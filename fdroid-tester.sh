#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 by-architect
#
# fdroid-tester.sh — test an app from an fdroiddata merge request on a phone,
# the way F-Droid's "Tester Review" asks for, and write the report to post.
# https://github.com/by-architect/fdroid-tester
#
#   fdroid-tester.sh <merge request link or number> [options]
#   fdroid-tester.sh --check          only check this machine and the phone
#
# In order, after checking every tool, the phone, PCAPdroid and the glab login:
#   1. reads the merge request and its Code Quality report from gitlab.com
#      (the APK link, permissions, CI warnings) — no login needed
#   2. downloads the APK that fits the connected phone into the current folder
#   3. looks inside the APK: permissions, trackers (Exodus list), web addresses
#      in the code, WebView, languages, debuggable/cleartext flags
#   4. installs it with adb, records its traffic with PCAPdroid if the phone
#      has it, opens the app and watches the first seconds: crash, permission
#      prompt on start, connections on start
#   5. asks what only a person can tell, and writes the report in the wiki's
#      template, ticked from what was found
#   6. posts the report as a comment on the same merge request (glab, after a yes)
#
# The checklist: https://gitlab.com/fdroid/wiki/-/wikis/Internal/Reviewing-new-apps

set -eu

# Everything below sits in one { … } block, so bash reads the whole file before
# running any of it: editing the script while a run waits for Enter cannot then
# break that run.
{

VERSION="1.0.0"
MR_REPO="fdroid/fdroiddata"
API="https://gitlab.com/api/v4"
PCAP_PKG="com.emanuelef.remote_capture"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/fdroid-tester"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/fdroid-tester"

SERIAL=""; WATCH=15; NO_DEVICE=0; KEEP=0; MR_ARG=""; CHECK_ONLY=0

usage() {
  cat <<EOF
usage: fdroid-tester.sh <merge request link or number> [options]
       fdroid-tester.sh --check [-s SERIAL]

  e.g. fdroid-tester.sh https://gitlab.com/fdroid/fdroiddata/-/merge_requests/38458

options:
  -s SERIAL      the adb device to use, when more than one is connected
  -w SECONDS     how long to watch the app after it opens (default $WATCH)
  --no-device    only download and look inside the APK, no phone needed
  --keep         leave the app installed at the end without asking
  --check        only check the tools, the phone, PCAPdroid and the glab
                 login, then stop
  --version      print the version
  -h, --help     this text

The APK goes into the current folder; the report, screenshots and network
capture into <appid>_<versionCode>-review/ next to it.

Optional keys (one line each, nothing else in the file):
  $CONF/pcapdroid-api-key   PCAPdroid starts without asking on the phone
                            (PCAPdroid → Settings → Control permissions → menu)
  $CONF/virustotal-api-key  only if you already have one: VirusTotal is then
                            scanned in the background instead of opened in
                            your browser
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -s) SERIAL="${2-}"; shift ;;
    -w) WATCH="${2-}"; shift
        case "$WATCH" in ''|*[!0-9]*) printf -- '-w wants a number of seconds\n' >&2; exit 2 ;; esac ;;
    --no-device) NO_DEVICE=1 ;;
    --keep) KEEP=1 ;;
    --check) CHECK_ONLY=1 ;;
    --version) printf 'fdroid-tester %s\n' "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$MR_ARG" ] || { printf 'one merge request at a time\n' >&2; exit 2; }
       MR_ARG="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- presentation
# Section titles in a soft muted teal; what you have to do yourself (on the
# phone, in the browser) in blue, so it stands out from what the script says.
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
  if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    TTL=$'\033[38;5;109m'; BLU=$'\033[1;38;5;75m'
  else
    TTL=$'\033[36m'; BLU=$'\033[1;34m'
  fi
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; TTL=""; BLU=""
fi
step()  { printf '\n%s━━ %s%s\n' "$TTL" "$*" "$R"; }
act()   { printf '   %s➜ %s%s\n' "$BLU" "$*" "$R"; }
say()   { printf '   %s\n' "$*"; }
note()  { printf '   %s%s%s\n' "$DIM" "$*" "$R"; }
warn()  { printf '   %s! %s%s\n' "$YLW" "$*" "$R"; }
ok()    { printf '   %s✓ %s%s\n' "$GRN" "$*" "$R"; }
die()   { printf '\n%sERROR: %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Run with no link: say where to get one, rather than print the options.
if [ -z "$MR_ARG" ] && [ "$CHECK_ONLY" = 0 ]; then
  cat <<EOF

  ${B}Which app do you want to test?${R}

  1. Open F-Droid's list of new apps waiting for a tester:
     ${CYN}https://gitlab.com/fdroid/fdroiddata/-/merge_requests/?sort=created_asc&state=opened&label_name[]=review-requested${R}

  2. Pick one and copy its link from the address bar. It looks like:
     ${CYN}https://gitlab.com/fdroid/fdroiddata/-/merge_requests/38458${R}

  3. Run this script with that link:
     ${B}$0 https://gitlab.com/fdroid/fdroiddata/-/merge_requests/38458${R}

  ${DIM}$0 --check   checks your tools and phone first
  $0 --help    all the options${R}

EOF
  exit 0
fi

readline() {  # readline VAR — false on EOF
  IFS= read -r "$1" && return 0
  printf '\n' >&2
  die "end of input — this script needs an interactive terminal"
}

confirm() {  # confirm "question" [default y|n]
  local q="$1" def="${2:-n}" a="" hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  printf '   %s%s%s %s ' "$B" "$q" "$R" "$hint" >&2
  readline a
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# yns VAR "question" [default y|n|s] — yes, no, or s(kip: not checked)
yns() {
  local __var="$1" q="$2" def="${3:-s}" a=""
  while :; do
    printf '   %s%s%s [y/n/s=skip, Enter=%s] ' "$B" "$q" "$R" "$def" >&2
    readline a
    [ -z "$a" ] && a="$def"
    case "$a" in [yY]*) a=y; break ;; [nN]*) a=n; break ;; [sS]*) a=s; break ;; esac
  done
  printf -v "$__var" '%s' "$a"
}

open_url() {  # open_url <url> — in the default browser; false when there is none
  case "$(uname -s)" in
    Darwin) open "$1" >/dev/null 2>&1 & return 0 ;;
  esac
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || have wslview || return 1
  if have xdg-open; then xdg-open "$1" >/dev/null 2>&1 & return 0; fi
  if have wslview; then wslview "$1" >/dev/null 2>&1 & return 0; fi
  return 1
}

pause() { printf '   %s➜ %s%s ' "$BLU" "$1" "$R" >&2; local _; readline _; }

# ================================================================ 0. checks
# Everything a run leans on, checked before anything is downloaded. A missing
# required tool stops here; a missing phone, PCAPdroid or glab login only turns
# its own part off, and the line says how to fix it.
FAILS=0
row() {  # row ok|warn|fail|info "what" "detail"
  local mark
  case "$1" in
    ok) mark="$GRN✓$R" ;; warn) mark="$YLW!$R" ;; fail) mark="$RED✗$R" ;; *) mark="$DIM·$R" ;;
  esac
  printf '   %s %-11s %s\n' "$mark" "$2" "$3"
  [ "$1" = fail ] && FAILS=$((FAILS + 1))
  return 0
}

find_aapt2() {
  if have aapt2; then command -v aapt2; return 0; fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}" d
  for d in $(ls -d "$sdk"/build-tools/*/ 2>/dev/null | sort -V -r); do
    [ -x "$d/aapt2" ] && { printf '%s' "${d%/}/aapt2"; return 0; }
  done
  return 1
}

sha256() {
  if have sha256sum; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

ADB=(adb); [ -n "$SERIAL" ] && ADB+=(-s "$SERIAL")
ash() { "${ADB[@]}" shell "$@" 2>/dev/null | tr -d '\r'; }

# PCAPdroid records in its CaptureService: running means recording.
capture_running() { ash dumpsys activity services "$PCAP_PKG" | grep -q 'CaptureService'; }
capture_stop() {  # ask PCAPdroid to stop, and wait until it has closed the file
  ash am start -n "$PCAP_PKG/.activities.CaptureCtrl" -e action stop "${KEY[@]}" >/dev/null || true
  for _ in $(seq 1 15); do capture_running || return 0; sleep 1; done
  return 1
}
KEY=()
DEV_ABIS=""; DEV_SDK=""; DEV_DESC=""; PCAP_OK=0; PCAP_NEED=0; CAN_POST=0; EDIT_CMD=""; NO_PHONE_FOUND=0

step "0. Checks"

# --- required
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
  row ok bash "$BASH_VERSION"
else
  row fail bash "$BASH_VERSION — 4.4 or newer is needed (macOS: brew install bash)"
fi
for t in curl unzip; do
  if have "$t"; then row ok "$t" "$(command -v "$t")"; else row fail "$t" "not installed"; fi
done
if have python3 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null; then
  row ok python3 "$(python3 -c 'import platform; print(platform.python_version())')"
else
  row fail python3 "Python 3.6 or newer is needed"
fi
if have sha256sum || have shasum; then row ok sha256 "$(command -v sha256sum || command -v shasum)"
else row fail sha256 "sha256sum (coreutils) or shasum is needed"; fi
if AAPT2="$(find_aapt2)"; then row ok aapt2 "$AAPT2"
else row fail aapt2 "not found — install Android build-tools, or set ANDROID_HOME"; fi
if curl -fsS -m 20 -o /dev/null "$API/projects/${MR_REPO//\//%2F}" 2>/dev/null; then
  row ok gitlab.com "reachable"
else
  row fail gitlab.com "cannot reach $API — check the network"
fi

# --- Exodus tracker list, refreshed weekly
TRK="$CACHE/trackers.json"
mkdir -p "$CACHE"
if [ ! -s "$TRK" ] || [ -n "$(find "$TRK" -mtime +7 2>/dev/null)" ]; then
  if curl -fsS -m 30 -o "$TRK.part" "https://reports.exodus-privacy.eu.org/api/trackers" 2>/dev/null; then
    mv "$TRK.part" "$TRK"
  else
    rm -f "$TRK.part"
  fi
fi
TRK_N="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["trackers"]))' "$TRK" 2>/dev/null || true)"
if [ -n "$TRK_N" ]; then row ok Exodus "$TRK_N trackers in the list"
else row warn Exodus "could not fetch the tracker list — the tracker check is off"; fi

# --- the phone and PCAPdroid
if [ "$NO_DEVICE" = 1 ]; then
  row info phone "skipped (--no-device)"
elif ! have adb; then
  row warn adb "not installed — the phone part is off (install Android platform-tools)"
  NO_PHONE_FOUND=1
else
  "${ADB[@]}" start-server >/dev/null 2>&1 || true
  row ok adb "$(adb version 2>/dev/null | sed -n 's/^Android Debug Bridge version //p')"
  mapfile -t DEVS < <(adb devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 " " $2 }')
  STATE=""
  if [ -n "$SERIAL" ]; then
    for d in "${DEVS[@]}"; do [ "${d% *}" = "$SERIAL" ] && STATE="${d#* }"; done
  elif [ "${#DEVS[@]}" -gt 1 ]; then
    STATE=many
  elif [ "${#DEVS[@]}" = 1 ]; then
    STATE="${DEVS[0]#* }"
  fi
  case "$STATE" in
    device)
      DEV_ABIS="$(ash getprop ro.product.cpu.abilist)"
      DEV_SDK="$(ash getprop ro.build.version.sdk)"
      DEV_DESC="$(ash getprop ro.product.manufacturer) $(ash getprop ro.product.model), Android $(ash getprop ro.build.version.release) (SDK $DEV_SDK)"
      row ok phone "$DEV_DESC — $DEV_ABIS"
      PCAP_INFO="$(ash dumpsys package "$PCAP_PKG")"
      PCAP_VER="$(printf '%s\n' "$PCAP_INFO" | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1)"
      PCAP_CODE="$(printf '%s\n' "$PCAP_INFO" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)"
      if [ -z "$PCAP_CODE" ]; then
        row warn PCAPdroid "not on the phone — the network check needs it"; PCAP_NEED=1
      elif [ "$PCAP_CODE" -lt 62 ]; then
        row warn PCAPdroid "$PCAP_VER is too old to be started from here"; PCAP_NEED=1
      else
        PCAP_OK=1
        if [ -s "$CONF/pcapdroid-api-key" ]; then row ok PCAPdroid "$PCAP_VER, API key set"
        else row ok PCAPdroid "$PCAP_VER — it asks on the phone; an API key skips that (--help)"; fi
      fi ;;
    unauthorized) row fail phone "${SERIAL:-the phone} has not allowed this computer — accept the USB debugging prompt on it" ;;
    offline)      row fail phone "${SERIAL:-the phone} is offline — unplug it and plug it back in" ;;
    many)         row fail phone "${#DEVS[@]} devices connected — pick one with -s: ${DEVS[*]%% *}" ;;
    "")           if [ -n "$SERIAL" ]; then row fail phone "$SERIAL is not connected"
                  else row warn phone "none connected — plug it in with USB debugging on"; NO_PHONE_FOUND=1; fi ;;
    *)            row fail phone "${SERIAL:-the phone} is in state '$STATE'" ;;
  esac
fi

# --- posting the report
if ! have glab; then
  row warn glab "not installed — you paste the report yourself (https://gitlab.com/gitlab-org/cli)"
elif ! glab auth status --hostname gitlab.com >/dev/null 2>&1; then
  row warn glab "not logged in to gitlab.com — run: glab auth login --hostname gitlab.com"
else
  GL_USER="$(glab api user 2>/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin).get("username", ""))' 2>/dev/null || true)"
  if [ -n "$GL_USER" ]; then CAN_POST=1; row ok glab "logged in as @$GL_USER"
  else row warn glab "logged in, but the API refused — the token needs the 'api' scope"; fi
fi
for e in "${VISUAL:-}" "${EDITOR:-}" nano vi; do
  [ -n "$e" ] && have "${e%% *}" && { EDIT_CMD="$e"; break; }
done
if [ -n "$EDIT_CMD" ]; then row ok editor "$EDIT_CMD"
else row warn editor "none found — set EDITOR to edit the report before posting"; fi
if [ -s "$CONF/virustotal-api-key" ]; then row ok VirusTotal "API key set — scanned automatically"
else row ok VirusTotal "opens in your browser at the end — nothing to set up"; fi

if [ "$FAILS" -gt 0 ]; then
  [ "$CHECK_ONLY" = 1 ] && die "$FAILS check(s) failed"
  die "fix the ✗ lines above, then run again"
fi

# PCAPdroid missing or too old: F-Droid is the place to get it, but the latest
# GitHub release can go straight onto the phone from here.
install_pcapdroid() {
  local rel url apk pkg out
  rel="$(curl -fsS -m 30 https://api.github.com/repos/emanuele-f/PCAPdroid/releases/latest 2>/dev/null)" \
    || { warn "could not reach GitHub"; return 1; }
  url="$(printf '%s' "$rel" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print(next((a["browser_download_url"] for a in r.get("assets", []) if a["name"].endswith(".apk")), ""))')"
  [ -n "$url" ] || { warn "the latest PCAPdroid release has no APK"; return 1; }
  apk="$CACHE/${url##*/}"
  if [ ! -s "$apk" ]; then
    say "downloading ${url##*/}"
    if ! curl -fL --progress-bar -o "$apk.part" "$url"; then
      rm -f "$apk.part"; warn "the download failed"; return 1
    fi
    mv "$apk.part" "$apk"
  fi
  pkg="$("$AAPT2" dump badging "$apk" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  if [ "$pkg" != "$PCAP_PKG" ]; then
    rm -f "$apk"; warn "the download is not PCAPdroid (${pkg:-unreadable}) — not installing it"; return 1
  fi
  say "installing ${apk##*/} on the phone…"
  if ! out="$("${ADB[@]}" install -r "$apk" 2>&1)"; then
    if printf '%s' "$out" | grep -q UPDATE_INCOMPATIBLE; then
      warn "the PCAPdroid on the phone is signed by someone else (another store)"
      confirm "Uninstall it and install the GitHub one? (its settings are lost)" n || return 1
      "${ADB[@]}" uninstall "$PCAP_PKG" >/dev/null 2>&1 || true
      out="$("${ADB[@]}" install "$apk" 2>&1)" || { printf '%s\n' "$out" | tail -2 | sed 's/^/     /'; return 1; }
    else
      printf '%s\n' "$out" | tail -2 | sed 's/^/     /'; warn "install failed"; return 1
    fi
  fi
  pkg="${apk##*/PCAPdroid_}"; ok "PCAPdroid ${pkg%.apk} installed"
}
if [ "$PCAP_NEED" = 1 ]; then
  printf '\n'
  say "PCAPdroid records what the app connects to. Install it from F-Droid:"
  act "https://f-droid.org/packages/$PCAP_PKG/"
  if confirm "Or install the latest version from GitHub onto the phone now?" y; then
    install_pcapdroid && PCAP_OK=1 || note "carrying on without the network check"
  fi
fi
if [ "$CHECK_ONLY" = 1 ]; then
  printf '\n'; ok "ready"; exit 0
fi
if [ "$NO_PHONE_FOUND" = 1 ]; then
  confirm "Carry on with the checks that need no phone?" y || exit 1
  NO_DEVICE=1
fi

WORK="$(mktemp -d)"
# The phone stays awake while the script runs, so you can put it down between
# steps; its own "stay awake while charging" setting comes back at the end,
# also after Ctrl+C or an error.
STAYON_OLD=""
keep_awake() {
  STAYON_OLD="$(ash settings get global stay_on_while_plugged_in)"
  case "$STAYON_OLD" in
    ''|*[!0-9]*) STAYON_OLD=""; warn "could not keep the phone awake"; return 0 ;;
  esac
  ash svc power stayon true >/dev/null || true
  ash input keyevent KEYCODE_WAKEUP >/dev/null || true
  ok "the phone stays awake while this runs (back to its own setting at the end)"
}
restore_awake() {
  [ -n "$STAYON_OLD" ] || return 0
  "${ADB[@]}" shell settings put global stay_on_while_plugged_in "$STAYON_OLD" >/dev/null 2>&1 || true
}
trap '[ -n "${VT_PID:-}" ] && kill "$VT_PID" 2>/dev/null; restore_awake; rm -rf "$WORK"' EXIT
[ "$NO_DEVICE" = 0 ] && keep_awake

# The JSON, APK and pcap work is in Python: one helper, several subcommands.
cat > "$WORK/tool.py" <<'PY'
import json, re, struct, sys, zipfile

def out(*cols):
    print("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in cols))

# --- mr <mr.json>: shell assignments
def cmd_mr(path):
    import shlex
    m = json.load(open(path))
    vals = {
        "MR_TITLE": m.get("title", ""), "MR_STATE": m.get("state", ""),
        "MR_AUTHOR": (m.get("author") or {}).get("username", ""),
        "MR_LABELS": ",".join(m.get("labels") or []), "MR_URL": m.get("web_url", ""),
        "MR_SHA": m.get("sha") or "", "MR_SRC": m.get("source_project_id") or "",
    }
    for k, v in vals.items():
        print(f"{k}={shlex.quote(str(v))}")

# --- cq <codequality.json>: APK / PERM / WARN / SUMMARY lines
def cmd_cq(path):
    d = json.load(open(path))
    seen = set()
    for key in ("new_errors", "existing_errors"):
        for e in d.get(key) or []:
            desc = (e.get("description") or "").strip()
            sev = e.get("severity") or "-"
            if desc in seen:
                continue
            seen.add(desc)
            m = re.match(r"(Signed APK|Reproducible build APK): (\S+)", desc)
            if m:
                out("APK", m.group(2)); continue
            if desc.startswith("Permission "):
                out("PERM", sev, desc.split(" ", 1)[1]); continue
            m = re.match(r"Fastlane/Triple-T in en-US: summary \((.*?)\), name", desc)
            if m:
                out("SUMMARY", m.group(1)); continue
            if sev != "info":
                out("WARN", sev, desc[:300])

# --- static <apk> <trackers.json> <abi or ->: what the code holds
NOISE = re.compile(r"""^(schemas\.android\.com|www\.w3\.org|ns\.adobe\.com|xml\.org|
  (www\.)?apache\.org|xmlpull\.org|json-schema\.org|(www\.)?example\.(com|org|net)|
  localhost|schemas\.microsoft\.com|purl\.org|xmlns\.com|schema\.org|(www\.)?xmlsoap\.org|
  .*\.xsd|[0-9.]+|ns\.android\.com|developer\.android\.com|.*\.googlesource\.com|
  (www\.)?opensource\.org|(www\.)?gnu\.org|issuetracker\.google\.com|goo\.gle|
  (www\.)?unicode\.org|(www\.)?ietf\.org|tools\.ietf\.org)$""", re.X)

def flag_host(host, path, net_sigs):
    if host in ("fonts.googleapis.com", "fonts.gstatic.com"):
        return "online fonts"
    if host == "api.github.com" or "/releases/latest" in (path or ""):
        return "update check?"
    if "generate_204" in (path or "") or host.startswith("connectivitycheck."):
        return "connectivity check"
    for name, rx in net_sigs:
        if rx.search(host):
            return "tracker: " + name
    for dom, name in KNOWN:
        if host == dom or host.endswith("." + dom):
            return "tracker: " + name
    return ""

# Well-known tracker addresses the Exodus network rules do not cover.
KNOWN = (("app-measurement.com", "Google Firebase Analytics"), ("crashlytics.com", "Crashlytics"),
         ("doubleclick.net", "Google Ads"), ("googlesyndication.com", "Google Ads"),
         ("googleadservices.com", "Google Ads"), ("graph.facebook.com", "Facebook SDK"))

# Some Exodus network rules are as broad as "\.google\.com"; a rule that also
# matches these ordinary addresses would flag every app, so it is left out.
COMMON = ("www.google.com", "maps.google.com", "fonts.googleapis.com", "www.gstatic.com",
          "github.com", "api.github.com", "www.facebook.com", "play.google.com")

def load_trackers(path):
    code, net = [], []
    try:
        t = json.load(open(path)).get("trackers", {})
    except Exception:
        return code, net
    for tr in t.values():
        for sig, lst in ((tr.get("code_signature"), code), (tr.get("network_signature"), net)):
            if sig and len(sig) > 3:
                try:
                    rx = re.compile(sig, re.M)
                    if lst is net and any(rx.search(h) for h in COMMON):
                        continue
                    lst.append((tr["name"], rx))
                except re.error:
                    pass
    return code, net

def cmd_static(apk, trackers, abi):
    z = zipfile.ZipFile(apk)
    names = z.namelist()
    code_sigs, net_sigs = load_trackers(trackers)
    classes, blobs = set(), []
    for n in names:
        if re.fullmatch(r"classes\d*\.dex", n):
            b = z.read(n); blobs.append(b)
            for m in re.finditer(rb"L([A-Za-z0-9_$/]{3,200});", b):
                classes.add(m.group(1).decode().replace("/", "."))
    if "resources.arsc" in names:
        blobs.append(z.read("resources.arsc"))
    flutter = [n for n in names if n.endswith("/libapp.so")]
    pick = [n for n in flutter if abi != "-" and n.startswith(f"lib/{abi}/")] or flutter[:1]
    for n in pick:
        blobs.append(z.read(n))
    if flutter:
        out("FLUTTER", "yes")
    text = "\n".join(sorted(classes))
    for name, rx in code_sigs:
        m = rx.search(text)
        if m:
            line = text[text.rfind("\n", 0, m.start()) + 1: text.find("\n", m.start())]
            out("TRACKER", name, line)
    for cls, why in (("com.google.android.gms.", "Google Play Services"),
                     ("com.google.firebase.", "Firebase")):
        if cls in text:
            out("NONFREE", why)
    if re.search(r"^android\.webkit\.WebView$", text, re.M):
        out("WEBVIEW", "android.webkit.WebView")
    if re.search(r"^(io\.flutter\.plugins\.webviewflutter|org\.mozilla\.geckoview)\.", text, re.M):
        out("WEBVIEW", "embedded browser library")
    hosts = {}
    for b in blobs:
        for m in re.finditer(rb"https?://([A-Za-z0-9][A-Za-z0-9.-]{2,252}\.[A-Za-z]{2,24})(/[\x21-\x7e]{0,200})?", b):
            host = m.group(1).decode().lower()
            path = (m.group(2) or b"").decode(errors="replace")
            if NOISE.match(host):
                continue
            f = flag_host(host, path, net_sigs)
            if host not in hosts or (f and not hosts[host]):
                hosts[host] = f
        if b"generate_204" in b and not any(v == "connectivity check" for v in hosts.values()):
            out("HINT", "connectivity check", "the code holds 'generate_204'")
    for h in sorted(hosts):
        out("HOST", h, hosts[h])

# --- pcap <file> <t_launch> <t_start_end> <trackers.json>: CONN lines
def dns_name(p, off, depth=0):
    labels = []
    if depth > 10:
        return "", off
    while off < len(p):
        n = p[off]
        if n == 0:
            off += 1; break
        if n & 0xC0 == 0xC0:
            if off + 1 >= len(p): break
            ptr = ((n & 0x3F) << 8) | p[off + 1]
            name, _ = dns_name(p, ptr, depth + 1)
            labels.append(name); off += 2
            return ".".join(l for l in labels if l), off
        labels.append(p[off + 1: off + 1 + n].decode(errors="replace")); off += 1 + n
    return ".".join(labels), off

def parse_dns(p, ipmap, names, ts):
    if len(p) < 12: return
    qd, an = struct.unpack("!HH", p[4:8])
    off, qname = 12, ""
    for _ in range(qd):
        qname, off = dns_name(p, off); off += 4
        if qname: names.setdefault(qname.lower(), ts)
    for _ in range(an):
        if off + 10 > len(p): return
        _, off = dns_name(p, off)
        typ, _, _, rdlen = struct.unpack("!HHIH", p[off:off + 10]); off += 10
        rd = p[off:off + rdlen]; off += rdlen
        if qname and typ == 1 and rdlen == 4:
            ipmap[".".join(map(str, rd))] = qname.lower()
        elif qname and typ == 28 and rdlen == 16:
            import ipaddress
            ipmap[str(ipaddress.IPv6Address(rd))] = qname.lower()

def tls_sni(p):
    try:
        if len(p) < 43 or p[0] != 0x16 or p[5] != 0x01: return None
        off = 43
        off += 1 + p[off]                                   # session id
        off += 2 + struct.unpack("!H", p[off:off + 2])[0]   # cipher suites
        off += 1 + p[off]                                   # compression
        end = off + 2 + struct.unpack("!H", p[off:off + 2])[0]; off += 2
        while off + 4 <= min(end, len(p)):
            et, el = struct.unpack("!HH", p[off:off + 4]); off += 4
            if et == 0:
                n = struct.unpack("!H", p[off + 3:off + 5])[0]
                return p[off + 5:off + 5 + n].decode(errors="replace").lower()
            off += el
    except (IndexError, struct.error):
        pass
    return None

def cmd_pcap(path, t_launch, t_end, trackers):
    import ipaddress
    t_launch, t_end = float(t_launch), float(t_end)
    _, net_sigs = load_trackers(trackers)
    data = open(path, "rb").read()
    if not data:
        out("NONE", "no packets"); return     # the header comes with the first packet
    if len(data) < 24:
        out("ERROR", "the capture file is cut short"); return
    magic = data[:4]
    if magic == b"\x0a\x0d\x0d\x0a":
        out("ERROR", "pcapng is not supported — switch PCAPdroid back to plain PCAP"); return
    end = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    link = struct.unpack(end + "I", data[20:24])[0]
    off, ipmap, names, flows = 24, {}, {}, {}
    while off + 16 <= len(data):
        sec, frac, incl, _ = struct.unpack(end + "IIII", data[off:off + 16]); off += 16
        pkt = data[off:off + incl]; off += incl
        ts = sec + frac / (1e9 if nano else 1e6)
        if link == 1:
            if len(pkt) < 14: continue
            pkt = pkt[14:]
        elif link == 113:
            pkt = pkt[16:]
        if not pkt: continue
        ver = pkt[0] >> 4
        if ver == 4 and len(pkt) >= 20:
            ihl = (pkt[0] & 15) * 4; proto = pkt[9]
            src, dst = str(ipaddress.IPv4Address(pkt[12:16])), str(ipaddress.IPv4Address(pkt[16:20]))
            l4 = pkt[ihl:]
        elif ver == 6 and len(pkt) >= 40:
            proto = pkt[6]
            src, dst = str(ipaddress.IPv6Address(pkt[8:24])), str(ipaddress.IPv6Address(pkt[24:40]))
            l4 = pkt[40:]
        else:
            continue
        if proto == 17 and len(l4) >= 8:
            sp, dp = struct.unpack("!HH", l4[:4]); pay = l4[8:]
            if 53 in (sp, dp):
                parse_dns(pay, ipmap, names, ts); continue
        elif proto == 6 and len(l4) >= 20:
            sp, dp = struct.unpack("!HH", l4[:4]); pay = l4[(l4[12] >> 4) * 4:]
        else:
            continue
        key = (proto, frozenset(((src, sp), (dst, dp))))
        if key not in flows:
            flows[key] = {"ts": ts, "dst": dst, "port": dp, "name": None}
        f = flows[key]
        if pay and not f["name"]:
            sni = tls_sni(pay)
            if sni:
                f["name"] = sni
            else:
                m = re.match(rb"(GET|POST|PUT|HEAD|DELETE|OPTIONS|PATCH) [^\r\n]*\r\n(?:.*\r\n)*?[Hh]ost: ([^\r\n:]+)", pay)
                if m:
                    f["name"] = m.group(2).decode(errors="replace").lower() + " (plain http!)"
    seen = {}
    for f in flows.values():
        name = f["name"] or ipmap.get(f["dst"]) or f"{f['dst']}:{f['port']}"
        seen[name] = min(f["ts"], seen.get(name, f["ts"]))
    for n, ts in names.items():
        if not any(k.startswith(n) for k in seen):
            seen[n + " (looked up)"] = ts
    if not seen:
        out("NONE", "no connections"); return
    for name, ts in sorted(seen.items(), key=lambda kv: kv[1]):
        when = "start" if ts <= t_end else "later"
        out("CONN", when, name, flag_host(name.split(" ")[0], "", net_sigs))

# --- vt <response.json>
def cmd_vt(path):
    a = json.load(open(path)).get("data", {}).get("attributes", {})
    if "last_analysis_stats" in a:        # a file report: already scanned
        st, status = a["last_analysis_stats"], "completed"
    else:                                 # an analysis: queued, in-progress, completed
        st, status = a.get("stats", {}), a.get("status", "queued")
    out("VT", status, st.get("malicious", 0), st.get("suspicious", 0),
        st.get("harmless", 0) + st.get("undetected", 0))

# --- jget <file> <key path…>: one value out of a JSON file
def cmd_jget(path, *keys):
    v = json.load(open(path))
    for k in keys:
        v = v.get(k, {}) if isinstance(v, dict) else {}
    print(v if isinstance(v, str) else "")

# --- cats <metadata.yml>
def cmd_cats(path):
    cats, on = [], False
    for line in open(path, encoding="utf-8", errors="replace"):
        if re.match(r"^Categories:", line):
            on = True; continue
        if on:
            m = re.match(r"^\s*-\s*(.+?)\s*$", line)
            if m: cats.append(m.group(1)); continue
            break
    print(", ".join(cats))

{"mr": cmd_mr, "cq": cmd_cq, "static": cmd_static, "pcap": cmd_pcap,
 "vt": cmd_vt, "jget": cmd_jget, "cats": cmd_cats}[sys.argv[1]](*sys.argv[2:])
PY
tool() { python3 "$WORK/tool.py" "$@"; }

# ================================================================ 1. the MR
step "1. Merge request"
case "$MR_ARG" in
  *[!0-9]*) IID="$(printf '%s' "$MR_ARG" | sed -nE 's#^(https?://)?gitlab\.com/fdroid/fdroiddata/-/merge_requests/([0-9]+).*#\2#p')" ;;
  *) IID="$MR_ARG" ;;
esac
[ -n "$IID" ] || die "not an fdroiddata merge request: $MR_ARG"

curl -fsS "$API/projects/${MR_REPO//\//%2F}/merge_requests/$IID" -o "$WORK/mr.json" \
  || die "could not read merge request !$IID from gitlab.com"
eval "$(tool mr "$WORK/mr.json")"
say "${B}!$IID${R} $MR_TITLE"
note "by @$MR_AUTHOR — $MR_URL"
[ "$MR_STATE" = opened ] || warn "this merge request is $MR_STATE — testing it helps nobody now"
case ",$MR_LABELS," in
  *,review-requested,*) ok "labelled review-requested: waiting for a tester" ;;
  *) note "labels: ${MR_LABELS:-none}" ;;
esac

# GitLab builds the report on request: 204 means "ask again in a moment".
say "reading the Code Quality report…"
CQ_URL="https://gitlab.com/$MR_REPO/-/merge_requests/$IID/codequality_reports.json"
CQ_OK=0
for _ in $(seq 1 20); do
  code="$(curl -sS -o "$WORK/cq.json" -w '%{http_code}' "$CQ_URL" || true)"
  [ "$code" = 200 ] && { CQ_OK=1; break; }
  [ "$code" = 204 ] || break
  sleep 3
done
[ "$CQ_OK" = 1 ] || die "no Code Quality report for !$IID (HTTP $code) — has its pipeline run?"

APK_URLS=(); CI_PERMS=(); CI_WARN=(); SUMMARY=""
while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    APK)     APK_URLS+=("$a") ;;
    PERM)    CI_PERMS+=("$b") ;;
    WARN)    CI_WARN+=("$a: $b") ;;
    SUMMARY) SUMMARY="$a" ;;
  esac
done < <(tool cq "$WORK/cq.json")

if [ "${#CI_WARN[@]}" -gt 0 ]; then
  warn "CI warnings the maintainers will also see:"
  printf '%s\n' "${CI_WARN[@]}" | sed 's/^/       /'
fi
[ "${#APK_URLS[@]}" -gt 0 ] || die "the report has no APK — the 'fdroid build' job failed or has not run; nothing to test yet"
ok "${#APK_URLS[@]} APK(s) in the report"

# ================================================================ 2. APK
step "2. APK"
apk_abis() { unzip -Z1 "$1" 2>/dev/null | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u | tr '\n' ' '; }

# rank <apk abis> — 0 for no native code, else where the best shared ABI sits
# in the phone's list (1 = its main one); nothing if they share none
rank() {
  local i=1 a
  [ -z "${1// /}" ] && { echo 0; return; }
  [ -z "$DEV_ABIS" ] && { echo 1; return; }
  for a in ${DEV_ABIS//,/ }; do
    case " $1 " in *" $a "*) echo "$i"; return ;; esac
    i=$((i + 1))
  done
}

APK=""; BEST=999; APK_ABIS=""
for url in "${APK_URLS[@]}"; do
  f="$PWD/${url##*/}"
  if [ -s "$f" ] && unzip -Z1 "$f" >/dev/null 2>&1; then
    note "already here: ${f##*/}"
  else
    say "downloading ${f##*/}"
    if ! curl -fL --progress-bar -o "$f.part" "$url"; then
      rm -f "$f.part"
      warn "could not download it — CI artifacts expire; ask the author to re-run the pipeline"
      continue
    fi
    mv "$f.part" "$f"
  fi
  abis="$(apk_abis "$f")"; r="$(rank "$abis")"
  note "  native code: ${abis:-none}"
  if [ -n "$r" ] && [ "$r" -lt "$BEST" ]; then APK="$f"; BEST="$r"; APK_ABIS="$abis"; fi
done
[ -n "$APK" ] || die "none of the APKs runs on this phone ($DEV_ABIS)"
ok "testing ${APK##*/}"

BADGING="$("$AAPT2" dump badging "$APK" 2>/dev/null)" || die "aapt2 could not read the APK"
bget() { printf '%s\n' "$BADGING" | sed -n "$1" | head -1; }
APPID="$(bget "s/^package: name='\([^']*\)'.*/\1/p")"
VCODE="$(bget "s/^package: .*versionCode='\([^']*\)'.*/\1/p")"
VNAME="$(bget "s/^package: .*versionName='\([^']*\)'.*/\1/p")"
MINSDK="$(bget "s/^minSdkVersion:'\([^']*\)'.*/\1/p")"
TGTSDK="$(bget "s/^targetSdkVersion:'\([^']*\)'.*/\1/p")"
LABEL="$(bget "s/^application-label:'\(.*\)'$/\1/p")"
LOCALES="$(bget "s/^locales: //p" | tr -d "'")"
mapfile -t PERMS < <(printf '%s\n' "$BADGING" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p")
MANIFEST="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null || true)"
SHA256="$(sha256 "$APK")"

OUT="$PWD/${APPID}_${VCODE}-review"
mkdir -p "$OUT"
cp "$WORK/cq.json" "$OUT/codequality.json"
say "${B}$LABEL${R} $APPID $VNAME ($VCODE) — minSdk $MINSDK, targetSdk $TGTSDK"
note "sha256 $SHA256"

if [ -n "$DEV_SDK" ] && [ -n "$MINSDK" ] && [ "$MINSDK" -gt "$DEV_SDK" ]; then
  die "the app needs Android SDK $MINSDK, the phone has $DEV_SDK"
fi

# ---- permissions
step "3. Inside the APK"
SPECIAL='MANAGE_EXTERNAL_STORAGE|QUERY_ALL_PACKAGES|REQUEST_INSTALL_PACKAGES|ACCESS_BACKGROUND_LOCATION|SYSTEM_ALERT_WINDOW|WRITE_SETTINGS|PACKAGE_USAGE_STATS|READ_LOGS|BIND_ACCESSIBILITY_SERVICE|BIND_DEVICE_ADMIN'
RUNTIME='CAMERA|RECORD_AUDIO|_LOCATION$|_CONTACTS$|GET_ACCOUNTS|_CALENDAR$|_SMS$|RECEIVE_MMS|RECEIVE_WAP_PUSH|READ_PHONE_STATE|READ_PHONE_NUMBERS|CALL_PHONE|ANSWER_PHONE_CALLS|_CALL_LOG$|ADD_VOICEMAIL|USE_SIP|BODY_SENSORS|ACTIVITY_RECOGNITION|READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|READ_MEDIA_|BLUETOOTH_(SCAN|CONNECT|ADVERTISE)|NEARBY_WIFI_DEVICES|UWB_RANGING|POST_NOTIFICATIONS'
P_SPECIAL=(); P_RUNTIME=(); HAS_INTERNET=0
for p in "${PERMS[@]}"; do
  short="${p#android.permission.}"
  [ "$short" = INTERNET ] && HAS_INTERNET=1
  if [[ "$p" == android.permission.* ]] && [[ "$short" =~ ^($SPECIAL)$ ]]; then P_SPECIAL+=("$short")
  elif [[ "$p" == android.permission.* ]] && [[ "$short" =~ ($RUNTIME) ]]; then P_RUNTIME+=("$short"); fi
done
say "${#PERMS[@]} permissions"
if [ "${#P_SPECIAL[@]}" -gt 0 ]; then
  warn "special permissions reviewers question: ${P_SPECIAL[*]}"
  case " ${P_SPECIAL[*]} " in *" MANAGE_EXTERNAL_STORAGE "*)
    note "MANAGE_EXTERNAL_STORAGE: the Storage Access Framework should be used where it can" ;; esac
fi
[ "${#P_RUNTIME[@]}" -gt 0 ] && note "asked at runtime: ${P_RUNTIME[*]}"
[ "$HAS_INTERNET" = 1 ] && note "INTERNET — the network check below matters" || ok "no INTERNET permission"

DEBUGGABLE=0; CLEARTEXT=0; TESTONLY=0
printf '%s\n' "$BADGING" | grep -q '^application-debuggable' && DEBUGGABLE=1
printf '%s\n' "$MANIFEST" | grep -qE 'debuggable\([^)]*\)=(true|0xffffffff)' && DEBUGGABLE=1
printf '%s\n' "$MANIFEST" | grep -qE 'usesCleartextTraffic\([^)]*\)=(true|0xffffffff)' && CLEARTEXT=1
printf '%s\n' "$MANIFEST" | grep -qE 'testOnly\([^)]*\)=(true|0xffffffff)' && TESTONLY=1
[ "$DEBUGGABLE" = 1 ] && warn "the APK is debuggable"
[ "$TESTONLY" = 1 ]   && warn "the APK is marked testOnly"
[ "$CLEARTEXT" = 1 ]  && warn "plain http allowed (usesCleartextTraffic)"

# ---- languages
HAS_EN=n
case " $LOCALES " in *" en "*|*" en-"*|*" en_"*) HAS_EN=y ;; esac
if [ "$HAS_EN" = y ]; then ok "has English strings"
else note "languages: ${LOCALES:-unknown} — check on the phone whether the default one is English"; fi

# ---- trackers, addresses in the code, WebView
PRIMARY_ABI="-"
for a in ${DEV_ABIS//,/ }; do case " $APK_ABIS " in *" $a "*) PRIMARY_ABI="$a"; break ;; esac; done
S_TRACKERS=(); S_NONFREE=(); S_HOSTS=(); S_WEBVIEW=""; S_HINTS=(); FLUTTER=0
while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    TRACKER) S_TRACKERS+=("$a ($b)") ;;
    NONFREE) S_NONFREE+=("$a") ;;
    WEBVIEW) S_WEBVIEW="${S_WEBVIEW:+$S_WEBVIEW, }$a" ;;
    HOST)    S_HOSTS+=("$a${b:+  ← $b}") ;;
    HINT)    S_HINTS+=("$a: $b") ;;
    FLUTTER) FLUTTER=1 ;;
  esac
done < <(tool static "$APK" "$TRK" "$PRIMARY_ABI")

[ "$FLUTTER" = 1 ] && note "Flutter app — addresses also read from libapp.so"
if [ "${#S_TRACKERS[@]}" -gt 0 ]; then
  warn "tracker code (Exodus list):"; printf '%s\n' "${S_TRACKERS[@]}" | sed 's/^/       /'
else ok "no tracker code from the Exodus list"; fi
[ "${#S_NONFREE[@]}" -gt 0 ] && warn "non-free libraries: ${S_NONFREE[*]}"
[ -n "$S_WEBVIEW" ] && note "uses a WebView ($S_WEBVIEW) — see whether links open inside the app"
for h in "${S_HINTS[@]}"; do note "$h"; done
if [ "${#S_HOSTS[@]}" -gt 0 ]; then
  say "web addresses in the code (not necessarily contacted):"
  printf '%s\n' "${S_HOSTS[@]}" | head -40 | sed 's/^/       /'
  [ "${#S_HOSTS[@]}" -gt 40 ] && note "  …and $(( ${#S_HOSTS[@]} - 40 )) more"
fi

# ---- VirusTotal
# Without anything to set up, the security question opens VirusTotal's page for
# this APK in the browser. Someone who already has a VirusTotal API key gets it
# fully automatic: the APK is looked up by its hash and, if unknown, uploaded
# (after a yes) and scanned in the background. Uploads are shared with
# VirusTotal's partners — these APKs are public CI downloads anyway. A free key
# allows 4 requests a minute, so the scan is checked every 20 seconds.
VT_LINK="https://www.virustotal.com/gui/file/$SHA256"
VT_API="https://www.virustotal.com/api/v3"
VT_KEY_FILE="$CONF/virustotal-api-key"
VT_RESULT=""; VT_MAL=""; VT_STATUS=""
VT_KEY=""; [ -s "$VT_KEY_FILE" ] && VT_KEY="$(head -1 "$VT_KEY_FILE" | tr -d '[:space:]')"
vt_get() {  # vt_get <api path> — JSON to $WORK/vt.json, prints the HTTP code
  curl -sS -m 60 -o "$WORK/vt.json" -w '%{http_code}' -H "x-apikey: $VT_KEY" "$VT_API/$1" 2>/dev/null || true
}
vt_read() { IFS=$'\t' read -r _ VT_STATUS VT_MAL VT_SUS VT_CLEAN < <(tool vt "$WORK/vt.json"); }
vt_show() {
  VT_RESULT="$VT_MAL malicious, $VT_SUS suspicious, $VT_CLEAN clean"
  if [ "$VT_MAL" = 0 ]; then ok "VirusTotal: $VT_RESULT"; else warn "VirusTotal: $VT_RESULT"; fi
}
# vt_scan — upload the APK and wait for its scan. It runs in the background
# while you test the app, says nothing, and leaves one line in vt-result:
# the scan's "VT …" line, or "ERR <why>".
vt_scan() {
  local url="$VT_API/files" aid code
  if [ "$(wc -c < "$APK")" -gt 33554432 ]; then     # over 32 MB: a one-time upload URL
    [ "$(vt_get files/upload_url)" = 200 ] && url="$(tool jget "$WORK/vt.json" data)"
  fi
  code="$(curl -sS -m 900 -o "$WORK/vtup.json" -w '%{http_code}' -H "x-apikey: $VT_KEY" \
          -F "file=@$APK" "$url" 2>/dev/null || true)"
  aid="$(tool jget "$WORK/vtup.json" data id 2>/dev/null || true)"
  if [ "$code" != 200 ] || [ -z "$aid" ]; then
    printf 'ERR\tthe upload failed (HTTP %s)\n' "$code" > "$WORK/vt-result"; return 0
  fi
  for _ in $(seq 1 45); do                          # 20 s apart, up to 15 minutes
    sleep 20
    [ "$(vt_get "analyses/$aid")" = 200 ] || continue
    if tool vt "$WORK/vt.json" > "$WORK/vt-result.part" \
       && grep -q $'^VT\tcompleted\t' "$WORK/vt-result.part"; then
      mv "$WORK/vt-result.part" "$WORK/vt-result"; return 0
    fi
  done
  printf 'ERR\tthe scan took longer than 15 minutes\n' > "$WORK/vt-result"
}
# vt_collect — pick up the background scan's result. If it is still running,
# wait for it, or skip it with Enter: the scan goes on at VirusTotal, and the
# security question is asked by hand instead.
vt_collect() {
  local rc kind a b c d
  [ -n "$VT_PID" ] || return 0
  if [ ! -s "$WORK/vt-result" ] && kill -0 "$VT_PID" 2>/dev/null; then
    say "VirusTotal is still scanning ${APK##*/}…"
    act "press Enter to skip it and check the link by hand, or just wait"
    while kill -0 "$VT_PID" 2>/dev/null; do
      if read -r -t 5 _; then
        kill "$VT_PID" 2>/dev/null || true; wait "$VT_PID" 2>/dev/null || true
        VT_PID=""; note "skipped — the scan goes on at $VT_LINK"; return 0
      else
        rc=$?; [ "$rc" -gt 128 ] || sleep 5        # no terminal to read: just wait
      fi
    done
  fi
  wait "$VT_PID" 2>/dev/null || true; VT_PID=""
  if [ -s "$WORK/vt-result" ]; then
    IFS=$'\t' read -r kind a b c d < "$WORK/vt-result"
    if [ "$kind" = VT ]; then VT_STATUS="$a"; VT_MAL="$b"; VT_SUS="$c"; VT_CLEAN="$d"; vt_show
    else warn "VirusTotal: $a — see $VT_LINK"; fi
  else
    warn "the VirusTotal scan stopped — see $VT_LINK"
  fi
}
VT_PID=""
if [ -n "$VT_KEY" ]; then
  code="$(vt_get "files/$SHA256")"
  case "$code" in
    200) vt_read; [ "$VT_STATUS" = completed ] && vt_show ;;
    404) if confirm "VirusTotal has not seen this APK — upload it for a scan?" y; then
           vt_scan </dev/null >/dev/null 2>&1 &
           VT_PID=$!
           ok "uploading and scanning in the background — carry on, the result comes in later"
         else
           note "not uploaded — you can check it by hand: $VT_LINK"
         fi ;;
    401|403) warn "VirusTotal refused the API key — fix $VT_KEY_FILE" ;;
    429) warn "VirusTotal's rate limit is reached (free key: 4 a minute, 500 a day)" ;;
    *)   warn "VirusTotal lookup failed (HTTP $code)" ;;
  esac
else
  note "VirusTotal: checked at the end, in your browser"
fi

# ---- categories, from the metadata in the MR
CATS=""
if [ -n "$MR_SRC" ] && [ -n "$MR_SHA" ]; then
  if curl -fsS -o "$WORK/meta.yml" \
       "$API/projects/$MR_SRC/repository/files/metadata%2F$APPID.yml/raw?ref=$MR_SHA" 2>/dev/null; then
    cp "$WORK/meta.yml" "$OUT/$APPID.yml"
    CATS="$(tool cats "$WORK/meta.yml")"
    say "categories: ${CATS:-none set}"
  fi
fi

# ================================================================ 4. on the phone
CRASHED=n; START_PROMPT=""; CONN_START=(); CONN_LATER=(); CAPTURED=n; PCAP_ERR=""
SHOT=""
if [ "$NO_DEVICE" = 0 ]; then
  step "4. On the phone"
  # The app and PCAPdroid's prompts would open behind the lock screen.
  phone_locked() {
    { ash dumpsys window; ash dumpsys activity activities; } \
      | grep -qE '(mKeyguardShowing|isKeyguardShowing|mShowingLockscreen|mDreamingLockscreen)=true'
  }
  if phone_locked; then
    ash input keyevent KEYCODE_WAKEUP >/dev/null || true
    act "unlock the phone — waiting…"
    for _ in $(seq 1 120); do phone_locked || break; sleep 1; done
    if phone_locked; then warn "the phone still looks locked — the app may open behind the lock screen"
    else ok "unlocked"; fi
  fi
  if [ -n "$(ash pm path "$APPID")" ]; then
    warn "$APPID is already installed"
    if confirm "Uninstall it first, for a clean first start? (its data is deleted)" y; then
      "${ADB[@]}" uninstall "$APPID" >/dev/null || die "could not uninstall it"
    fi
  fi
  say "installing…"
  if ! "${ADB[@]}" install -r "$APK" > "$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" | sed 's/^/     /'
    grep -q UPDATE_INCOMPATIBLE "$WORK/install.log" \
      && die "a copy signed with another key is installed — uninstall it and run again"
    die "install failed"
  fi
  ok "installed"

  # PCAPdroid records only this app's traffic into Download/PCAPdroid/.
  PCAP_NAME="fdroid-tester-$APPID.pcap"
  if [ "$HAS_INTERNET" = 1 ]; then
    if [ "$PCAP_OK" = 1 ]; then
      KEY=(); [ -s "$CONF/pcapdroid-api-key" ] && KEY=(-e api_key "$(head -1 "$CONF/pcapdroid-api-key")")
      ash rm -f "/sdcard/Download/PCAPdroid/$PCAP_NAME" || true
      if capture_running; then
        warn "PCAPdroid is already recording — stopping it, so this run gets its own capture"
        capture_stop
      fi
      ash am start -n "$PCAP_PKG/.activities.CaptureCtrl" -e action start \
        -e pcap_dump_mode pcap_file -e pcap_name "$PCAP_NAME" -e app_filter "$APPID" \
        -e block_quic always -e auto_block_private_dns true "${KEY[@]}" >/dev/null
      if [ "${#KEY[@]}" -eq 0 ]; then
        act "on the phone: allow PCAPdroid's control prompt (and the VPN prompt, the first time)"
        note "tip: an API key in $CONF/pcapdroid-api-key skips the first prompt (see --help)"
      fi
      say "waiting for PCAPdroid to start recording…"
      for _ in $(seq 1 90); do capture_running && break; sleep 1; done
      if capture_running; then
        CAPTURED=y; ok "PCAPdroid is recording"
      else
        warn "PCAPdroid did not start within 90 seconds"
        confirm "Carry on without the network check?" y || die "start PCAPdroid once by hand, then run again"
      fi
    else
      warn "no network check — PCAPdroid is missing or too old (see the checks at the top)"
    fi
  fi

  "${ADB[@]}" logcat -c 2>/dev/null || true
  T_LAUNCH="$(ash date +%s)"
  if "${ADB[@]}" shell monkey -p "$APPID" -c android.intent.category.LAUNCHER 1 2>&1 | grep -q 'No activities found'; then
    warn "the app has no launcher icon to open — open it by hand"
  fi
  act "watching the first $WATCH seconds — don't touch the phone yet"
  for _ in $(seq 1 "$WATCH"); do
    sleep 1
    if [ -z "$START_PROMPT" ] && ash dumpsys window | grep -E 'mCurrentFocus=' | grep -q GrantPermissionsActivity; then
      ash uiautomator dump /sdcard/fdroid-tester.xml >/dev/null || true
      START_PROMPT="$(ash cat /sdcard/fdroid-tester.xml \
        | grep -oE 'text="[^"]*" resource-id="[^"]*permission_message"' \
        | sed -E 's/^text="([^"]*)".*/\1/' | head -1)"
      ash rm -f /sdcard/fdroid-tester.xml || true
      START_PROMPT="${START_PROMPT:-a permission prompt}"
      "${ADB[@]}" exec-out screencap -p > "$OUT/permission-on-start.png" 2>/dev/null || true
    fi
  done
  T_END="$(ash date +%s)"
  SHOT="$OUT/after-${WATCH}s.png"
  "${ADB[@]}" exec-out screencap -p > "$SHOT" 2>/dev/null || SHOT=""

  if [ -z "$(ash pidof "$APPID")" ] || "${ADB[@]}" logcat -d -b crash 2>/dev/null | grep -q "Process: $APPID"; then
    CRASHED=y
    "${ADB[@]}" logcat -d -b crash > "$OUT/crash.log" 2>/dev/null || true
    warn "the app is not running after $WATCH seconds — it probably crashed (crash.log saved)"
  else
    ok "still running after $WATCH seconds"
  fi
  if [ -n "$START_PROMPT" ]; then
    warn "asks for a permission on start: \"$START_PROMPT\""
    note "only permissions the basic function needs belong at start"
  else
    ok "no permission prompt on start"
  fi

  SAYS=""; [ -n "$SUMMARY" ] && SAYS="It says: \"$SUMMARY\""
  cat <<EOF

   ${BLU}➜ Now use the app.${R} $SAYS
     ${BLU}- try the main features from its description
     - deny the optional permissions: does it still work?
     - look for terms to accept, ads, paid unlocks, sign-in walls
     - open links (author, help, donate): browser, or a view inside the app?
     - look at its settings: language, update checks, online features${R}

EOF
  pause "Press Enter when you are done…"

  if [ "$CRASHED" = n ] && "${ADB[@]}" logcat -d -b crash 2>/dev/null | grep -q "Process: $APPID"; then
    "${ADB[@]}" logcat -d -b crash > "$OUT/crash.log" 2>/dev/null || true
    warn "it crashed while you used it (crash.log saved)"
    CRASHED=later
  fi

  if [ "$CAPTURED" = y ]; then
    capture_stop || warn "PCAPdroid is still recording — stop it in the app; the file may be cut short"
    if "${ADB[@]}" pull "/sdcard/Download/PCAPdroid/$PCAP_NAME" "$OUT/traffic.pcap" >/dev/null 2>&1; then
      ash rm -f "/sdcard/Download/PCAPdroid/$PCAP_NAME" || true
      while IFS=$'\t' read -r kind a b c; do
        case "$kind" in
          CONN) [ "$a" = start ] && CONN_START+=("$b${c:+  ← $c}") || CONN_LATER+=("$b${c:+  ← $c}") ;;
          ERROR) PCAP_ERR="$a" ;;
        esac
      done < <(tool pcap "$OUT/traffic.pcap" "$T_LAUNCH" "$T_END" "$TRK")
      if [ -n "$PCAP_ERR" ]; then
        warn "$PCAP_ERR — the network questions below are asked instead"
      else
        if [ "${#CONN_START[@]}" -gt 0 ]; then
          warn "connections in the first $WATCH seconds:"; printf '%s\n' "${CONN_START[@]}" | sed 's/^/       /'
        else ok "no connections on start"; fi
        if [ "${#CONN_LATER[@]}" -gt 0 ]; then
          say "connections while you used it:"; printf '%s\n' "${CONN_LATER[@]}" | sed 's/^/       /'
        fi
        [ "${#CONN_START[@]}" -eq 0 ] && [ "${#CONN_LATER[@]}" -eq 0 ] \
          && warn "no traffic at all — the author may be able to drop the INTERNET permission"
      fi
    else
      CAPTURED=n
      warn "could not fetch the capture from Download/PCAPdroid/ — was it running?"
    fi
  fi
fi

# ================================================================ 5. questions
# Every box in the report gets an answer: what this run measured fills its box
# by itself, and everything else is asked here. "s" still leaves a box
# unticked and marked (not checked), for when you really could not tell.
step "5. What you saw"
yes_if() { [ "$1" -gt 0 ] && echo y || echo n; }

NET_SEEN=s; NET_START=s; NET_EXTRA=s; NET_TRACK=s
if [ "$CAPTURED" = y ] && [ -z "$PCAP_ERR" ]; then
  NET_SEEN="$(yes_if $(( ${#CONN_START[@]} + ${#CONN_LATER[@]} )))"
  NET_START="$(yes_if "${#CONN_START[@]}")"
  NET_EXTRA="$(yes_if "$(printf '%s\n' "${CONN_START[@]}" "${CONN_LATER[@]}" | grep -cE 'online fonts|connectivity check' || true)")"
  NET_TRACK="$(yes_if "$(printf '%s\n' "${CONN_START[@]}" "${CONN_LATER[@]}" | grep -c 'tracker:' || true)")"
fi
[ "${#S_TRACKERS[@]}" -gt 0 ] && NET_TRACK=y
MSTORAGE=y; case " ${P_SPECIAL[*]} " in *" MANAGE_EXTERNAL_STORAGE "*) MSTORAGE=s ;; esac
vt_collect
VT_OK=s; [ -n "$VT_RESULT" ] && [ "$VT_MAL" = 0 ] && VT_OK=y

[ "$NO_DEVICE" = 1 ] && act "no phone in this run — answer from what you saw on a device, or s to skip"

say "${B}Basic function${R}"
def=y; [ "$CRASHED" = n ] || def=n
yns Q_WORKS    "Did it start and work normally?" "$def"
yns Q_FEATURES "Do the main features from its description work?" y
yns Q_ICON     "Does it have its own icon (not the stock Android/Flutter one)?" y
WORKS="$Q_WORKS"; [ "$CRASHED" = n ] || WORKS=n

say "${B}Policy${R}"
yns Q_POLICY   "Anything against the Inclusion Policy (ads, paid unlock, non-free service)?" n
if [ -n "$CATS" ]; then yns Q_CATS "Do the categories fit ($CATS)?" y
else yns Q_CATS "The metadata sets no categories — is that right?" n; fi
yns Q_TERMS    "Did it ask you to accept terms other than the FOSS license?" n

say "${B}Permissions${R}"
yns Q_OPTIONAL "Does it work without the optional permissions?" y
if [ "$MSTORAGE" = s ]; then
  note "it asks for MANAGE_EXTERNAL_STORAGE (access to all files)"
  yns MSTORAGE "Is that really needed — could the system file picker (SAF) not do the job?" n
fi

NET_UNCLEAR=s; Q_WEBVIEW=s; Q_UPDATE=s
if [ "$HAS_INTERNET" = 1 ]; then
  say "${B}Network${R}"
  [ "$NET_SEEN" = s ] && yns NET_SEEN \
    "Did the app connect to anything at all?" "$([ "${#S_HOSTS[@]}" -gt 0 ] && echo y || echo n)"
  [ "$NET_START" = s ] && yns NET_START "Did it connect to anything as soon as it opened, before you did anything?" n
  def=n; printf '%s\n' "${CONN_START[@]}" "${CONN_LATER[@]}" | grep -q 'update check' && def=y
  yns Q_UPDATE   "Does it check for updates by itself?" "$def"
  [ "$NET_EXTRA" = s ] && yns NET_EXTRA "Did it load fonts or icons online, or ping a server just to test the connection?" n
  [ "$NET_TRACK" = s ] && yns NET_TRACK "Did it contact any tracking or analytics service?" n
  if [ "$CAPTURED" = y ] && [ -z "$PCAP_ERR" ] && [ $(( ${#CONN_START[@]} + ${#CONN_LATER[@]} )) -gt 0 ]; then
    note "what it connected to:"
    printf '%s\n' "${CONN_START[@]}" "${CONN_LATER[@]}" | sed 's/^/       /'
  elif [ "${#S_HOSTS[@]}" -gt 0 ]; then
    note "addresses in its code:"
    printf '%s\n' "${S_HOSTS[@]}" | head -20 | sed 's/^/       /'
  fi
  [ -n "$SUMMARY" ] && note "its summary: $SUMMARY"
  yns NET_UNCLEAR "Is any of these connections not explained in its description?" n
  yns Q_WEBVIEW  "Did a link (author page, help…) open inside the app instead of the browser?" n
fi

say "${B}Language${R}"
yns Q_EN       "Is it usable in English?" y

if [ "$VT_OK" = s ]; then
  say "${B}Security scan${R}"
  if [ -n "$VT_RESULT" ]; then
    # a scanner or two flagging an open source app is usually a false alarm
    note "VirusTotal: $VT_RESULT — $VT_LINK"
    yns VT_OK "Do all or most scanners say it is clean?" "$([ "$VT_MAL" -le 2 ] && echo y || echo n)"
  else
    if open_url "$VT_LINK"; then act "VirusTotal is open in your browser"
    else act "open $VT_LINK"; fi
    act "if it says the file is unknown, drag this file onto the page:"
    note "  $APK"
    yns VT_OK "Do all or most scanners say it is clean?" y
  fi
fi

# Free text for what the boxes do not cover: one line after another, an empty
# line ends it. It goes into the report between the checklist and the details.
say "${B}Anything else${R}"
printf '   %sIs there anything you want to add to the report?%s\n' "$B" "$R" >&2
note "type it line by line, then Enter on an empty line — or just Enter to skip"
TESTER_NOTES=""
while :; do
  printf '   > ' >&2
  readline line
  [ -z "$line" ] && break
  TESTER_NOTES="$TESTER_NOTES$line"$'\n'
done
[ -n "$TESTER_NOTES" ] && ok "added to the report"

# ================================================================ 6. report
box() {  # box <condition y|n|s> <text> — ticked when the condition is y
  case "$1" in
    y) printf -- '- [x] %s\n' "$2" ;;
    n) printf -- '- [ ] %s\n' "$2" ;;
    *) printf -- '- [ ] %s _(not checked)_\n' "$2" ;;
  esac
}
neg() { case "$1" in y) echo n ;; n) echo y ;; *) echo s ;; esac; }

REPORT="$OUT/report.md"
{
  printf 'Tested `%s` %s (%s)' "$APPID" "$VNAME" "$VCODE"
  [ -n "$DEV_DESC" ] && printf ' on %s' "$DEV_DESC"
  printf '.\n\n<table>\n<thead>\n<tr>\n<th>Category</th>\n<th>Checklist</th>\n</tr>\n</thead>\n<tbody>\n'
  printf '<tr>\n<td>Basic Function</td>\n<td>\n\n'
  box "$WORKS"      "The app can start and work normally."
  box "$Q_FEATURES" "The functions in the description are implemented."
  box "$Q_ICON"     "The app has a unique icon (instead of a default one)."
  printf '\n</td>\n</tr>\n<tr>\n<td>Policy Compliance</td>\n<td>\n\n'
  box "$(neg "$Q_POLICY")" "Features don't violate F-Droid's Inclusion Policy."
  box "$Q_CATS"            "The Categories field is set properly."
  box "$(neg "$Q_TERMS")"  "Doesn't require accepting any terms other than the FOSS license."
  printf '\n</td>\n</tr>\n<tr>\n<td>Permissions</td>\n<td>\n\n'
  box "$Q_OPTIONAL" "The app can be used without granting optional runtime permissions."
  box "$MSTORAGE"   "The app doesn't require unnecessary MANAGE_EXTERNAL_STORAGE permission."
  printf '\n</td>\n</tr>\n<tr>\n<td>Network Connections</td>\n<td>\n\n'
  if [ "$HAS_INTERNET" = 0 ]; then
    printf -- '- No `INTERNET` permission.\n'
  else
    box "$NET_SEEN"  "Network connection is observed."
    box "$NET_START" "The app connects to web services on start."
    box "$Q_UPDATE"  "The app checks for update automatically."
    box "$NET_EXTRA" "The app has unnecessary connections (online fonts, icons, connectivity check)."
    box "$NET_TRACK" "Tracking domains connected."
    box "$NET_UNCLEAR" "Connections not described clearly in description."
    box "$Q_WEBVIEW" "Unnecessary in-app webview presents in the app."
  fi
  printf '\n</td>\n</tr>\n<tr>\n<td>Language Support</td>\n<td>\n\n'
  box "$Q_EN" "The app has English support."
  printf '\n</td>\n</tr>\n<tr>\n<td>Security Scan</td>\n<td>\n\n'
  box "$VT_OK" "All or most vendors on VirusTotal or similar scanning services indicate the app is benign."
  printf '\n</td>\n</tr>\n</tbody>\n</table>\n\n'
  if [ -n "$TESTER_NOTES" ]; then
    # two trailing spaces keep each line on its own line in Markdown
    printf '**Notes from the tester:**\n\n'
    printf '%s' "$TESTER_NOTES" | sed 's/$/  /'
    printf '\n'
  fi

  printf '<details>\n<summary>Details</summary>\n\n'
  printf -- '- APK: `%s` (sha256 `%s`)\n' "${APK##*/}" "$SHA256"
  [ "$CRASHED" != n ] && printf -- '- Crashed (%s). Log:\n```\n%s\n```\n' \
    "$([ "$CRASHED" = y ] && echo "on start" || echo "while in use")" "$(head -40 "$OUT/crash.log" 2>/dev/null)"
  [ -n "$START_PROMPT" ] && printf -- '- Asks for a permission on start: "%s"\n' "$START_PROMPT"
  [ "${#P_SPECIAL[@]}" -gt 0 ] && printf -- '- Special permissions: %s\n' "${P_SPECIAL[*]}"
  [ "${#P_RUNTIME[@]}" -gt 0 ] && printf -- '- Runtime permissions: %s\n' "${P_RUNTIME[*]}"
  [ "$CLEARTEXT" = 1 ] && printf -- '- `usesCleartextTraffic` is on (plain http allowed).\n'
  [ "$DEBUGGABLE" = 1 ] && printf -- '- The APK is debuggable.\n'
  [ "${#S_TRACKERS[@]}" -gt 0 ] && { printf -- '- Tracker code (Exodus signatures):\n'; printf '  - %s\n' "${S_TRACKERS[@]}"; }
  [ "${#S_NONFREE[@]}" -gt 0 ] && printf -- '- Non-free libraries: %s\n' "${S_NONFREE[*]}"
  if [ "$CAPTURED" = y ] && [ -z "$PCAP_ERR" ]; then
    printf -- '- Connections (PCAPdroid), first %ss after launch:' "$WATCH"
    if [ "${#CONN_START[@]}" -gt 0 ]; then printf '\n'; printf '  - `%s`\n' "${CONN_START[@]}"; else printf ' none\n'; fi
    printf -- '- Connections while in use:'
    if [ "${#CONN_LATER[@]}" -gt 0 ]; then printf '\n'; printf '  - `%s`\n' "${CONN_LATER[@]}"; else printf ' none\n'; fi
  elif [ "$HAS_INTERNET" = 1 ]; then
    printf -- '- Network not captured.\n'
  fi
  [ -n "$VT_RESULT" ] && printf -- '- VirusTotal: %s — %s\n' "$VT_RESULT" "$VT_LINK"
  [ -z "$VT_RESULT" ] && printf -- '- VirusTotal: %s\n' "$VT_LINK"
  printf '\n</details>\n'
} > "$REPORT"

step "6. Report"
cat "$REPORT"
printf '\n'
ok "saved to ${REPORT#"$PWD"/}"

# ================================================================ 7. post it
# The report goes to the same merge request, as a comment from your GitLab
# account. Nothing is posted without a yes, and the boxes still unchecked can
# be fixed in an editor first.
step "7. Post to !$IID"
LEFT="$(grep -c '(not checked)' "$REPORT" || true)"
[ "$LEFT" -gt 0 ] && warn "$LEFT box(es) still say (not checked)"
if [ -n "$EDIT_CMD" ] && confirm "Edit the report before posting?" "$([ "$LEFT" -gt 0 ] && echo y || echo n)"; then
  $EDIT_CMD "$REPORT" || warn "the editor exited with an error"
fi
if [ "$CAN_POST" = 0 ]; then
  note "glab is not ready (see the checks at the top) — paste ${REPORT#"$PWD"/} into $MR_URL yourself"
elif confirm "Post the report as a comment on $MR_URL?" y; then
  if glab api --method POST "projects/${MR_REPO//\//%2F}/merge_requests/$IID/notes" \
       -F "body=@$REPORT" > "$WORK/note.json" 2>&1; then
    NOTE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' \
               "$WORK/note.json" 2>/dev/null || true)"
    ok "posted: $MR_URL${NOTE_ID:+#note_$NOTE_ID}"
  else
    warn "glab could not post it:"; sed 's/^/     /' "$WORK/note.json" | head -5
    note "paste ${REPORT#"$PWD"/} into $MR_URL yourself"
  fi
else
  note "not posted — it stays in ${REPORT#"$PWD"/}"
fi

if [ "$NO_DEVICE" = 0 ] && [ "$KEEP" = 0 ]; then
  confirm "Remove the app from the phone now?" y && "${ADB[@]}" uninstall "$APPID" >/dev/null && ok "removed"
fi

exit 0
}
