#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
threat_watch - classify web visitors from selected countries in cPanel/Apache domlogs.

Every run reads only the log lines written since the previous run, maps each
visitor IP to a country with a local copy of the RIR delegation files (or a
MaxMind .mmdb file), and sorts every watched visitor into one of:

    attack    exploit attempts, webshell access, code injection
    scanner   probing for files/versions, hacking tools, many .php 404s
    fake_bot  claims to be Googlebot/Bingbot/... from a watched country
    bot       known crawlers
    normal    ordinary page views

Results are written as small text/CSV reports. Nothing is blocked.

Requires Python 3.6+ (standard library only). Run as root via threat_watch.sh.
"""

import argparse
import bisect
import fcntl
import fnmatch
import gzip
import ipaddress
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
from collections import Counter, OrderedDict, defaultdict
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)


def _read_version():
    try:
        with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
            return f.read().strip() or "dev"
    except OSError:
        return "dev"


VERSION = _read_version()

CATEGORIES = ("attack", "scanner", "fake_bot", "bot", "normal")
RANK = {"normal": 0, "bot": 1, "fake_bot": 2, "scanner": 3, "attack": 4}
SUSPICIOUS = ("attack", "scanner", "fake_bot")
RULE_KINDS = ("attack", "scanner", "scanner_ua", "bot_ua")

EXIT_OK, EXIT_CONFIG, EXIT_SECURITY, EXIT_GEO = 0, 1, 2, 3

DEFAULT_RIR_SOURCES = " ".join([
    "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest",
    "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest",
    "https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest",
    "https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-latest",
    "https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-latest",
])

DEFAULTS = OrderedDict([
    ("INSTANCE_NAME", "default"),
    # input
    ("DOMLOG_DIR", ""),
    ("LOG_GLOB", "*"),
    ("DOMAINS", ""),
    ("EXCLUDE_LOGS", "*-bytes_log *-ftp_log *.bkup *.offset *.gz"),
    ("ARCHIVE_DIR", ""),
    ("ROTATION_CATCHUP", "yes"),
    ("ARCHIVE_MAX_MB", "1024"),
    ("FIRST_RUN", "full"),
    ("MAX_LINE_LENGTH", "8192"),
    # output
    ("OUTPUT_DIR", ""),
    ("STATE_DIR", "/var/lib/threat_watch"),
    ("OUTPUT_FILE_MODE", "0600"),
    ("RETENTION_DAYS", "30"),
    ("SAMPLE_LINES_PER_IP", "30"),
    ("TOP_NORMAL", "20"),
    ("REPEAT_KEEP_DAYS", "90"),
    # countries
    ("WATCH_COUNTRIES", "ID"),
    ("WATCH_UNKNOWN", "no"),
    ("WHITELIST_COUNTRIES", "MY"),
    ("WHITELIST_IPS", "127.0.0.1 ::1"),
    ("WHITELIST_CIDRS", ""),
    # geo
    ("GEO_PROVIDER", "rir"),
    ("GEO_REFRESH_DAYS", "7"),
    ("RIR_SOURCES", DEFAULT_RIR_SOURCES),
    ("GEO_MMDB_FILE", ""),
    # rules
    ("RULES_DIR", ""),
    ("LOCAL_RULES_DIR", "/etc/threat_watch/rules.local"),
    ("DISABLED_RULES", ""),
    ("SCANNER_404_THRESHOLD", "20"),
    ("FLAG_FAKE_BOTS", "yes"),
    ("FAKE_BOT_UA_REGEX", "googlebot|bingbot|applebot|duckduckbot|yandexbot|baiduspider"),
    ("FAKE_BOT_EXEMPT_COUNTRIES", "US"),
])


class ConfigError(Exception):
    pass


class SecurityError(Exception):
    pass


class GeoError(Exception):
    pass


# --------------------------------------------------------------------------- #
# config
# --------------------------------------------------------------------------- #

_KEY_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")
_CC_RE = re.compile(r"^[A-Z]{2}$")


def _words(value):
    return [w for w in (value or "").split() if w]


def _parse_value(raw):
    raw = raw.strip()
    if raw[:1] in ('"', "'"):
        quote = raw[0]
        end = raw.find(quote, 1)
        if end == -1:
            raise ValueError("unterminated quote")
        rest = raw[end + 1:].strip()
        if rest and not rest.startswith("#"):
            raise ValueError("unexpected text after closing quote")
        return raw[1:end]
    m = re.search(r"\s#", raw)
    if m:
        raw = raw[:m.start()]
    return raw.strip()


def load_config(path):
    raw = OrderedDict(DEFAULTS)
    warnings = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise ConfigError("cannot read config %s: %s" % (path, e))
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("export "):
            s = s[7:].lstrip()
        m = _KEY_RE.match(s)
        if not m:
            raise ConfigError("%s:%d: cannot parse line: %s" % (path, n, line))
        key, value = m.groups()
        try:
            value = _parse_value(value)
        except ValueError as e:
            raise ConfigError("%s:%d: %s" % (path, n, e))
        if key not in DEFAULTS:
            warnings.append("%s:%d: unknown setting %s (ignored)" % (path, n, key))
            continue
        raw[key] = value
    return Settings(raw, path), warnings


class Settings(object):
    def __init__(self, raw, path):
        self.path = path
        g = raw.get

        self.instance = g("INSTANCE_NAME") or "default"
        if not re.match(r"^[A-Za-z0-9._-]+$", self.instance):
            raise ConfigError("INSTANCE_NAME may only contain letters, digits, '.', '_' and '-'")

        self.domlog_dir = g("DOMLOG_DIR")
        if not self.domlog_dir:
            raise ConfigError("DOMLOG_DIR is required")
        self.log_glob = g("LOG_GLOB") or "*"
        self.domains = set(_words(g("DOMAINS")))
        self.exclude_logs = _words(g("EXCLUDE_LOGS"))
        self.archive_dir = g("ARCHIVE_DIR")
        self.rotation_catchup = self._yesno(g, "ROTATION_CATCHUP")
        self.archive_max_bytes = self._int(g, "ARCHIVE_MAX_MB", 1) * 1024 * 1024
        self.first_run = self._choice(g, "FIRST_RUN", ("full", "skip"))
        self.max_line = self._int(g, "MAX_LINE_LENGTH", 256)

        self.output_dir = g("OUTPUT_DIR")
        if not self.output_dir:
            raise ConfigError("OUTPUT_DIR is required")
        base_state = g("STATE_DIR") or "/var/lib/threat_watch"
        self.state_dir = os.path.join(base_state, self.instance)
        try:
            self.file_mode = int(g("OUTPUT_FILE_MODE"), 8)
        except ValueError:
            raise ConfigError("OUTPUT_FILE_MODE must be octal, e.g. 0600")
        if self.file_mode & 0o022 or self.file_mode > 0o777:
            raise ConfigError("OUTPUT_FILE_MODE must not be group/world writable (use 0600 or 0640)")
        self.retention_days = self._int(g, "RETENTION_DAYS", 1)
        self.sample_lines = self._int(g, "SAMPLE_LINES_PER_IP", 0)
        self.top_normal = self._int(g, "TOP_NORMAL", 0)
        self.repeat_keep_days = self._int(g, "REPEAT_KEEP_DAYS", 1)

        watch = [w.upper() for w in _words(g("WATCH_COUNTRIES"))]
        if not watch:
            raise ConfigError("WATCH_COUNTRIES is empty (use e.g. \"ID\" or \"ALL\")")
        self.watch_all = "ALL" in watch
        self.watch = set(w for w in watch if w != "ALL")
        self.watch_unknown = self._yesno(g, "WATCH_UNKNOWN")
        self.wl_countries = set(w.upper() for w in _words(g("WHITELIST_COUNTRIES")))
        self.fake_bot_exempt = set(w.upper() for w in _words(g("FAKE_BOT_EXEMPT_COUNTRIES")))
        for label, ccs in (("WATCH_COUNTRIES", self.watch),
                           ("WHITELIST_COUNTRIES", self.wl_countries),
                           ("FAKE_BOT_EXEMPT_COUNTRIES", self.fake_bot_exempt)):
            bad = [c for c in ccs if not _CC_RE.match(c)]
            if bad:
                raise ConfigError("%s: not 2-letter country codes: %s" % (label, " ".join(sorted(bad))))

        self.wl_ips = set()
        for w in _words(g("WHITELIST_IPS")):
            try:
                self.wl_ips.add(ipaddress.ip_address(w))
            except ValueError:
                raise ConfigError("WHITELIST_IPS: invalid IP %r" % w)
        self.wl_nets = []
        for w in _words(g("WHITELIST_CIDRS")):
            try:
                self.wl_nets.append(ipaddress.ip_network(w, strict=False))
            except ValueError:
                raise ConfigError("WHITELIST_CIDRS: invalid network %r" % w)

        self.geo_provider = self._choice(g, "GEO_PROVIDER", ("rir", "mmdb"))
        self.geo_refresh_days = self._int(g, "GEO_REFRESH_DAYS", 1)
        self.rir_sources = _words(g("RIR_SOURCES"))
        self.mmdb_file = g("GEO_MMDB_FILE")
        if self.geo_provider == "rir" and not self.rir_sources:
            raise ConfigError("RIR_SOURCES is empty")
        if self.geo_provider == "mmdb" and not self.mmdb_file:
            raise ConfigError("GEO_PROVIDER=mmdb needs GEO_MMDB_FILE")

        self.rules_dir = g("RULES_DIR") or os.path.join(ROOT, "rules")
        self.local_rules_dir = g("LOCAL_RULES_DIR")
        self.disabled_rules = set(_words(g("DISABLED_RULES")))
        self.scanner_404_threshold = self._int(g, "SCANNER_404_THRESHOLD", 0)
        self.flag_fake_bots = self._yesno(g, "FLAG_FAKE_BOTS")
        try:
            self.fake_bot_ua = re.compile(g("FAKE_BOT_UA_REGEX") or "(?!)", re.IGNORECASE)
        except re.error as e:
            raise ConfigError("FAKE_BOT_UA_REGEX: %s" % e)

    @staticmethod
    def _yesno(g, key):
        v = (g(key) or "").strip().lower()
        if v in ("yes", "y", "true", "1", "on"):
            return True
        if v in ("no", "n", "false", "0", "off", ""):
            return False
        raise ConfigError("%s must be yes or no (got %r)" % (key, v))

    @staticmethod
    def _int(g, key, minimum):
        try:
            v = int(g(key))
        except (TypeError, ValueError):
            raise ConfigError("%s must be a whole number" % key)
        if v < minimum:
            raise ConfigError("%s must be >= %d" % (key, minimum))
        return v

    @staticmethod
    def _choice(g, key, options):
        v = (g(key) or "").strip().lower()
        if v not in options:
            raise ConfigError("%s must be one of: %s" % (key, ", ".join(options)))
        return v

    def geo_wanted(self):
        """Countries the geo table must contain (None = all)."""
        if self.watch_all:
            return None
        return set(self.watch) | set(self.wl_countries) | set(self.fake_bot_exempt)


def load_rules(settings):
    """Load <kind>.rules from RULES_DIR, then LOCAL_RULES_DIR (same name overrides)."""
    rules = {k: OrderedDict() for k in RULE_KINDS}
    for d, required in ((settings.rules_dir, True), (settings.local_rules_dir, False)):
        if not d:
            continue
        if not os.path.isdir(d):
            if required:
                raise ConfigError("RULES_DIR not found: %s" % d)
            continue
        for kind in RULE_KINDS:
            p = os.path.join(d, kind + ".rules")
            if not os.path.isfile(p):
                if required:
                    raise ConfigError("missing rules file: %s" % p)
                continue
            with open(p, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    s = line.strip()
                    if not s or s.startswith("#"):
                        continue
                    parts = s.split(None, 1)
                    if len(parts) != 2:
                        raise ConfigError("%s:%d: expected '<rule_name> <regex>'" % (p, n))
                    name, rx = parts
                    try:
                        rules[kind][name] = re.compile(rx, re.IGNORECASE)
                    except re.error as e:
                        raise ConfigError("%s:%d: bad regex for rule %s: %s" % (p, n, name, e))
    out = {}
    for kind in RULE_KINDS:
        out[kind] = [(n, rx) for n, rx in rules[kind].items() if n not in settings.disabled_rules]
    return out


# --------------------------------------------------------------------------- #
# safe filesystem helpers (state/output dirs must not be tamperable by others)
# --------------------------------------------------------------------------- #

def open_private_dir(path, create=True):
    path = os.path.abspath(path)
    if create:
        os.makedirs(path, mode=0o700, exist_ok=True)
    real = os.path.realpath(path)
    if real != path:
        raise SecurityError("%s resolves through a symlink to %s; set the real path in the config" % (path, real))
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as e:
        raise SecurityError("cannot open directory %s safely: %s" % (path, e))
    st = os.fstat(fd)
    if st.st_uid != os.geteuid():
        os.close(fd)
        raise SecurityError("%s is owned by uid %d, not by the user running threat_watch (uid %d); "
                            "refusing because that user could tamper with it" % (path, st.st_uid, os.geteuid()))
    if st.st_mode & 0o022:
        os.close(fd)
        raise SecurityError("%s is group/world-writable; run: chmod 700 %s" % (path, path))
    return fd


def write_atomic(dirfd, name, text, mode):
    tmp = ".%s.%d.tmp" % (name, os.getpid())
    try:
        os.unlink(tmp, dir_fd=dirfd)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dirfd)
    try:
        os.fchmod(fd, mode)
        f = os.fdopen(fd, "w", encoding="utf-8")
        fd = None
        with f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
    finally:
        if fd is not None:
            os.close(fd)
    os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)


def read_text(dirfd, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def read_json(dirfd, name, default, log=None):
    txt = read_text(dirfd, name)
    if txt is None:
        return default
    try:
        return json.loads(txt)
    except ValueError:
        if log:
            log.warn("%s is corrupt; starting it fresh" % name)
        return default


def file_exists(dirfd, name):
    try:
        os.stat(name, dir_fd=dirfd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def append_runlog(dirfd, name, text, mode, max_bytes=1024 * 1024):
    try:
        st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
        if st.st_size > max_bytes:
            old = read_text(dirfd, name) or ""
            keep = old[-(max_bytes // 4):]
            keep = keep[keep.find("\n") + 1:]
            write_atomic(dirfd, name, keep, mode)
    except FileNotFoundError:
        pass
    fd = os.open(name, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, mode, dir_fd=dirfd)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(text)


# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #

class RunLog(object):
    def __init__(self, echo):
        self.echo = echo
        self.lines = []
        self.warnings = 0

    def _add(self, level, msg):
        line = "%s [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), level, msg)
        self.lines.append(line)
        if self.echo or level == "ERROR":
            sys.stderr.write(line + "\n")

    def info(self, msg):
        self._add("INFO", msg)

    def warn(self, msg):
        self.warnings += 1
        self._add("WARN", msg)

    def error(self, msg):
        self._add("ERROR", msg)

    def text(self):
        return "".join(l + "\n" for l in self.lines)


# --------------------------------------------------------------------------- #
# geo lookup
# --------------------------------------------------------------------------- #

class RirGeo(object):
    """Country lookup from the five RIR 'delegated' statistics files."""

    CACHE = "geo_ranges.tsv"
    META = "geo_meta.json"

    def __init__(self, settings, statefd, log):
        self.s = settings
        self.fd = statefd
        self.log = log
        self.starts = {4: [], 6: []}
        self.ends = {4: [], 6: []}
        self.ccs = {4: [], 6: []}

    def ensure(self, force=False):
        meta = read_json(self.fd, self.META, {}, self.log)
        have = file_exists(self.fd, self.CACHE)
        age = time.time() - float(meta.get("built", 0))
        stale = age > self.s.geo_refresh_days * 86400
        changed = meta.get("sources") != self.s.rir_sources
        if force or not have or stale or changed:
            self.refresh(have)

    def refresh(self, have_cache):
        ranges = []
        ok = 0
        for url in self.s.rir_sources:
            try:
                n = self._fetch(url, ranges)
                ok += 1
                self.log.info("geo: %s -> %d ranges" % (url, n))
            except Exception as e:  # network/parse errors are reported, not fatal
                self.log.warn("geo: failed to fetch %s: %s" % (url, e))
        if ok < len(self.s.rir_sources):
            if have_cache:
                self.log.warn("geo: %d/%d sources failed; keeping the previous country table" %
                              (len(self.s.rir_sources) - ok, len(self.s.rir_sources)))
                return
            if ok == 0:
                raise GeoError("could not download any RIR source and no cached country table exists")
            self.log.warn("geo: building a partial country table from %d/%d sources" %
                          (ok, len(self.s.rir_sources)))
        ranges.sort()
        body = "".join("%d|%d|%d|%s\n" % r for r in ranges)
        write_atomic(self.fd, self.CACHE, body, 0o600)
        write_atomic(self.fd, self.META, json.dumps({
            "built": time.time(), "sources": self.s.rir_sources,
            "ok_sources": ok, "ranges": len(ranges)}, indent=1), 0o600)
        self.log.info("geo: country table rebuilt (%d ranges)" % len(ranges))

    @staticmethod
    def _fetch(url, out):
        req = urllib.request.Request(url, headers={"User-Agent": "threat_watch/%s" % VERSION})
        count = 0
        with urllib.request.urlopen(req, timeout=90) as resp:
            for raw in resp:
                line = raw.decode("ascii", "replace").strip()
                if not line or line[0] == "#":
                    continue
                f = line.split("|")
                if len(f) < 7:
                    continue
                cc, typ, status = f[1].upper(), f[2], f[6]
                if typ not in ("ipv4", "ipv6") or not _CC_RE.match(cc):
                    continue
                if status not in ("allocated", "assigned"):
                    continue
                try:
                    start = int(ipaddress.ip_address(f[3]))
                    if typ == "ipv4":
                        end, ver = start + int(f[4]) - 1, 4
                    else:
                        end, ver = start + (1 << (128 - int(f[4]))) - 1, 6
                except ValueError:
                    continue
                out.append((ver, start, end, cc))
                count += 1
        if count == 0:
            raise ValueError("no ranges found in file")
        return count

    def load(self, wanted):
        txt = read_text(self.fd, self.CACHE)
        if txt is None:
            raise GeoError("country table missing; run with --refresh-geo")
        for line in txt.splitlines():
            parts = line.split("|")
            if len(parts) != 4:
                continue
            cc = parts[3]
            if wanted is not None and cc not in wanted:
                continue
            ver = int(parts[0])
            self.starts[ver].append(int(parts[1]))
            self.ends[ver].append(int(parts[2]))
            self.ccs[ver].append(cc)

    def lookup(self, ip):
        ver = ip.version
        n = int(ip)
        st = self.starts[ver]
        i = bisect.bisect_right(st, n) - 1
        if i >= 0 and self.ends[ver][i] >= n:
            return self.ccs[ver][i]
        return "??"


class MmdbGeo(object):
    """Country lookup through the mmdblookup CLI (libmaxminddb)."""

    def __init__(self, settings, log):
        self.path = settings.mmdb_file
        self.bin = shutil.which("mmdblookup")
        self.log = log
        if not self.bin:
            raise GeoError("GEO_PROVIDER=mmdb but mmdblookup is not installed")
        if not os.path.isfile(self.path):
            raise GeoError("GEO_MMDB_FILE not found: %s" % self.path)

    def ensure(self, force=False):
        pass

    def load(self, wanted):
        pass

    def lookup(self, ip):
        try:
            res = subprocess.run([self.bin, "--file", self.path, "--ip", str(ip), "country", "iso_code"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return "??"
        m = re.search(r'"([A-Za-z]{2})"', res.stdout.decode("utf-8", "replace"))
        return m.group(1).upper() if m else "??"


# --------------------------------------------------------------------------- #
# log parsing
# --------------------------------------------------------------------------- #

LINE_RE = re.compile(
    r'^(\S+) \S+ \S+ \[([^\]]+)\] "((?:[^"\\]|\\.)*)" (\d{3}|-) (\S+)'
    r'(?: "((?:[^"\\]|\\.)*)" "((?:[^"\\]|\\.)*)")?')
MONTHS = {"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
          "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12}
PHP_PATH_RE = re.compile(r"\.(?:php\d?|phtml|pht)$", re.IGNORECASE)
_tz_cache = {}


def parse_ts(s):
    """'17/Nov/2026:14:40:16 +0800' -> aware datetime (None if malformed)."""
    try:
        off = s[21:26]
        tz = _tz_cache.get(off)
        if tz is None:
            sign = 1 if off[0] == "+" else -1
            tz = timezone(sign * timedelta(hours=int(off[1:3]), minutes=int(off[3:5])))
            _tz_cache[off] = tz
        return datetime(int(s[7:11]), MONTHS[s[3:6]], int(s[0:2]),
                        int(s[12:14]), int(s[15:17]), int(s[18:20]), tzinfo=tz)
    except (KeyError, ValueError, IndexError):
        return None


class LineReader(object):
    """Split a binary stream into lines, never reading past `limit` bytes."""

    def __init__(self, fobj, limit, max_line):
        self.f = fobj
        self.limit = limit
        self.max_line = max_line
        self.total = 0
        self.leftover = b""
        self.truncated = False

    def __iter__(self):
        buf = b""
        while self.total < self.limit:
            chunk = self.f.read(min(1 << 20, self.limit - self.total))
            if not chunk:
                break
            self.total += len(chunk)
            buf += chunk
            parts = buf.split(b"\n")
            buf = parts.pop()
            if len(buf) > 4 * 1024 * 1024:  # absurd line without newline: drop it
                buf = b""
            for p in parts:
                yield p[:self.max_line]
        if self.total >= self.limit and self.f.read(1):
            self.truncated = True
        self.leftover = buf


def decode(raw):
    return raw.decode("utf-8", "replace").rstrip("\r")


class Visitor(object):
    __slots__ = ("ip", "cc", "cat", "reqs", "cats", "hits", "first", "last", "first_s", "last_s",
                 "domains", "reasons", "rcat", "uas", "samples", "php404")

    def __init__(self, ip, cc):
        self.ip, self.cc, self.cat = ip, cc, "normal"
        self.reqs = self.hits = self.php404 = 0
        self.cats, self.reasons, self.uas, self.domains = Counter(), Counter(), Counter(), Counter()
        self.rcat = {}
        self.first = self.last = None
        self.first_s = self.last_s = ""
        self.samples = []


class Analyzer(object):
    def __init__(self, settings, rules, geo, log):
        self.s = settings
        self.rules = rules
        self.geo = geo
        self.log = log
        self.ipcache = {}
        self.visitors = {}
        self.bot_names = defaultdict(lambda: [set(), 0])
        self.lines = self.bad = self.whitelisted = self.other = self.watched = 0
        self.win_first = self.win_last = None

    def resolve(self, ip_s):
        try:
            ip = ipaddress.ip_address(ip_s)
        except ValueError:
            return ("other", "??")
        if ip in self.s.wl_ips or any(ip in n for n in self.s.wl_nets):
            return ("whitelist", "--")
        cc = self.geo.lookup(ip)
        if cc in self.s.wl_countries:
            return ("whitelist", cc)
        if self.s.watch_all or cc in self.s.watch or (cc == "??" and self.s.watch_unknown):
            return ("watch", cc)
        return ("other", cc)

    def classify(self, method, url, ua, cc):
        req = method + " " + url
        for name, rx in self.rules["attack"]:
            if rx.search(req):
                return "attack", name
        for name, rx in self.rules["scanner"]:
            if rx.search(req):
                return "scanner", name
        for name, rx in self.rules["scanner_ua"]:
            if rx.search(ua):
                return "scanner", name
        for name, rx in self.rules["bot_ua"]:
            if rx.search(ua):
                if (self.s.flag_fake_bots and self.s.fake_bot_ua.search(ua)
                        and cc not in self.s.fake_bot_exempt):
                    return "fake_bot", "fake_" + name
                return "bot", name
        return "normal", None

    def handle(self, line, domain, min_ts=None):
        """Process one log line. Returns its epoch timestamp (or None if unparsable)."""
        m = LINE_RE.match(line)
        if not m:
            self.bad += 1
            return None
        ip_s, ts_raw, req, status_s, _size, _ref, ua = m.groups()
        dt = parse_ts(ts_raw)
        if dt is None:
            self.bad += 1
            return None
        ts = dt.timestamp()
        if min_ts is not None and ts <= min_ts:
            return ts
        self.lines += 1
        if self.win_first is None or ts < self.win_first[0]:
            self.win_first = (ts, dt)
        if self.win_last is None or ts > self.win_last[0]:
            self.win_last = (ts, dt)

        info = self.ipcache.get(ip_s)
        if info is None:
            info = self.resolve(ip_s)
            self.ipcache[ip_s] = info
        action, cc = info
        if action == "whitelist":
            self.whitelisted += 1
            return ts
        if action == "other":
            self.other += 1
            return ts
        self.watched += 1

        parts = req.split(" ")
        if len(parts) >= 2:
            method, url = parts[0], parts[1]
        else:
            method, url = (req or "-"), ""
        ua = ua or ""
        status = int(status_s) if status_s.isdigit() else 0

        cat, reason = self.classify(method, url, ua, cc)
        v = self.visitors.get(ip_s)
        if v is None:
            v = self.visitors[ip_s] = Visitor(ip_s, cc)
        v.reqs += 1
        v.cats[cat] += 1
        v.domains[domain] += 1
        if reason:
            v.reasons[reason] += 1
            v.rcat[reason] = cat
        if v.first is None or ts < v.first:
            v.first, v.first_s = ts, dt.strftime("%Y-%m-%d %H:%M:%S %z")
        if v.last is None or ts > v.last:
            v.last, v.last_s = ts, dt.strftime("%Y-%m-%d %H:%M:%S %z")
        if cat == "attack" and 200 <= status < 300:
            v.hits += 1
        is_php404 = status == 404 and PHP_PATH_RE.search(url.split("?", 1)[0]) is not None
        if is_php404:
            v.php404 += 1
        if cat == "bot":
            b = self.bot_names[reason]
            b[0].add(ip_s)
            b[1] += 1
        if ua in v.uas or len(v.uas) < 10:
            v.uas[ua] += 1
        if (cat in SUSPICIOUS or is_php404) and len(v.samples) < self.s.sample_lines:
            v.samples.append((dt.strftime("%Y-%m-%d %H:%M:%S"), domain, method, url, status_s, ua,
                              reason or ("php_404" if is_php404 else "")))
        if RANK[cat] > RANK[v.cat]:
            v.cat = cat
        return ts

    def finalize(self):
        t = self.s.scanner_404_threshold
        for v in self.visitors.values():
            if t and v.php404 >= t and RANK[v.cat] < RANK["scanner"]:
                v.cat = "scanner"
                key = "php_404_x%d" % v.php404
                v.reasons[key] += 1
                v.rcat[key] = "scanner"


# --------------------------------------------------------------------------- #
# reading logs (incremental)
# --------------------------------------------------------------------------- #

def list_logs(s, log):
    try:
        names = sorted(os.listdir(s.domlog_dir))
    except OSError as e:
        raise ConfigError("cannot list DOMLOG_DIR %s: %s" % (s.domlog_dir, e))
    out = []
    for name in names:
        if name.startswith(".") or not fnmatch.fnmatch(name, s.log_glob):
            continue
        if any(fnmatch.fnmatch(name, x) for x in s.exclude_logs):
            continue
        full = os.path.join(s.domlog_dir, name)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        domain = name[:-len("-ssl_log")] if name.endswith("-ssl_log") else name
        if s.domains and domain not in s.domains:
            continue
        out.append((name, full, domain))
    return out


def catchup_archive(s, an, name, domain, since_ts, log):
    """Read lines newer than since_ts from the rotated cPanel archive (<log>-Mon-YYYY.gz)."""
    if not s.archive_dir or not os.path.isdir(s.archive_dir):
        return 0
    rx = re.compile("^" + re.escape(name) + r"-[A-Z][a-z]{2}-\d{4}\.gz$")
    cands = []
    for fn in os.listdir(s.archive_dir):
        if not rx.match(fn):
            continue
        p = os.path.join(s.archive_dir, fn)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if stat.S_ISREG(st.st_mode) and st.st_mtime >= since_ts - 3600:
            cands.append((st.st_mtime, p))
    before = an.lines
    for _mt, p in sorted(cands):
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError as e:
            log.warn("catch-up: cannot open %s: %s" % (p, e))
            continue
        with os.fdopen(fd, "rb") as raw:
            try:
                with gzip.GzipFile(fileobj=raw) as gz:
                    reader = LineReader(gz, s.archive_max_bytes, s.max_line)
                    for line in reader:
                        an.handle(decode(line), domain, min_ts=since_ts)
                    if reader.truncated:
                        log.warn("catch-up: %s is larger than ARCHIVE_MAX_MB; stopped early" % p)
            except (OSError, EOFError) as e:
                log.warn("catch-up: %s unreadable: %s" % (p, e))
    got = an.lines - before
    if got:
        log.info("catch-up: %s -> %d lines from rotated archive" % (name, got))
    return got


def read_logs(s, an, state, log, since_start, now):
    logs_state = state.setdefault("logs", {})
    stats = {"files": 0, "bytes": 0, "rotated": 0}
    seen = set()
    for name, full, domain in list_logs(s, log):
        seen.add(name)
        prev = logs_state.get(name)
        try:
            fd = os.open(full, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError as e:
            log.warn("cannot open %s: %s" % (full, e))
            continue
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            size, ino = st.st_size, st.st_ino
            start = 0
            last_ts = prev.get("last_ts") if prev else None
            if since_start:
                start = 0
            elif prev is None:
                if s.first_run == "skip":
                    start = size
                    log.info("first run: skipping existing %d bytes of %s" % (size, name))
            elif prev.get("inode") != ino or size < prev.get("offset", 0):
                stats["rotated"] += 1
                log.info("rotation detected on %s" % name)
                if s.rotation_catchup and last_ts:
                    catchup_archive(s, an, name, domain, last_ts, log)
            else:
                start = prev.get("offset", 0)
            f.seek(start)
            reader = LineReader(f, size - start, s.max_line)
            for line in reader:
                ts = an.handle(decode(line), domain)
                if ts is not None and (last_ts is None or ts > last_ts):
                    last_ts = ts
            consumed = reader.total - len(reader.leftover)
            stats["files"] += 1
            stats["bytes"] += consumed
            logs_state[name] = {"inode": ino, "offset": start + consumed, "last_ts": last_ts, "seen": now}
    for name in list(logs_state):
        if name not in seen and now - float(logs_state[name].get("seen", 0)) > 30 * 86400:
            del logs_state[name]
    return stats


# --------------------------------------------------------------------------- #
# reports
# --------------------------------------------------------------------------- #

_CTRL_RE = re.compile("[\x00-\x1f\x7f-\x9f‪-‮⁦-⁩]")


def clean(s, maxlen=300):
    s = _CTRL_RE.sub(lambda m: "\\x%02x" % ord(m.group()) if ord(m.group()) < 256
                     else "\\u%04x" % ord(m.group()), s or "")
    return s if len(s) <= maxlen else s[:maxlen] + "..."


def csv_field(s):
    s = clean(str(s), 1000)
    if s[:1] in ("=", "+", "-", "@"):
        s = "'" + s
    if any(c in s for c in ',"\n'):
        s = '"' + s.replace('"', '""') + '"'
    return s


def table(headers, rows, indent="  "):
    widths = [len(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(str(c)))
    fmt = lambda r: indent + "  ".join(
        str(c).rjust(widths[i]) if isinstance(c, int) else str(c).ljust(widths[i])
        for i, c in enumerate(r)).rstrip()
    out = [fmt(headers), indent + "  ".join("-" * w for w in widths)]
    out.extend(fmt(r) for r in rows)
    return "\n".join(out)


def top_reason(v):
    """Most frequent reason among those that gave the visitor its final category."""
    best = [(n, r) for r, n in v.reasons.items() if v.rcat.get(r) == v.cat]
    if not best:
        return v.reasons.most_common(1)[0][0] if v.reasons else ""
    return sorted(best, key=lambda x: (-x[0], x[1]))[0][1]


def build_summary(s, an, stats, run_dt, took, prefix, offenders):
    vs = list(an.visitors.values())
    susp = sorted((v for v in vs if v.cat in SUSPICIOUS),
                  key=lambda v: (-RANK[v.cat], -v.hits, -v.reqs))
    L = []
    L.append("threat_watch %s  |  instance: %s" % (VERSION, s.instance))
    L.append("Run:        %s  (took %.1fs)" % (run_dt.strftime("%Y-%m-%d %H:%M:%S %z"), took))
    if an.win_first:
        L.append("Window:     %s  ->  %s" % (an.win_first[1].strftime("%Y-%m-%d %H:%M:%S %z"),
                                             an.win_last[1].strftime("%Y-%m-%d %H:%M:%S %z")))
    else:
        L.append("Window:     (no new log lines)")
    L.append("Watching:   %s%s" % ("ALL countries" if s.watch_all else " ".join(sorted(s.watch)),
                                   "  (+unknown)" if s.watch_unknown else ""))
    L.append("Whitelist:  countries: %s | IPs/CIDRs: %d" %
             (" ".join(sorted(s.wl_countries)) or "-", len(s.wl_ips) + len(s.wl_nets)))
    L.append("Logs:       %d files, %d new lines (%.1f MB), %d rotated, %d unparsable" %
             (stats["files"], an.lines, stats["bytes"] / 1048576.0, stats["rotated"], an.bad))
    L.append("Traffic:    %d watched, %d whitelisted, %d other countries" %
             (an.watched, an.whitelisted, an.other))
    L.append("")

    L.append("TOTAL (watched visitors)")
    rows = []
    for c in CATEGORIES:
        ips = [v for v in vs if v.cat == c]
        rows.append((c, len(ips), sum(v.reqs for v in ips)))
    L.append(table(("Category", "IPs", "Requests"), rows))
    L.append("")

    dom_ips = defaultdict(Counter)
    dom_reqs = defaultdict(Counter)
    for v in vs:
        for d, n in v.domains.items():
            dom_ips[d][v.cat] += 1
            dom_reqs[d][v.cat] += n
    if dom_ips:
        L.append("PER DOMAIN (IPs per category, total requests)")
        rows = []
        for d in sorted(dom_ips, key=lambda d: (-sum(dom_ips[d][c] for c in SUSPICIOUS), d)):
            rows.append(tuple([d] + [dom_ips[d][c] for c in CATEGORIES] + [sum(dom_reqs[d].values())]))
        L.append(table(("Domain",) + CATEGORIES + ("Requests",), rows))
        L.append("")

    L.append("SUSPICIOUS IPS (%d)%s" % (len(susp), "  -> details: %s_suspicious.txt" % prefix if susp else ""))
    if susp:
        rows = []
        for v in susp[:50]:
            rep = offenders.get(v.ip, {}).get("runs", 1)
            rows.append((v.ip, v.cc, v.cat, v.reqs, v.hits, rep,
                         clean(",".join(sorted(v.domains)), 40), clean(top_reason(v), 30)))
        L.append(table(("IP", "CC", "Category", "Reqs", "Hits", "Runs", "Domains", "Top reason"), rows))
        if len(susp) > 50:
            L.append("  ... %d more in the details file" % (len(susp) - 50))
        if any(v.hits for v in susp):
            L.append("  !! Hits = attack requests that got HTTP 2xx. Check those URLs on disk now.")
    else:
        L.append("  none")
    L.append("")

    normal = sorted((v for v in vs if v.cat == "normal"), key=lambda v: -v.reqs)
    if s.top_normal and normal:
        L.append("TOP NORMAL VISITORS (%d of %d)" % (min(s.top_normal, len(normal)), len(normal)))
        L.append(table(("IP", "CC", "Reqs", "Domains"),
                       [(v.ip, v.cc, v.reqs, clean(",".join(sorted(v.domains)), 50))
                        for v in normal[:s.top_normal]]))
        L.append("")

    if an.bot_names:
        L.append("BOTS")
        L.append(table(("Bot", "IPs", "Requests"),
                       [(n, len(b[0]), b[1]) for n, b in
                        sorted(an.bot_names.items(), key=lambda kv: -kv[1][1])]))
        L.append("")

    rep = sorted(((ip, e) for ip, e in offenders.items() if e.get("runs", 0) >= 2),
                 key=lambda kv: (-kv[1]["runs"], -RANK.get(kv[1].get("worst"), 0)))
    L.append("REPEAT OFFENDERS (flagged in 2+ runs: %d)  -> repeat_offenders.txt" % len(rep))
    if rep:
        L.append(table(("IP", "CC", "Worst", "Runs", "Last seen"),
                       [(ip, e.get("cc", "??"), e.get("worst", ""), e.get("runs", 0),
                         e.get("last_s", "")) for ip, e in rep[:10]]))
    else:
        L.append("  none")
    L.append("")
    return "\n".join(L)


def build_suspicious(s, an, offenders):
    susp = sorted((v for v in an.visitors.values() if v.cat in SUSPICIOUS),
                  key=lambda v: (-RANK[v.cat], -v.hits, -v.reqs))
    L = []
    for v in susp:
        runs = offenders.get(v.ip, {}).get("runs", 1)
        L.append("=== %s [%s] %s  reqs=%d hits=%d runs=%d" % (v.ip, v.cc, v.cat.upper(), v.reqs, v.hits, runs))
        L.append("first: %s   last: %s" % (v.first_s, v.last_s))
        L.append("domains: %s" % clean(", ".join("%s(%d)" % kv for kv in v.domains.most_common()), 500))
        L.append("reasons: %s" % clean(", ".join("%s x%d" % kv for kv in v.reasons.most_common()), 500))
        L.append("categories: %s" % ", ".join("%s=%d" % kv for kv in v.cats.most_common()))
        for ua, n in v.uas.most_common(3):
            L.append("ua (x%d): %s" % (n, clean(ua, 200)))
        if v.samples:
            L.append("samples:")
            for t, d, m, u, st, ua, why in v.samples:
                L.append("  %s  %-24s %-6s %s  %s  [%s]" % (t, clean(d, 24), clean(m, 6), clean(u, 220), st, why))
        L.append("")
    return "\n".join(L)


def build_suspicious_csv(an, offenders):
    rows = ["ip,country,category,requests,hits,runs,first_seen,last_seen,domains,reasons"]
    for v in sorted((v for v in an.visitors.values() if v.cat in SUSPICIOUS),
                    key=lambda v: (-RANK[v.cat], -v.reqs)):
        rows.append(",".join(csv_field(x) for x in (
            v.ip, v.cc, v.cat, v.reqs, v.hits, offenders.get(v.ip, {}).get("runs", 1),
            v.first_s, v.last_s, " ".join(sorted(v.domains)),
            " ".join("%s:%d" % kv for kv in v.reasons.most_common()))))
    return "\n".join(rows) + "\n"


def update_offenders(s, an, offenders, now):
    for v in an.visitors.values():
        if v.cat not in SUSPICIOUS:
            continue
        e = offenders.get(v.ip)
        if e is None:
            e = offenders[v.ip] = {"cc": v.cc, "worst": v.cat, "runs": 0, "reqs": 0, "hits": 0,
                                   "first": v.first, "first_s": v.first_s, "domains": []}
        e["runs"] += 1
        e["reqs"] += v.reqs
        e["hits"] += v.hits
        e["cc"] = v.cc
        if RANK[v.cat] > RANK.get(e.get("worst"), 0):
            e["worst"] = v.cat
        if v.first < e.get("first", v.first):
            e["first"], e["first_s"] = v.first, v.first_s
        e["last"], e["last_s"] = v.last, v.last_s
        e["domains"] = sorted(set(e.get("domains", [])) | set(v.domains))[:20]
    cutoff = now - s.repeat_keep_days * 86400
    for ip in [ip for ip, e in offenders.items() if float(e.get("last", 0)) < cutoff]:
        del offenders[ip]


def build_offenders_txt(s, offenders):
    rows = sorted(offenders.items(), key=lambda kv: (-kv[1].get("runs", 0), -RANK.get(kv[1].get("worst"), 0)))
    L = ["threat_watch %s  |  instance: %s  |  updated %s" %
         (VERSION, s.instance, time.strftime("%Y-%m-%d %H:%M:%S %z")),
         "Suspicious IPs seen in the last %d days, most frequent first." % s.repeat_keep_days, ""]
    if not rows:
        L.append("  none")
    else:
        L.append(table(("IP", "CC", "Worst", "Runs", "Reqs", "Hits", "First seen", "Last seen", "Domains"),
                       [(ip, e.get("cc", "??"), e.get("worst", ""), e.get("runs", 0), e.get("reqs", 0),
                         e.get("hits", 0), e.get("first_s", ""), e.get("last_s", ""),
                         clean(",".join(e.get("domains", [])), 60)) for ip, e in rows]))
    return "\n".join(L) + "\n"


REPORT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{4,6}_(summary|suspicious)\.(txt|csv)$")


def prune_reports(s, outfd, now, log):
    cutoff = now - s.retention_days * 86400
    removed = 0
    for name in os.listdir(outfd):
        if not REPORT_RE.match(name):
            continue
        try:
            st = os.stat(name, dir_fd=outfd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
            os.unlink(name, dir_fd=outfd)
            removed += 1
    if removed:
        log.info("retention: removed %d report files older than %d days" % (removed, s.retention_days))


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #

def make_geo(s, statefd, log):
    return MmdbGeo(s, log) if s.geo_provider == "mmdb" else RirGeo(s, statefd, log)


def cmd_test_ip(s, statefd, log, ips):
    geo = make_geo(s, statefd, log)
    geo.ensure()
    geo.load(None)
    an = Analyzer(s, {k: [] for k in RULE_KINDS}, geo, log)
    for ip_s in ips:
        try:
            ip = ipaddress.ip_address(ip_s)
        except ValueError:
            print("%-40s invalid IP" % ip_s)
            continue
        action, _ = an.resolve(ip_s)
        print("%-40s country=%-3s -> %s" % (ip_s, geo.lookup(ip), action))
    return EXIT_OK


def cmd_validate(s, warnings):
    problems = []
    rules = load_rules(s)
    if not os.path.isdir(s.domlog_dir):
        problems.append("DOMLOG_DIR does not exist: %s" % s.domlog_dir)
    if s.archive_dir and not os.path.isdir(s.archive_dir):
        problems.append("ARCHIVE_DIR does not exist: %s" % s.archive_dir)
    if not os.path.isdir(os.path.dirname(os.path.abspath(s.output_dir))):
        problems.append("parent of OUTPUT_DIR does not exist: %s" % s.output_dir)
    if s.geo_provider == "mmdb":
        if not shutil.which("mmdblookup"):
            problems.append("mmdblookup not installed")
        if not os.path.isfile(s.mmdb_file):
            problems.append("GEO_MMDB_FILE not found: %s" % s.mmdb_file)
    overlap = s.watch & s.wl_countries
    if overlap:
        warnings.append("countries in both WATCH and WHITELIST (whitelist wins): %s" % " ".join(sorted(overlap)))
    print("threat_watch %s  config: %s" % (VERSION, s.path))
    print("  instance      : %s" % s.instance)
    print("  watch         : %s" % ("ALL" if s.watch_all else " ".join(sorted(s.watch))))
    print("  whitelist     : countries=%s ips=%d cidrs=%d" %
          (" ".join(sorted(s.wl_countries)) or "-", len(s.wl_ips), len(s.wl_nets)))
    print("  domlogs       : %s" % s.domlog_dir)
    print("  reports       : %s" % s.output_dir)
    print("  state         : %s" % s.state_dir)
    print("  geo           : %s" % s.geo_provider)
    print("  rules         : " + ", ".join("%s=%d" % (k, len(rules[k])) for k in RULE_KINDS))
    if os.path.isdir(s.domlog_dir):
        print("  logs found    : %d" % len(list_logs(s, RunLog(False))))
    for w in warnings:
        print("  warning       : %s" % w)
    for p in problems:
        print("  PROBLEM       : %s" % p)
    print("OK" if not problems else "NOT OK")
    return EXIT_OK if not problems else EXIT_CONFIG


def cmd_run(s, args, log, warnings):
    t0 = time.time()
    run_dt = datetime.now().astimezone()
    for w in warnings:
        log.warn(w)
    rules = load_rules(s)

    statefd = open_private_dir(s.state_dir)
    lockfd = os.open("lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=statefd)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.stderr.write("threat_watch: another run of instance '%s' is in progress; exiting\n" % s.instance)
        return EXIT_OK

    outfd = None if args.dry_run else open_private_dir(s.output_dir)

    geo = make_geo(s, statefd, log)
    geo.ensure()
    geo.load(s.geo_wanted())

    state = read_json(statefd, "state.json", {}, log)
    an = Analyzer(s, rules, geo, log)
    stats = read_logs(s, an, state, log, args.since_start, t0)
    an.finalize()

    offenders = read_json(statefd, "offenders.json", {}, log)
    if not args.dry_run:
        update_offenders(s, an, offenders, t0)

    prefix = run_dt.strftime("%Y-%m-%d_%H%M")
    if outfd is not None and file_exists(outfd, prefix + "_summary.txt"):
        prefix = run_dt.strftime("%Y-%m-%d_%H%M%S")
    took = time.time() - t0
    summary = build_summary(s, an, stats, run_dt, took, prefix, offenders)
    n_susp = sum(1 for v in an.visitors.values() if v.cat in SUSPICIOUS)

    if args.dry_run:
        sys.stdout.write(summary + "\n")
        if args.details and n_susp:
            sys.stdout.write("\n" + build_suspicious(s, an, offenders) + "\n")
        sys.stdout.write("(dry run: no state or reports written)\n")
        return EXIT_OK

    mode = s.file_mode
    write_atomic(outfd, prefix + "_summary.txt", summary + "\n", mode)
    write_atomic(outfd, "latest_summary.txt", summary + "\n", mode)
    if n_susp:
        write_atomic(outfd, prefix + "_suspicious.txt", build_suspicious(s, an, offenders), mode)
        write_atomic(outfd, prefix + "_suspicious.csv", build_suspicious_csv(an, offenders), mode)
    write_atomic(outfd, "repeat_offenders.txt", build_offenders_txt(s, offenders), mode)
    prune_reports(s, outfd, t0, log)

    state["version"] = VERSION
    state["last_run"] = t0
    write_atomic(statefd, "state.json", json.dumps(state, indent=1, sort_keys=True), 0o600)
    write_atomic(statefd, "offenders.json", json.dumps(offenders, indent=1, sort_keys=True), 0o600)

    log.info("run done: %d files, %d lines, %d watched, %d suspicious IPs, %.1fs" %
             (stats["files"], an.lines, an.watched, n_susp, time.time() - t0))
    append_runlog(outfd, "threat_watch.log", log.text(), mode)
    if args.stdout:
        sys.stdout.write(summary + "\n")
    return EXIT_OK


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="threat_watch",
        description="Classify visitors from selected countries in Apache/cPanel domlogs (report only).")
    p.add_argument("-c", "--config", default="/etc/threat_watch/threat_watch.conf", help="config file")
    p.add_argument("--dry-run", action="store_true", help="analyse and print, but write no state or reports")
    p.add_argument("--details", action="store_true", help="with --dry-run: also print per-IP details")
    p.add_argument("--since-start", action="store_true", help="ignore saved positions; read live logs from the beginning")
    p.add_argument("--stdout", action="store_true", help="also print the summary after a normal run")
    p.add_argument("--validate", action="store_true", help="check config and rules, then exit")
    p.add_argument("--refresh-geo", action="store_true", help="re-download the country table, then exit")
    p.add_argument("--test-ip", nargs="+", metavar="IP", help="show country and decision for IPs, then exit")
    p.add_argument("-v", "--verbose", action="store_true", help="print progress messages to stderr")
    p.add_argument("--version", action="version", version="threat_watch %s" % VERSION)
    args = p.parse_args(argv)

    log = RunLog(args.verbose)
    try:
        s, warnings = load_config(args.config)
        if args.validate:
            return cmd_validate(s, warnings)
        if args.refresh_geo or args.test_ip:
            statefd = open_private_dir(s.state_dir)
            if args.refresh_geo:
                geo = make_geo(s, statefd, RunLog(True))
                geo.ensure(force=True)
                return EXIT_OK
            return cmd_test_ip(s, statefd, log, args.test_ip)
        return cmd_run(s, args, log, warnings)
    except ConfigError as e:
        log.error("config: %s" % e)
        return EXIT_CONFIG
    except SecurityError as e:
        log.error("security: %s" % e)
        return EXIT_SECURITY
    except GeoError as e:
        log.error("geo: %s" % e)
        return EXIT_GEO


if __name__ == "__main__":
    sys.exit(main())
