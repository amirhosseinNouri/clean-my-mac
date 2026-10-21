#!/usr/bin/env bash
#
# cleanup.sh - find junk on macOS and offer to remove it.
#
# Looks at:
#   * Trash, user caches, sandboxed app caches, logs, Mail attachment downloads
#   * Developer leftovers (Xcode DerivedData, device support files, package caches, ...)
#   * Data left behind by apps that are no longer installed
#   * Docker Desktop and WhatsApp data when those apps are no longer installed
#   * "Install macOS" apps
#   * Old iOS device backups and firmware files
#   * (--system) system-wide caches and logs, launch daemons whose program is gone
#
# Never touched: ~/Downloads, Chrome profiles (cookies, logins, history), Keychains,
# iCloud Drive, Mail, Messages, Calendars, Contacts and Photos libraries.
#
# Nothing is removed without confirmation. Removed items are deleted permanently
# (moving them to the Trash would not free any space).
#
# Usage: ./cleanup.sh [options]
#   -n, --dry-run        Only report what could be removed
#   -y, --yes            Auto-accept low-risk categories (trash, caches, logs);
#                        everything else is still confirmed item by item
#   -s, --system         Also scan system-wide locations (asks for your password)
#   -m, --min-size MB    Ignore items smaller than MB megabytes (default: 1)
#   -h, --help           Show this help

set -u
export LC_NUMERIC=C

DRY_RUN=0
ASSUME_YES=0
INCLUDE_SYSTEM=0
MIN_KB=1024
LIST_LIMIT=25

FREED_KB=0
POTENTIAL_KB=0
FREE_BEFORE=0
CATEGORY=""
SUMMARY_DONE=0

# At least three labels, e.g. com.vendor.app
DNS_RE='^[a-z]{2,10}\.[a-z0-9_-]+\.[a-z0-9_.-]+$'

# Folder names in ~/Library/Application Support that belong to macOS itself.
SYSTEM_NAMES="accessibilitybundles addressbook animoji apple applemediaservices appstore avatarcache
biome books cachedelete caches callhistorydb callhistorytransactions calendar clouddocs cloudkit contacts
coreparsec crashreporter differentialprivacy diskimages dock facetime familycircle fileprovider
fontregistry freeform gamekit homeenergyd icdd icloud identityservices instruments knowledge
locationaccessstored mail maps messages mobilesync music networkserviceproxy news notes photos
podcasts quicklook reminders safari screentimeagent sharedfilelist siri spotlight stocks
syncservices tipsd tv videosubscriptionsd weather xcode"

usage() { sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; }

if [ -t 1 ]; then
  C_B=$'\033[1m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_CYN=$'\033[36m' C_OFF=$'\033[0m'
else
  C_B='' C_DIM='' C_RED='' C_GRN='' C_YEL='' C_CYN='' C_OFF=''
fi

warn() { printf '%s\n' "${C_YEL}$*${C_OFF}" >&2; }
die() { printf '%s\n' "${C_RED}$*${C_OFF}" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -s|--system) INCLUDE_SYSTEM=1 ;;
    -m|--min-size)
      shift
      case ${1:-} in ''|*[!0-9]*) die "--min-size needs a whole number of megabytes" ;; esac
      MIN_KB=$(( $1 * 1024 )) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[ "$(uname -s)" = Darwin ] || die "This script only supports macOS."
[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not with sudo. Use --system for system-wide locations."
[ -n "${HOME:-}" ] && [ "$HOME" != / ] && [ -d "$HOME" ] || die "HOME is not set to a valid directory."

HAVE_TTY=0
if { : >/dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cleanup.XXXXXX") || die "Cannot create a temporary directory."
: > "$TMP_DIR/freed.log"
: > "$TMP_DIR/claimed"
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'echo; warn "Interrupted."; print_summary; exit 130' INT TERM

DATA_VOL=/
[ -d /System/Volumes/Data ] && DATA_VOL=/System/Volumes/Data

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

free_kb() { df -k "$DATA_VOL" | awk 'NR == 2 { print $4 }'; }

# human KB -> "1.5 GB"
human() {
  awk -v k="${1:-0}" 'BEGIN { split("KB MB GB TB", u, " "); i = 1
    while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), k, u[i] }'
}

# to_kb "1.2GB" -> 1258291
to_kb() {
  printf '%s' "$1" | awk '{ v = $0 + 0; u = toupper($0); gsub(/[0-9. ]/, "", u)
    m = (u ~ /^T/) ? 1024^3 : (u ~ /^G/) ? 1024^2 : (u ~ /^M/) ? 1024 : (u ~ /^K/) ? 1 : 1 / 1024
    printf "%d", v * m }'
}

# size_kb PATH [sudo]
size_kb() {
  if [ "${2:-}" = sudo ]; then sudo du -sk "$1" 2>/dev/null; else du -sk "$1" 2>/dev/null; fi |
    awk 'END { print $1 + 0 }'
}

pretty() {
  case $1 in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# recently_modified PATH DAYS: true when anything inside changed in the last DAYS days
recently_modified() { [ -n "$(find "$1" -mtime "-$2" -print -quit 2>/dev/null)" ]; }

# ask PROMPT -> prints the lowercased answer (empty without a terminal)
ask() {
  local reply=""
  [ "$HAVE_TTY" -eq 1 ] || return 0
  printf '%s ' "$1" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "$reply" | tr '[:upper:]' '[:lower:]'
}

category() {
  CATEGORY=$1
  printf '\n%s\n' "${C_B}${C_CYN}== $1 ==${C_OFF}"
  [ -z "${2:-}" ] || printf '  %s\n' "${C_DIM}$2${C_OFF}"
  [ ! -t 1 ] || printf '  %s\r' "${C_DIM}scanning...${C_OFF}"
}

# Clears the "scanning..." line.
scan_done() { [ ! -t 1 ] || printf '\r\033[K'; }

new_list() {
  local f
  f=$(mktemp "$TMP_DIR/list.XXXXXX")
  printf '%s' "$f"
}

# Paths that must never be deleted, nor any folder containing them.
# Entries may end in a glob. Chrome's disk cache (~/Library/Caches/Google) holds
# no cookies or logins, so it stays removable.
PROTECTED_PATHS="\
$HOME/Downloads
$HOME/Library/Keychains
$HOME/Library/Mobile Documents
$HOME/Library/CloudStorage
$HOME/Library/Mail
$HOME/Library/Messages
$HOME/Library/Calendars
$HOME/Library/Application Support/AddressBook
$HOME/Library/Application Support/Google/Chrome*
$HOME/Library/Application Support/Chromium
$HOME/Library/Preferences/com.google.Chrome*
$HOME/Library/HTTPStorages/com.google.Chrome*
$HOME/Library/Cookies/com.google.Chrome*
$HOME/Library/WebKit/com.google.Chrome*
$HOME/Library/Saved Application State/com.google.Chrome*"

is_protected() {
  local p=$1 prot rest=$PROTECTED_PATHS
  case $p in *.photoslibrary|*.photoslibrary/*) return 0 ;; esac
  while [ -n "$rest" ]; do
    prot=${rest%%$'\n'*}
    case $rest in *$'\n'*) rest=${rest#*$'\n'} ;; *) rest="" ;; esac
    # shellcheck disable=SC2254 # $prot is a glob on purpose
    case $p in $prot|$prot/*) return 0 ;; esac   # the path itself or something inside it
    case $prot in "$p"/*) return 0 ;; esac          # a folder that contains it
  done
  return 1
}

# Last line of defence: only paths inside these locations may ever be deleted.
is_safe_path() {
  local p=$1
  case $p in /*) ;; *) return 1 ;; esac
  case $p in */../*|*/..|*/./*|*/.) return 1 ;; esac
  is_protected "$p" && return 1
  case $p in
    "$HOME/Library/"*/?*) return 0 ;;   # at least two levels below ~/Library
    "$HOME/.Trash/"?*|"$HOME/.cache/"?*|"$HOME/.npm/"?*|"$HOME/.gradle/"?*|\
    "$HOME/.m2/"?*|"$HOME/.cargo/"?*|"$HOME/.android/"?*) return 0 ;;
    /Volumes/*/.Trashes/*/?*) return 0 ;;
    /Library/Caches/?*|/Library/Logs/?*|/private/var/log/?*) return 0 ;;
    /Library/LaunchAgents/?*.plist|/Library/LaunchDaemons/?*.plist) return 0 ;;
    "/Applications/Install macOS "*.app) return 0 ;;
  esac
  return 1
}

record_freed() {
  [ "$1" -gt 0 ] || return 0
  FREED_KB=$((FREED_KB + $1))
  printf '%s\t%s\n' "$CATEGORY" "$1" >> "$TMP_DIR/freed.log"
}

# remove_path PATH [sudo]
remove_path() {
  local p=$1 mode=${2:-} before after=0
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if ! is_safe_path "$p"; then
    warn "  Refusing to remove $(pretty "$p") (outside the allowed locations)"
    return 1
  fi
  before=$(size_kb "$p" "$mode")
  case $p in
    "$HOME"/Library/LaunchAgents/*.plist|/Library/LaunchAgents/*.plist)
      launchctl bootout "gui/$(id -u)" "$p" >/dev/null 2>&1 ;;
    /Library/LaunchDaemons/*.plist)
      sudo launchctl bootout system "$p" >/dev/null 2>&1 ;;
  esac
  if [ "$mode" = sudo ]; then sudo rm -rf -- "$p" 2>/dev/null; else rm -rf -- "$p" 2>/dev/null; fi
  if [ -e "$p" ]; then
    after=$(size_kb "$p" "$mode")
    warn "  Partly removed (some files are protected or in use): $(pretty "$p")"
  fi
  record_freed $((before - after))
}

remove_target() {
  local target=$1 mode=${2:-} p
  case $target in
    @*) while IFS= read -r p; do remove_path "$p" "$mode"; done < "${target#@}" ;;
    *) remove_path "$target" "$mode" ;;
  esac
}

# add_item LIST PATH [TAG] [sudo] - adds PATH when it exists and is big enough
add_item() {
  local list=$1 p=$2 tag=${3:-} mode=${4:-} kb
  case $p in *$'\n'*|*$'\t'*) return 0 ;; esac
  [ -e "$p" ] && [ ! -L "$p" ] || return 0
  is_safe_path "$p" || return 0
  kb=$(size_kb "$p" "$mode")
  [ "$kb" -ge "$MIN_KB" ] || return 0
  printf '%s\t%s\t%s\n' "$kb" "$p" "$tag" >> "$list"
}

# add_children LIST DIR [EXCLUDE_ERE] [TAG] [sudo]
add_children() {
  local list=$1 dir=$2 exclude=${3:-} tag=${4:-} mode=${5:-} p
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' p; do
    if [ -n "$exclude" ] && printf '%s' "${p##*/}" | grep -Eq "$exclude"; then continue; fi
    add_item "$list" "$p" "$tag" "$mode"
  done < <(
    if [ "$mode" = sudo ]; then sudo find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null
    else find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null; fi
  )
}

describe() {
  case $1 in
    @*) printf '%s' "$2" ;;
    *) printf '%s' "$(pretty "$1")"; [ -z "$2" ] || printf '  %s' "${C_DIM}$2${C_OFF}" ;;
  esac
}

# review LIST RISK [sudo]
#   RISK=low   regenerated automatically: may be accepted in bulk (or with --yes)
#   RISK=high  personal data or a guess: only item by item, default no
review() {
  local list=$1 risk=$2 mode=${3:-} sorted count total kb target label shown=0 answer gp
  scan_done
  sorted="$list.sorted"
  sort -t $'\t' -k1,1nr "$list" > "$sorted"
  count=$(wc -l < "$sorted" | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    printf '  %s\n' "${C_DIM}Nothing to clean.${C_OFF}"
    return 0
  fi
  total=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$sorted")
  POTENTIAL_KB=$((POTENTIAL_KB + total))

  while IFS=$'\t' read -r kb target label; do
    shown=$((shown + 1))
    [ "$shown" -le "$LIST_LIMIT" ] || break
    printf '  %10s  %s\n' "$(human "$kb")" "$(describe "$target" "$label")"
  done < "$sorted"
  [ "$count" -le "$LIST_LIMIT" ] || printf '  %s\n' "${C_DIM}... and $((count - LIST_LIMIT)) more${C_OFF}"
  printf '  %s\n' "${C_B}Total: $(human "$total") in $count item(s)${C_OFF}"

  [ "$DRY_RUN" -eq 0 ] || return 0

  if [ "$risk" = low ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then answer=a
    else answer=$(ask "  Remove? [a]ll / [s]elect one by one / [N]one:"); fi
  else
    answer=$(ask "  These need a closer look. Review one by one? [s]elect / [N]one:")
  fi

  case $answer in
    a|all)
      if [ "$risk" != low ]; then echo "  Skipped."; return 0; fi
      while IFS=$'\t' read -r kb target label; do
        remove_target "$target" "$mode" </dev/null
      done < "$sorted"
      ;;
    s|select)
      while IFS=$'\t' read -r kb target label; do
        case $target in
          @*) while IFS= read -r gp; do printf '      %s\n' "$(pretty "$gp")"; done < "${target#@}" ;;
        esac
        answer=$(ask "  Remove $(describe "$target" "$label") ($(human "$kb"))? [y/N/q]")
        case $answer in
          y|yes) remove_target "$target" "$mode" </dev/null ;;
          q|quit) break ;;
        esac
      done < "$sorted"
      ;;
    *) echo "  Skipped." ;;
  esac
}

# offer_command TITLE EST_KB RISK CMD... - freed space is measured on the disk
offer_command() {
  local title=$1 est=$2 risk=$3 answer before after shown_size='?'
  shift 3
  scan_done
  [ "$est" -le 0 ] || shown_size=$(human "$est")
  printf '  %10s  %s\n' "$shown_size" "$title"
  printf '  %10s  %s\n' "" "${C_DIM}\$ $*${C_OFF}"
  POTENTIAL_KB=$((POTENTIAL_KB + est))
  [ "$DRY_RUN" -eq 0 ] || return 0

  if [ "$risk" = low ] && [ "$ASSUME_YES" -eq 1 ]; then answer=y
  else answer=$(ask "  Run it? [y/N]:"); fi
  case $answer in y|yes) ;; *) echo "  Skipped."; return 0 ;; esac

  CATEGORY=$title
  before=$(free_kb)
  "$@" </dev/null || warn "  Command failed: $*"
  after=$(free_kb)
  record_freed $((after - before))
}

# ---------------------------------------------------------------------------
# Installed-app index (used to detect leftovers)
# ---------------------------------------------------------------------------

APP_IDS="$TMP_DIR/app_ids"
APP_NAMES="$TMP_DIR/app_names"
VENDORS="$TMP_DIR/vendors"

build_app_index() {
  local spot="$TMP_DIR/spotlight" b
  : > "$APP_IDS"; : > "$TMP_DIR/app_names_raw"

  # Spotlight knows every app on indexed volumes, including ones outside /Applications.
  mdfind -attr kMDItemCFBundleIdentifier "kMDItemContentType == 'com.apple.application-bundle'" \
    > "$spot" 2>/dev/null
  sed -n 's/.*kMDItemCFBundleIdentifier = //p' "$spot" | grep -v '^(null)$' >> "$APP_IDS"
  sed 's/ *kMDItemCFBundleIdentifier = .*$//' "$spot" | sed 's#.*/##' >> "$TMP_DIR/app_names_raw"

  # Plus bundles in the usual places, in case Spotlight is off or incomplete.
  find /Applications "$HOME/Applications" /System/Applications /System/Library/CoreServices \
       /Library/PreferencePanes "$HOME/Library/PreferencePanes" \
       /Library/Audio/Plug-Ins "$HOME/Library/Audio/Plug-Ins" "/Library/Internet Plug-Ins" \
       /Library/Extensions /Library/SystemExtensions "/Library/Application Support" \
       /opt/homebrew/Caskroom /usr/local/Caskroom \
       -maxdepth 4 \( -name '*.app' -o -name '*.prefPane' -o -name '*.component' -o -name '*.vst' \
       -o -name '*.vst3' -o -name '*.plugin' -o -name '*.kext' -o -name '*.systemextension' \
       -o -name '*.driver' \) -print0 -prune 2>/dev/null |
    while IFS= read -r -d '' b; do
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$b/Contents/Info.plist" 2>/dev/null \
        >> "$APP_IDS"
      printf '%s\n' "${b##*/}" >> "$TMP_DIR/app_names_raw"
    done

  sed 's/\.[^.]*$//' "$TMP_DIR/app_names_raw" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9\n' |
    awk 'length($0) >= 3' | sort -u > "$APP_NAMES"
  tr '[:upper:]' '[:lower:]' < "$APP_IDS" |
    awk -F. 'NF >= 2 { v = $1 "." $2
      if ($2 ~ /^(github|gitlab|sourceforge|googlecode|bitbucket)$/ && NF >= 3) v = v "." $3
      print v }' | sort -u > "$VENDORS"
}

# owner_installed ID: true when any installed bundle comes from the same vendor.
# Matching on the vendor (com.google, not com.google.chrome) is deliberately
# conservative: shared helpers and updaters are never flagged.
owner_installed() {
  local v1=${1%%.*} rest=${1#*.} v2 v
  v2=${rest%%.*}
  v="$v1.$v2"
  case $v2 in github|gitlab|sourceforge|googlecode|bitbucket) rest=${rest#*.}; v="$v.${rest%%.*}" ;; esac
  case $v in com.apple|systemgroup.com|group.com) return 0 ;; esac
  grep -Fxq -- "$v" "$VENDORS"
}

name_matches_app() {
  awk -v n="$1" 'index($0, n) || index(n, $0) { found = 1; exit } END { exit !found }' "$APP_NAMES"
}

# id_from_name NAME KIND -> lowercase bundle id guessed from a file/folder name
id_from_name() {
  local n=$1
  n=${n%.plist}; n=${n%.savedState}; n=${n%.binarycookies}
  case $2 in
    byhost) n=$(printf '%s' "$n" | sed -E 's/\.[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$//; s/\.[0-9A-Fa-f]{12}$//') ;;
    group) n=$(printf '%s' "$n" | sed -E 's/^[A-Z0-9]{10}\.//; s/^groups?\.//') ;;
  esac
  printf '%s' "$n" | tr '[:upper:]' '[:lower:]'
}

# scan_ids RAW DIR KIND - records "id<TAB>kb<TAB>path" for entries whose app is gone
scan_ids() {
  local raw=$1 dir=$2 kind=$3 p id
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' p; do
    case $p in *$'\n'*|*$'\t'*) continue ;; esac
    [ -L "$p" ] && continue
    grep -Fxq -- "$p" "$TMP_DIR/claimed" && continue
    id=$(id_from_name "${p##*/}" "$kind")
    [[ $id =~ $DNS_RE ]] || continue
    case $id in *com.apple.*) continue ;; esac
    owner_installed "$id" && continue
    is_safe_path "$p" || continue
    printf '%s\t%s\t%s\n' "$id" "$(size_kb "$p")" "$p" >> "$raw"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

collect_id_leftovers() {
  local list=$1 raw="$TMP_DIR/orphans.raw" id group kb n tag p
  : > "$raw"
  scan_ids "$raw" "$HOME/Library/Application Support" plain
  scan_ids "$raw" "$HOME/Library/Containers" plain
  scan_ids "$raw" "$HOME/Library/Group Containers" group
  scan_ids "$raw" "$HOME/Library/Application Scripts" plain
  scan_ids "$raw" "$HOME/Library/Preferences" plain
  scan_ids "$raw" "$HOME/Library/Preferences/ByHost" byhost
  scan_ids "$raw" "$HOME/Library/Saved Application State" plain
  scan_ids "$raw" "$HOME/Library/HTTPStorages" plain
  scan_ids "$raw" "$HOME/Library/WebKit" plain
  scan_ids "$raw" "$HOME/Library/Cookies" plain
  scan_ids "$raw" "$HOME/Library/Caches" plain
  scan_ids "$raw" "$HOME/Library/Logs" plain

  # One entry per app, covering all of its locations.
  for id in $(cut -f1 "$raw" | sort -u); do
    group=$(mktemp "$TMP_DIR/group.XXXXXX")
    awk -F'\t' -v id="$id" '$1 == id { print $3 }' "$raw" > "$group"
    kb=$(awk -F'\t' -v id="$id" '$1 == id { s += $2 } END { print s + 0 }' "$raw")
    [ "$kb" -ge "$MIN_KB" ] || continue
    n=$(wc -l < "$group" | tr -d ' ')
    tag=""
    while IFS= read -r p; do
      if recently_modified "$p" 30; then tag="  [changed in the last 30 days]"; break; fi
    done < "$group"
    printf '%s\t@%s\t%s\n' "$kb" "$group" "$id  ($n location(s))$tag" >> "$list"
  done
}

# collect_app_data LIST NAME_GLOB... - every entry in the usual Library folders
# whose name matches one of the globs (case-insensitive). Matches are claimed so
# the generic leftover scan does not list them again.
collect_app_data() {
  local list=$1 dir p g
  local -a match
  shift
  match=(-iname "$1")
  shift
  for g in "$@"; do match=("${match[@]}" -o -iname "$g"); done
  for dir in "Application Support" Containers "Group Containers" "Application Scripts" Caches \
             Preferences "Preferences/ByHost" "Saved Application State" HTTPStorages WebKit Cookies Logs; do
    [ -d "$HOME/Library/$dir" ] || continue
    while IFS= read -r -d '' p; do
      [ -L "$p" ] && continue
      is_safe_path "$p" || continue
      printf '%s\n' "$p" >> "$TMP_DIR/claimed"
      printf '%s\t%s\t%s\n' "$(size_kb "$p")" "$p" "" >> "$list"
    done < <(find "$HOME/Library/$dir" -mindepth 1 -maxdepth 1 \( "${match[@]}" \) -print0 2>/dev/null)
  done
}

# app_in_use ID_ERE PROCESS_ERE: installed (per the app index) or running
app_in_use() {
  grep -Eiq -- "$1" "$APP_IDS" || pgrep -if -- "$2" >/dev/null 2>&1
}

# Folders in Application Support named after an app rather than a bundle id.
# These are guesses, so they must also be untouched for 90 days.
collect_named_leftovers() {
  local list=$1 p name norm
  while IFS= read -r -d '' p; do
    [ -d "$p" ] && [ ! -L "$p" ] || continue
    grep -Fxq -- "$p" "$TMP_DIR/claimed" && continue
    name=${p##*/}
    case $name in .*|*.*.*) continue ;; esac
    norm=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    [ ${#norm} -ge 3 ] || continue
    case " $(echo $SYSTEM_NAMES) " in *" $norm "*) continue ;; esac
    if [ -e "/usr/libexec/$name" ] || [ -e "/usr/sbin/$name" ] || [ -e "/usr/bin/$name" ] ||
       [ -e "/System/Library/CoreServices/$name.app" ] ||
       [ -e "/System/Library/PrivateFrameworks/$name.framework" ]; then
      continue
    fi
    command -v "$name" >/dev/null 2>&1 && continue
    command -v "$norm" >/dev/null 2>&1 && continue
    name_matches_app "$norm" && continue
    recently_modified "$p" 90 && continue
    add_item "$list" "$p" "[guess: no matching app, untouched for 90+ days]"
  done < <(find "$HOME/Library/Application Support" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# Launch agents/daemons whose program no longer exists (they fail on every login).
collect_dead_launchd() {
  local list=$1 dir=$2 p prog
  for p in "$dir"/*.plist; do
    [ -f "$p" ] && [ ! -L "$p" ] || continue
    case ${p##*/} in com.apple.*) continue ;; esac
    prog=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$p" 2>/dev/null) ||
      prog=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$p" 2>/dev/null) || continue
    case $prog in /Volumes/*) continue ;; /*) ;; *) continue ;; esac
    [ -e "$prog" ] && continue
    is_safe_path "$p" || continue
    printf '%s\t%s\t%s\n' "$(size_kb "$p")" "$p" "[runs missing program $prog]" >> "$list"
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local kb cat free_after
  [ "$SUMMARY_DONE" -eq 0 ] || return 0
  SUMMARY_DONE=1
  printf '\n%s\n' "${C_B}${C_CYN}== Summary ==${C_OFF}"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  Dry run: nothing was removed."
    echo "  ${C_B}Up to $(human "$POTENTIAL_KB") could be freed${C_OFF} (plus whatever the listed commands reclaim)."
    echo "  Run again without --dry-run to choose what to remove."
    return 0
  fi
  if [ -s "$TMP_DIR/freed.log" ]; then
    awk -F'\t' '{ if (!($1 in s)) order[++n] = $1; s[$1] += $2 }
      END { for (i = 1; i <= n; i++) print s[order[i]] "\t" order[i] }' "$TMP_DIR/freed.log" |
      while IFS=$'\t' read -r kb cat; do
        printf '  %10s  %s\n' "$(human "$kb")" "$cat"
      done
  fi
  free_after=$(free_kb)
  echo "  ${C_GRN}${C_B}Freed: $(human "$FREED_KB")${C_OFF}"
  echo "  Free disk space: $(human "$FREE_BEFORE") before, $(human "$free_after") now."
  if [ "$FREED_KB" -gt 0 ]; then
    echo "  ${C_DIM}macOS may report some of it as \"purgeable\" until local snapshots expire.${C_OFF}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local L p u udids est n dir kb name date cache_dir

  printf '%s\n' "${C_B}Mac cleanup${C_OFF}"
  [ "$DRY_RUN" -eq 1 ] && echo "  Dry run: nothing will be removed."
  echo "  ${C_YEL}Quit open apps first. Anything you approve is deleted permanently.${C_OFF}"
  if [ -d "$HOME/Library/Safari" ] && ! ls "$HOME/Library/Safari" >/dev/null 2>&1; then
    warn "  Your terminal lacks Full Disk Access, so some locations cannot be scanned."
    warn "  Grant it in System Settings > Privacy & Security > Full Disk Access for a complete scan."
  fi
  if [ "$HAVE_TTY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    warn "  No terminal to ask questions on: running as a dry run."
    DRY_RUN=1
  fi
  FREE_BEFORE=$(free_kb)

  # --- Low risk: regenerated automatically -----------------------------------

  category "Trash" "Files you already deleted."
  L=$(new_list)
  add_children "$L" "$HOME/.Trash"
  for p in /Volumes/*/.Trashes/"$(id -u)"; do add_children "$L" "$p"; done
  review "$L" low

  category "User caches" "Apps rebuild these as needed (first launch may be slower)."
  L=$(new_list)
  add_children "$L" "$HOME/Library/Caches" \
    '^(com\.apple\.(bird|akd|homed|HomeKit|containermanagerd|ap\.adprivacyd)|CloudKit|FamilyCircle)'
  review "$L" low

  category "Sandboxed app caches" "Caches inside App Store / sandboxed app containers."
  L=$(new_list)
  for p in "$HOME"/Library/Containers/*/Data/Library/Caches; do add_item "$L" "$p"; done
  add_item "$L" "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads" \
    "[attachments you opened in Mail]"
  review "$L" low

  category "Logs and crash reports"
  L=$(new_list)
  add_children "$L" "$HOME/Library/Logs"
  review "$L" low

  category "Developer caches" "Build products and package caches; rebuilt or re-downloaded on demand."
  L=$(new_list)
  add_children "$L" "$HOME/Library/Developer/Xcode/DerivedData"
  for p in "$HOME"/Library/Developer/Xcode/*DeviceSupport; do
    add_children "$L" "$p" "" "[copied again when the device connects]"
  done
  add_item "$L" "$HOME/Library/Developer/CoreSimulator/Caches"
  add_item "$L" "$HOME/Library/Developer/Xcode/UserData/Previews"
  add_item "$L" "$HOME/Library/Developer/XCPGDevices"
  add_item "$L" "$HOME/.npm/_cacache"
  add_item "$L" "$HOME/.gradle/caches"
  add_item "$L" "$HOME/.cargo/registry/cache"
  add_item "$L" "$HOME/.android/cache"
  add_item "$L" "$HOME/Library/pnpm/store"
  review "$L" low

  # --- Commands ---------------------------------------------------------------

  category "Maintenance commands"
  n=0
  if command -v brew >/dev/null 2>&1; then
    est=$(brew cleanup -s --prune=all -n 2>/dev/null | sed -n 's/.*free approximately \([0-9.]*[KMGT]*B\).*/\1/p' | tail -1)
    if [ -n "$est" ]; then
      offer_command "Homebrew: old versions and downloads" "$(to_kb "$est")" low brew cleanup -s --prune=all
      n=$((n + 1))
    fi
  fi
  if xcode-select -p >/dev/null 2>&1 && xcrun --find simctl >/dev/null 2>&1; then
    udids=$(xcrun simctl list devices unavailable 2>/dev/null |
      grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')
    if [ -n "$udids" ]; then
      est=0
      for u in $udids; do
        est=$((est + $(size_kb "$HOME/Library/Developer/CoreSimulator/Devices/$u")))
      done
      offer_command "Simulators for Xcode/iOS versions no longer installed" "$est" low \
        xcrun simctl delete unavailable
      n=$((n + 1))
    fi
  fi
  if command -v go >/dev/null 2>&1; then
    cache_dir=$(go env GOMODCACHE 2>/dev/null)
    kb=0
    [ -z "$cache_dir" ] || kb=$(size_kb "$cache_dir")
    if [ "$kb" -ge "$MIN_KB" ]; then
      offer_command "Go module cache (re-downloaded on next build)" "$kb" high go clean -modcache
      n=$((n + 1))
    fi
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    offer_command "Docker: stopped containers, unused networks, dangling images, build cache (volumes kept)" \
      0 high docker system prune -f
    n=$((n + 1))
  fi
  if [ "$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine')" -gt 0 ]; then
    offer_command "Local Time Machine snapshots (macOS also purges these when space runs low)" \
      0 high tmutil thinlocalsnapshots / 999999999999 4
    n=$((n + 1))
  fi
  scan_done
  [ "$n" -gt 0 ] || printf '  %s\n' "${C_DIM}Nothing to run.${C_OFF}"

  # --- Data of specific apps that are no longer installed ---------------------

  category "Docker Desktop data" "VM disk image, images and settings. The docker CLI config in ~/.docker is kept."
  build_app_index
  INDEX_OK=1
  [ "$(wc -l < "$APP_IDS" | tr -d ' ')" -ge 20 ] || INDEX_OK=0
  if [ "$INDEX_OK" -eq 0 ]; then
    scan_done
    warn "  Could not build a reliable list of installed apps; skipping app data to be safe."
  elif app_in_use '^com\.docker\.docker$' 'Docker Desktop|com\.docker\.(backend|virtualization)'; then
    scan_done
    printf '  %s\n' "${C_DIM}Docker Desktop is installed or running; keeping its data.${C_OFF}"
  else
    L=$(new_list)
    collect_app_data "$L" 'com.docker.*' 'group.com.docker' 'Docker Desktop' 'com.electron.docker*'
    review "$L" low
  fi

  category "WhatsApp data" "Chats and media stored on this Mac (your phone and backups are not affected)."
  if [ "$INDEX_OK" -eq 0 ]; then
    scan_done
    warn "  Skipped (no reliable list of installed apps)."
  elif app_in_use 'whatsapp' 'WhatsApp'; then
    scan_done
    printf '  %s\n' "${C_DIM}WhatsApp is installed or running; keeping its data.${C_OFF}"
  else
    L=$(new_list)
    collect_app_data "$L" '*whatsapp*'
    review "$L" low
  fi

  # --- High risk: confirmed item by item ---------------------------------------

  category "Leftovers of uninstalled apps" \
    "Settings and data of apps not found on this Mac. Keep anything from apps you run from elsewhere."
  if [ "$INDEX_OK" -eq 0 ]; then
    scan_done
    warn "  Skipped (no reliable list of installed apps)."
  else
    L=$(new_list)
    collect_id_leftovers "$L"
    collect_named_leftovers "$L"
    collect_dead_launchd "$L" "$HOME/Library/LaunchAgents"
    review "$L" high
  fi

  category "Developer data" "Re-downloadable, but may hold things you still need."
  L=$(new_list)
  add_children "$L" "$HOME/Library/Developer/Xcode/Archives" "" \
    "[needed to symbolicate crash reports of shipped builds]"
  add_children "$L" "$HOME/.cache"
  add_item "$L" "$HOME/.m2/repository" "[also holds artifacts you built with mvn install]"
  review "$L" high

  category "macOS installers"
  L=$(new_list)
  for p in "/Applications/Install macOS "*.app; do
    add_item "$L" "$p" "[macOS installer, can be downloaded again]"
  done
  review "$L" high

  category "iOS backups and firmware"
  L=$(new_list)
  for p in "$HOME"/Library/iTunes/*Software\ Updates/*.ipsw; do
    add_item "$L" "$p" "[firmware, downloaded again when needed]"
  done
  for p in "$HOME/Library/Application Support/MobileSync/Backup"/*; do
    [ -d "$p" ] || continue
    name=$(defaults read "$p/Info.plist" "Device Name" 2>/dev/null)
    date=$(defaults read "$p/Info.plist" "Last Backup Date" 2>/dev/null)
    add_item "$L" "$p" "[backup of ${name:-unknown device}${date:+, ${date%% *}}]"
  done
  review "$L" high

  # --- System-wide -----------------------------------------------------------

  if [ "$INCLUDE_SYSTEM" -eq 1 ]; then
    echo
    if ! sudo -v; then
      warn "Could not get administrator rights; skipping system-wide locations."
    else
      category "System caches"
      L=$(new_list)
      add_children "$L" /Library/Caches "" "" sudo
      review "$L" low sudo

      category "System logs" "Logs in /Library/Logs and rotated logs older than a week."
      L=$(new_list)
      add_children "$L" /Library/Logs "" "" sudo
      while IFS= read -r -d '' p; do
        add_item "$L" "$p" "" sudo
      done < <(sudo find /private/var/log -type f \( -name '*.gz' -o -name '*.bz2' -o -name '*.[0-9]' \) \
                 -mtime +7 -print0 2>/dev/null)
      review "$L" low sudo

      category "System launch agents and daemons whose program is gone"
      L=$(new_list)
      for dir in /Library/LaunchAgents /Library/LaunchDaemons; do collect_dead_launchd "$L" "$dir"; done
      review "$L" high sudo
    fi
  fi

  print_summary
}

main
