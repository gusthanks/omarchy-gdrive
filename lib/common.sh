# shellcheck shell=bash
# lib/common.sh — provider-agnostic half of omarchy-gdrive.
#
# Everything in this file only knows about "an rclone remote, mounted at a
# directory by a user systemd service, with a VFS cache". Nothing here is
# Google-specific: the provider module (lib/gdrive.sh) fills in the hooks
# listed under PROVIDER HOOKS so the same core can become omarchy-cloud-drive.

# ---------------------------------------------------------------------------
# Identity and defaults (a provider module may override before sourcing this)
# ---------------------------------------------------------------------------
: "${CLI_NAME:=omarchy-gdrive}"
: "${CLI_VERSION:=0.4.0}"
: "${PROVIDER_ID:=gdrive}"
: "${DISPLAY_NAME:=Google Drive}"
: "${BACKEND_TYPE:=drive}"
: "${DEFAULT_REMOTE:=gdrive}"
: "${DEFAULT_MOUNTPOINT:=$HOME/GoogleDrive}"
: "${DEFAULT_SERVICE:=rclone-gdrive}"
: "${REPO_URL:=https://github.com/gusthanks/omarchy-gdrive}"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
STATE_DIR="$CONFIG_HOME/$CLI_NAME"
STATE_FILE="$STATE_DIR/config"
SYSTEMD_USER_DIR="$CONFIG_HOME/systemd/user"
RCLONE_CONF="${RCLONE_CONFIG:-$CONFIG_HOME/rclone/rclone.conf}"
GTK_BOOKMARKS="$CONFIG_HOME/gtk-3.0/bookmarks"
MANAGED_MARKER="Managed by $CLI_NAME"
# Written when Google refuses the login; while it exists the mount does not even try
# to start (see auth-guard). Deleted by reconnect, or ignored once rclone.conf is newer.
# One per service, named after it: <service>.login-refused in the state dir.
LOCAL_BIN="$HOME/.local/bin"

# Runtime state, filled by load_state / setup.
REMOTE="$DEFAULT_REMOTE"
MOUNTPOINT="$DEFAULT_MOUNTPOINT"
SERVICE="$DEFAULT_SERVICE"
MANAGED=""            # "template" (we wrote the unit), "adopted" (user's own unit) or ""

# Global flags.
ASSUME_YES=0
JSON_OUTPUT=0
QUIET=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_INFO=$'\e[36m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""
fi

say()   { (( QUIET )) || printf '%s\n' "$*"; }
info()  { (( QUIET )) || printf '%s•%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()    { (( QUIET )) || printf '%s✔%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
fail()  { printf '%s✘%s %s\n' "$C_FAIL" "$C_RESET" "$*" >&2; }
die()   { fail "$*"; exit 1; }
hr()    { (( QUIET )) || printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────" "$C_RESET"; }
title() { (( QUIET )) || printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

have() { command -v "$1" >/dev/null 2>&1; }
# stdin and stderr, not stdout: helpers run inside $(...) where stdout is a pipe.
interactive() { [[ -t 0 && -t 2 ]]; }

# confirm <question> [default yes|no]  — honours --yes; refuses to guess when not a tty.
confirm() {
  local q=$1 def=${2:-yes}
  (( ASSUME_YES )) && return 0
  if ! interactive; then
    [[ $def == yes ]] && return 0
    return 1
  fi
  if have gum; then
    local args=(--affirmative "$(t common.yes)" --negative "$(t common.no)")
    [[ $def == no ]] && args+=(--default=false)
    gum confirm "${args[@]}" "$q"
  else
    local ans
    read -r -p "$q [$([[ $def == yes ]] && echo Y/n || echo y/N)] " ans
    ans=${ans:-$([[ $def == yes ]] && echo y || echo n)}
    [[ $ans =~ ^[yYsS] ]]
  fi
}

# choose <header> <option>...  — prints the chosen option; first option is the default.
choose() {
  local header=$1
  shift
  if ! interactive; then
    printf '%s' "$1"
    return
  fi
  if have gum; then
    gum choose --header="$header" --selected="$1" "$@"
  else
    local i=1 pick
    printf '%s\n' "$header" >&2
    for o in "$@"; do printf '  %d) %s\n' "$i" "$o" >&2; ((i++)); done
    read -r -p "> " pick
    [[ $pick =~ ^[0-9]+$ && $pick -ge 1 && $pick -le $# ]] || pick=1
    eval "printf '%s' \"\${$pick}\""
  fi
}

# prompt <label> [--password]  — reads a line, never echoing when --password.
prompt() {
  local label=$1 secret=${2:-} val
  interactive || return 1
  if have gum; then
    if [[ $secret == --password ]]; then
      gum input --password --prompt "$label " --placeholder "" </dev/tty
    else
      gum input --prompt "$label " --placeholder "" </dev/tty
    fi
  else
    if [[ $secret == --password ]]; then
      read -r -s -p "$label " val </dev/tty; printf '\n' >&2
    else
      read -r -p "$label " val </dev/tty
    fi
    printf '%s' "$val"
  fi
}

human_bytes() {
  local b=${1:-0}
  [[ $b =~ ^[0-9]+$ ]] || b=0
  if have numfmt; then numfmt --to=iec-i --suffix=B --format='%.1f' "$b"; else printf '%s B' "$b"; fi
}

# rclone SizeSuffix ("15G", "2Gi", "500M", "off") → bytes (binary units, like rclone).
size_to_bytes() {
  local s=${1:-0} n unit
  [[ $s == off || -z $s ]] && { printf '0'; return; }
  n=${s%%[^0-9.]*}; unit=${s#"$n"}; unit=${unit%i}; unit=${unit%I}; unit=${unit%B}
  case ${unit^^} in
    K) awk -v n="$n" 'BEGIN{printf "%d", n*1024}' ;;
    M) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024}' ;;
    G) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
    T) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024*1024*1024}' ;;
    P) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024*1024*1024*1024}' ;;
    *) awk -v n="$n" 'BEGIN{printf "%d", n}' ;;
  esac
}

# ---------------------------------------------------------------------------
# State file (~/.config/omarchy-gdrive/config)
# ---------------------------------------------------------------------------
load_state() {
  if [[ -f $STATE_FILE ]]; then
    local k v
    while IFS='=' read -r k v; do
      case $k in
        REMOTE) REMOTE=$v ;;
        MOUNTPOINT) MOUNTPOINT=${v/#\~/$HOME} ;;
        SERVICE) SERVICE=$v ;;
        MANAGED) MANAGED=$v ;;
      esac
    done < "$STATE_FILE"
  fi
  # Without a state file, fall back to whatever a unit with the default name says.
  if [[ ! -f $STATE_FILE && -f $(unit_path) ]]; then
    unit_parse_execstart "$(unit_path)"
    [[ -z $MANAGED ]] && MANAGED=$(unit_is_managed "$(unit_path)" && echo template || echo adopted)
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"
  {
    echo "# Written by $CLI_NAME $(date -u +%Y-%m-%dT%H:%M:%SZ). Edit with: $CLI_NAME setup"
    echo "REMOTE=$REMOTE"
    echo "MOUNTPOINT=$MOUNTPOINT"
    echo "SERVICE=$SERVICE"
    echo "MANAGED=$MANAGED"
  } > "$STATE_FILE"
}

# redact_secrets — stdin → stdout with OAuth tokens and client secrets masked.
# rclone does not log them at NOTICE level, but an error line can quote a
# config value or an HTTP body, and these lines end up on screen.
redact_secrets() {
  sed -E \
    -e 's/("?(access_token|refresh_token|client_secret|id_token)"?[[:space:]]*[:=][[:space:]]*"?)[^",}[:space:]]+/\1[redacted]/g' \
    -e 's/ya29\.[A-Za-z0-9._-]+/[redacted]/g' \
    -e 's#1//[A-Za-z0-9._-]{20,}#[redacted]#g' \
    -e 's/GOCSPX-[A-Za-z0-9_-]+/[redacted]/g'
}

# ---------------------------------------------------------------------------
# rclone remote helpers (never print the token)
# ---------------------------------------------------------------------------
remote_exists() { rclone listremotes 2>/dev/null | grep -qx "$REMOTE:"; }

# remote_option <key> — one option of the remote from the config, or empty.
# Reads through `rclone config dump` so obscured/env-backed values resolve, and
# only the requested key leaves this function.
remote_option() {
  rclone config dump 2>/dev/null | jq -r --arg r "$REMOTE" --arg k "$1" '.[$r][$k] // empty'
}
remote_type() { remote_option type; }

# status_remote_facts — "<exists>\t<own client>" (yes/no each) for the status
# poll. The bar asks for status every few seconds and each rclone start costs
# ~0.1 s of CPU on a slow laptop, so this runs one `rclone config dump` only
# when rclone.conf (or an RCLONE_CONFIG_* variable) changed, and keeps the
# answer in $XDG_RUNTIME_DIR (RAM, private, gone on reboot). Only the two
# yes/no facts are stored — never a token, id or secret. setup/doctor/remove
# keep reading the config directly.
: "${PROVIDER_OWN_CLIENT_JQ:=false}"   # jq test on the remote's object; set per provider
status_remote_facts() {
  local dir="${XDG_RUNTIME_DIR:-$CACHE_HOME}/$CLI_NAME" file key facts cached_key
  file="$dir/status-remote"
  key=$( { printf '%s\n%s\n' "$REMOTE" "$PROVIDER_OWN_CLIENT_JQ"
           stat -Lc '%i %s %y' "$RCLONE_CONF" 2>/dev/null
           env | grep '^RCLONE_CONFIG' | sort; } | cksum | cut -d' ' -f1)
  if [[ -r $file ]] && { read -r cached_key; read -r facts; } <"$file" && [[ $cached_key == "$key" && -n $facts ]]; then
    printf '%s' "$facts"; return 0
  fi
  facts=$(rclone config dump 2>/dev/null | jq -r --arg r "$REMOTE" "
    if has(\$r) then [\"yes\", (.[\$r] | if ($PROVIDER_OWN_CLIENT_JQ) then \"yes\" else \"no\" end)]
    else [\"no\", \"no\"] end | @tsv") || facts=""
  [[ $facts == *$'\t'* ]] || { printf 'no\tno'; return 0; }   # rclone/jq failed: report, don't cache
  if mkdir -p -m 700 "$dir" 2>/dev/null; then
    ( umask 077; printf '%s\n%s\n' "$key" "$facts" >"$file.$$" && mv -f "$file.$$" "$file" ) 2>/dev/null
  fi
  printf '%s' "$facts"
}

# Errors that mean "sign in again": the refresh token was refused, revoked or
# the OAuth client is gone. Retrying never fixes these; only a reconnect does.
AUTH_ERROR_RE='invalid_grant|expired or revoked|empty token|couldn.t fetch token|unauthorized_client|invalid_client|deleted_client'
is_auth_error() { grep -qiE "$AUTH_ERROR_RE" <<<"${1:-}"; }

# A real round trip with a short budget: proves the token (and the network) work.
REMOTE_TOKEN_ERROR=""
remote_token_ok() {
  local out
  out=$(timeout 45 rclone lsjson "$REMOTE:" --max-depth 1 --contimeout 10s --timeout 30s --low-level-retries 3 --retries 2 2>&1 >/dev/null)
  local rc=$?
  # rclone's error lines never contain the token; keep a one-line reason for doctor.
  REMOTE_TOKEN_ERROR=$(grep -vE 'shared Google Drive client_id|^\s*[]},]*\s*$' <<<"$out" | grep -E 'ERROR|CRITICAL|Failed|rateLimit|invalid_grant|token' | tail -n 1 | sed -E 's/^[0-9/ :]+ (ERROR|CRITICAL|NOTICE) ?:? ?//' | redact_secrets | cut -c1-160)
  REMOTE_TOKEN_KIND=ok
  if (( rc != 0 )); then
    if grep -qiE 'rateLimitExceeded|userRateLimitExceeded|quotaExceeded|429' <<<"$out"; then REMOTE_TOKEN_KIND=throttled
    elif is_auth_error "$out"; then REMOTE_TOKEN_KIND=invalid
    else REMOTE_TOKEN_KIND=unreachable; fi
  fi
  return $rc
}

secure_rclone_conf() {
  local dir
  dir=$(dirname "$RCLONE_CONF")
  [[ -d $dir ]] && chmod 700 "$dir" 2>/dev/null
  [[ -f $RCLONE_CONF ]] && chmod 600 "$RCLONE_CONF" 2>/dev/null
  return 0
}

rclone_conf_mode() { stat -c %a "$RCLONE_CONF" 2>/dev/null || echo ""; }

# ---------------------------------------------------------------------------
# systemd user unit
# ---------------------------------------------------------------------------
unit_path() { printf '%s/%s.service' "$SYSTEMD_USER_DIR" "$SERVICE"; }
unit_exists() { [[ -f $(unit_path) ]]; }
unit_is_managed() { grep -qF "$MANAGED_MARKER" "${1:-$(unit_path)}" 2>/dev/null; }

# Pull REMOTE and MOUNTPOINT out of an existing unit's ExecStart (joined over
# backslash continuations, %h expanded).
unit_parse_execstart() {
  local file=$1 line
  line=$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$file" | grep -E '^ExecStart=.*rclone +mount' | head -n 1) || true
  [[ -n $line ]] || return 1
  local r m
  r=$(sed -E 's/.*rclone +mount +([^ :]+): +.*/\1/' <<<"$line")
  m=$(sed -E 's/.*rclone +mount +[^ ]+: +("?)([^" ]+)\1.*/\2/' <<<"$line")
  [[ -n $r && -n $m ]] || return 1
  REMOTE=$r
  MOUNTPOINT=${m//%h/$HOME}
  MOUNTPOINT=${MOUNTPOINT/#\~/$HOME}
}

unit_flag() {  # unit_flag <flag> [file] → value of "--flag value" in ExecStart
  local flag=$1 file=${2:-$(unit_path)}
  sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$file" 2>/dev/null | grep -E '^ExecStart=' | grep -oE -- "$flag[ =]+[^ ]+" | head -n 1 | sed -E "s/^$flag[ =]+//"
}

unit_has_flag() { sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "${2:-$(unit_path)}" 2>/dev/null | grep -E '^ExecStart=' | grep -qE -- "$1( |$)"; }

systemctl_user() { systemctl --user "$@"; }
service_active_state() { systemctl_user show -p ActiveState --value "$SERVICE.service" 2>/dev/null || echo unknown; }
service_sub_state()    { systemctl_user show -p SubState --value "$SERVICE.service" 2>/dev/null || echo unknown; }
service_enabled()      { systemctl_user is-enabled "$SERVICE.service" >/dev/null 2>&1; }
service_result()       { systemctl_user show -p Result --value "$SERVICE.service" 2>/dev/null || echo ""; }

# The last error goes into `status --json` (shown in the bar popup) and into
# doctor's output, so scrub anything that looks like a credential first.
# Only rclone's own lines: `-u` would also match systemd's "Failed to start …",
# which hides the reason (and made a refused login look like any other failure).
service_last_error() {
  journalctl --user _SYSTEMD_USER_UNIT="$SERVICE.service" -p err -n 1 -o cat --no-pager 2>/dev/null | tail -n 1 | redact_secrets
}

# Restart backoff. A failing mount (no network, a refused login) used to be
# retried every 10 s forever; now the wait doubles up to an hour. Units from the
# template carry it; an adopted unit gets it from a drop-in (doctor --fix), so
# the user's own file is never edited.
service_has_backoff() {
  local steps; steps=$(systemctl_user show -p RestartSteps --value "$SERVICE.service" 2>/dev/null)
  [[ $steps =~ ^[0-9]+$ ]] && (( steps > 0 ))
}
backoff_dropin_path() { printf '%s/%s.service.d/50-omarchy-backoff.conf' "$SYSTEMD_USER_DIR" "$SERVICE"; }
install_backoff_dropin() {
  local path; path=$(backoff_dropin_path)
  mkdir -p "$(dirname "$path")" || return 1
  printf '%s\n' "# Written by $CLI_NAME doctor --fix: wait longer between failed starts." \
    "[Service]" "RestartSteps=8" "RestartMaxDelaySec=1h" > "$path" || return 1
  systemctl_user daemon-reload
}

# Login guard. A refused login never fixes itself, so retrying (even with the
# backoff) only burns CPU and battery. ExecStopPost runs `auth-guard`: when the
# run that just ended was refused by Google, it writes the flag file and stops the
# unit, which cancels the pending restart. ExecCondition then skips every start
# (boot included) while the flag exists and rclone.conf is not newer than it, so
# a `rclone config reconnect` made by hand also counts. ExecStartPost deletes the
# flag once a mount came up. Units from the template carry these lines; an
# adopted unit gets them from a drop-in (doctor --fix).
login_flag() { printf '%s/%s.login-refused' "$STATE_DIR" "$SERVICE"; }
login_refused() { local f; f=$(login_flag); [[ -f $f && ! $RCLONE_CONF -nt $f ]]; }
guard_dropin_path() { printf '%s/%s.service.d/60-omarchy-login-guard.conf' "$SYSTEMD_USER_DIR" "$SERVICE"; }
service_has_guard() { systemctl_user show -p ExecStopPost --value "$SERVICE.service" 2>/dev/null | grep -q 'auth-guard'; }
# systemd path forms: %h for $HOME, so the unit stays readable and portable.
unit_home_path() { local p=$1; [[ $p == "$HOME"/* ]] && p="%h${p#"$HOME"}"; printf '%s' "$p"; }
guard_unit_lines() {
  local flag conf cli
  flag=$(unit_home_path "$(login_flag)"); conf=$(unit_home_path "$RCLONE_CONF"); cli=$(unit_home_path "${SELF:-$LOCAL_BIN/$CLI_NAME}")
  printf '%s
' \
    "# Google refused the login: stay off until reconnect (no retry loop, no CPU)." \
    "ExecCondition=/bin/sh -c 'test ! -e \"\$\$1\" || test \"\$\$2\" -nt \"\$\$1\"' _ $flag $conf" \
    "ExecStartPost=-/usr/bin/rm -f $flag" \
    "ExecStopPost=-$cli auth-guard %N"
}
install_guard_dropin() {
  local path; path=$(guard_dropin_path)
  mkdir -p "$(dirname "$path")" || return 1
  { printf '%s\n' "# Written by $CLI_NAME doctor --fix." "[Service]"; guard_unit_lines; } > "$path" || return 1
  systemctl_user daemon-reload
}

# 10 % of the free space on the disk that holds the cache, clamped to 2–50 GiB.
compute_cache_max() {
  local avail gib
  mkdir -p "$CACHE_HOME" 2>/dev/null
  avail=$(df --output=avail -B1 "$CACHE_HOME" 2>/dev/null | tail -n 1 | tr -d ' ')
  [[ $avail =~ ^[0-9]+$ ]] || avail=0
  gib=$(( avail / 10 / 1024 / 1024 / 1024 ))
  (( gib < 2 )) && gib=2
  (( gib > 50 )) && gib=50
  printf '%dG' "$gib"
}

# render_unit <template> <cache-max> → unit text on stdout
render_unit() {
  local template=$1 cache=$2 mp=$MOUNTPOINT
  [[ $mp == "$HOME"/* ]] && mp="%h${mp#"$HOME"}"
  sed -e "s|@@DISPLAY_NAME@@|$DISPLAY_NAME|g" \
      -e "s|@@REMOTE@@|$REMOTE|g" \
      -e "s|@@MOUNTPOINT@@|$mp|g" \
      -e "s|@@CACHE_MAX_SIZE@@|$cache|g" \
      "$template" | awk -v guard="$(guard_unit_lines)" '$0 == "@@LOGIN_GUARD@@" { print guard; next } { print }'
}

# install_unit <template> — writes the unit if it changed; returns 0 if written.
install_unit() {
  local template=$1 cache rendered path tmp
  path=$(unit_path)
  cache=$(unit_flag --vfs-cache-max-size "$path")
  [[ -n $cache && $(unit_is_managed "$path" && echo y) == y ]] || cache=$(compute_cache_max)
  rendered=$(render_unit "$template" "$cache")
  mkdir -p "$SYSTEMD_USER_DIR"
  if [[ -f $path ]] && [[ $(cat "$path") == "$rendered" ]]; then
    return 1
  fi
  tmp=$(mktemp "$SYSTEMD_USER_DIR/.$SERVICE.XXXXXX")
  printf '%s\n' "$rendered" > "$tmp"
  mv -f "$tmp" "$path"
  systemctl_user daemon-reload
  return 0
}

# ---------------------------------------------------------------------------
# Mount and cache
# ---------------------------------------------------------------------------
mount_active() { findmnt -rn -t fuse.rclone -M "$MOUNTPOINT" >/dev/null 2>&1; }
mount_responsive() { timeout 5 ls -A "$MOUNTPOINT" >/dev/null 2>&1; }

wait_for_mount() {  # wait_for_mount [seconds]
  local i max=${1:-30}
  for (( i = 0; i < max * 2; i++ )); do
    mount_active && return 0
    [[ $(service_active_state) == failed ]] && return 1
    sleep 0.5
  done
  return 1
}

cache_dir()      { printf '%s/rclone/vfs/%s' "$CACHE_HOME" "$REMOTE"; }
cache_meta_dir() { printf '%s/rclone/vfsMeta/%s' "$CACHE_HOME" "$REMOTE"; }

cache_bytes() {
  local d
  d=$(cache_dir)
  [[ -d $d ]] || { printf '0'; return; }
  du -sb "$d" 2>/dev/null | cut -f1
}

# Files in the VFS cache still waiting to be uploaded ("Dirty": true in the metadata).
cache_pending_uploads() {
  local d
  d=$(cache_meta_dir)
  [[ -d $d ]] || { printf '0'; return; }
  grep -rlE '"Dirty": *true' "$d" 2>/dev/null | wc -l | tr -d ' '
}

cache_disk_free() {
  local d=$CACHE_HOME
  [[ -d $d ]] || d=$HOME
  df --output=avail -B1 "$d" 2>/dev/null | tail -n 1 | tr -d ' '
}

# ---------------------------------------------------------------------------
# File manager bookmark (GTK3 bookmarks: Nautilus, Thunar, file chooser)
# ---------------------------------------------------------------------------
bookmark_uri() {
  jq -rn --arg p "$MOUNTPOINT" '"file://" + ($p | split("/") | map(@uri) | join("/"))'
}
bookmark_present() { [[ -f $GTK_BOOKMARKS ]] && grep -qE "^$(bookmark_uri)( |$)" "$GTK_BOOKMARKS"; }
bookmark_add() {
  bookmark_present && return 0
  mkdir -p "$(dirname "$GTK_BOOKMARKS")"
  printf '%s %s\n' "$(bookmark_uri)" "$DISPLAY_NAME" >> "$GTK_BOOKMARKS"
}
bookmark_remove() {
  [[ -f $GTK_BOOKMARKS ]] || return 0
  local uri tmp
  uri=$(bookmark_uri)
  tmp=$(mktemp)
  grep -vE "^${uri}( |$)" "$GTK_BOOKMARKS" > "$tmp" || true
  mv -f "$tmp" "$GTK_BOOKMARKS"
}

# ---------------------------------------------------------------------------
# CLI symlink into ~/.local/bin (so `omarchy-gdrive` works after `omarchy plugin add`)
# ---------------------------------------------------------------------------
link_cli() {
  local target=$1 link="$LOCAL_BIN/$CLI_NAME"
  mkdir -p "$LOCAL_BIN"
  if [[ -L $link && $(readlink -f "$link") == "$(readlink -f "$target")" ]]; then return 1; fi
  [[ -e $link && ! -L $link ]] && return 1   # a real file: leave the user's alone
  ln -sfn "$target" "$link"
}
unlink_cli() { local link="$LOCAL_BIN/$CLI_NAME"; [[ -L $link ]] && rm -f "$link"; return 0; }

# ---------------------------------------------------------------------------
# Dependencies (pacman is the only thing that ever runs as root)
# ---------------------------------------------------------------------------
ensure_deps() {
  local missing=()
  have rclone || missing+=(rclone)
  have fusermount3 || missing+=(fuse3)
  have jq || missing+=(jq)
  (( ${#missing[@]} == 0 )) && return 0
  have pacman || die "$(t deps.missingNoPacman "${missing[*]}")"
  # Show the exact root command and ask before running it. --yes skips the
  # question; without --yes and without a terminal to ask in, nothing is
  # installed (confirm() would otherwise take its default answer).
  local cmd=(sudo pacman -S --needed --noconfirm "${missing[@]}")
  info "$(t deps.installing "${missing[*]}")"
  say "  ${cmd[*]}"
  if ! (( ASSUME_YES )); then
    interactive || die "$(t deps.needTerminal "$CLI_NAME")"
    confirm "$(t deps.confirm "${missing[*]}")" || die "$(t common.aborted)"
  fi
  "${cmd[@]}" || die "$(t deps.failed)"
}

# ---------------------------------------------------------------------------
# PROVIDER HOOKS — defaults, defined only when the provider module (sourced
# before this file) did not supply its own.
# ---------------------------------------------------------------------------
declare -F provider_setup_intro >/dev/null || provider_setup_intro() { :; }            # text shown before creating a remote
declare -F provider_create_remote >/dev/null || provider_create_remote() { die "provider_create_remote not implemented"; }
declare -F provider_own_credentials >/dev/null || provider_own_credentials() { return 0; }     # 0 = own API credentials, 1 = shared/none
declare -F provider_offer_credentials >/dev/null || provider_offer_credentials() { :; }            # setup: existing remote without own creds
declare -F provider_doctor_extra >/dev/null || provider_doctor_extra() { :; }            # extra doctor lines
declare -F provider_token_hint >/dev/null || provider_token_hint() { :; }              # doctor: after a refused login
declare -F provider_reconnect_intro >/dev/null || provider_reconnect_intro() { :; }    # reconnect: text before the browser opens
declare -F provider_quota_json >/dev/null || provider_quota_json() { printf '{}'; }  # {"total":..,"used":..,"free":..}
declare -F provider_network_ok >/dev/null || provider_network_ok() { curl -fsS -m 5 -o /dev/null https://example.com/ 2>/dev/null; }

# ---------------------------------------------------------------------------
# Summary state for the panel / status
# ---------------------------------------------------------------------------
# unconfigured | stopped | starting | mounted | error
summary_state() {
  local active=$1 mounted=$2 remote_ok=$3 unit_ok=$4 sub=${5:-}
  if [[ $remote_ok != true || $unit_ok != true ]]; then printf 'unconfigured'; return; fi
  # Between two failed starts systemd waits in "auto-restart": that is a
  # failure being retried, not a mount on its way up.
  [[ $sub == auto-restart* && $mounted != true ]] && { printf 'error'; return; }
  case $active in
    active)       [[ $mounted == true ]] && printf 'mounted' || printf 'starting' ;;
    activating|reloading) printf 'starting' ;;
    failed)       printf 'error' ;;
    *)            printf 'stopped' ;;
  esac
}

# ---------------------------------------------------------------------------
# Subcommands shared by every provider
# ---------------------------------------------------------------------------
cmd_status() {
  local rclone_ok=false remote_ok=false unit_ok=false own=false enabled=false mounted=false responsive=false
  local active sub cache_b cache_max cache_max_b pending last_err state managed
  have rclone && rclone_ok=true
  if [[ $rclone_ok == true ]]; then
    local facts; facts=$(status_remote_facts)
    [[ ${facts%%$'\t'*} == yes ]] && remote_ok=true
    [[ $remote_ok == true && ${facts##*$'\t'} == yes ]] && own=true
  fi
  unit_exists && unit_ok=true
  service_enabled && enabled=true
  active=$(service_active_state); sub=$(service_sub_state)
  mount_active && mounted=true
  [[ $mounted == true ]] && mount_responsive && responsive=true
  cache_b=$(cache_bytes); cache_max=$(unit_flag --vfs-cache-max-size); cache_max_b=$(size_to_bytes "${cache_max:-off}")
  pending=$(cache_pending_uploads)
  last_err=$(service_last_error)
  managed=${MANAGED:-$(unit_is_managed && echo template || echo adopted)}
  [[ $unit_ok == true ]] || managed=""
  state=$(summary_state "$active" "$mounted" "$remote_ok" "$unit_ok" "$sub")
  [[ $state == mounted && $responsive != true ]] && state=error
  # Google refused the login: say so, so the widget can offer a reconnect.
  local auth_expired=false
  [[ $state == error ]] && is_auth_error "$last_err" && auth_expired=true
  # The guard stopped the unit after a refused login: off on purpose, waiting for reconnect.
  if [[ $mounted != true && $unit_ok == true ]] && login_refused; then
    state=error; auth_expired=true
    [[ -n $last_err ]] || last_err=$(head -n 1 "$(login_flag)" | redact_secrets | cut -c1-300)
  fi

  if (( JSON_OUTPUT )); then
    jq -n \
      --arg provider "$PROVIDER_ID" --arg displayName "$DISPLAY_NAME" \
      --arg remote "$REMOTE" --arg mountpoint "$MOUNTPOINT" --arg service "$SERVICE" --arg managed "$managed" \
      --argjson rclone "$rclone_ok" --argjson remoteExists "$remote_ok" --argjson unitExists "$unit_ok" --argjson ownClient "$own" \
      --arg activeState "$active" --arg subState "$sub" --argjson enabled "$enabled" \
      --argjson mounted "$mounted" --argjson responsive "$responsive" \
      --argjson cacheBytes "${cache_b:-0}" --arg cacheMax "${cache_max:-off}" --argjson cacheMaxBytes "${cache_max_b:-0}" \
      --argjson pendingUploads "${pending:-0}" --arg lastError "$last_err" --arg state "$state" \
      --argjson authExpired "$auth_expired" \
      --arg version "$CLI_VERSION" \
      '$ARGS.named'
    return 0
  fi

  title "$DISPLAY_NAME"
  case $state in
    mounted)      ok   "$(t status.mounted "$MOUNTPOINT")" ;;
    starting)     info "$(t status.starting "$MOUNTPOINT")" ;;
    stopped)      warn "$(t status.stopped "$MOUNTPOINT")" ;;
    error)        fail "$(t status.error "$MOUNTPOINT")" ;;
    unconfigured) warn "$(t status.unconfigured "$CLI_NAME")" ;;
  esac
  if [[ $unit_ok == true ]]; then
    say "  $(t status.service "$SERVICE" "$active ($sub)" "$([[ $enabled == true ]] && t common.enabled || t common.disabled)" "$(t "managed.$managed")")"
  fi
  if [[ $remote_ok == true ]]; then
    say "  $(t status.remote "$REMOTE" "$([[ $own == true ]] && t creds.own || t creds.shared)")"
  fi
  say "  $(t status.cache "$(human_bytes "$cache_b")" "${cache_max:-∞}" "$pending")"
  [[ -n $last_err ]] && say "  $(t status.lastError "$last_err")"
  [[ $auth_expired == true ]] && say "  $(t status.authExpired "$CLI_NAME")"
  [[ $state == mounted ]]
}

cmd_start() {
  unit_exists || die "$(t err.noUnit "$CLI_NAME")"
  login_refused && die "$(t err.loginRefused "$CLI_NAME")"
  mkdir -p "$MOUNTPOINT"
  systemctl_user start "$SERVICE.service" || die "$(t err.startFailed "$SERVICE")"
  if wait_for_mount 30; then ok "$(t start.ok "$MOUNTPOINT")"; else
    fail "$(t start.timeout)"; journalctl --user -u "$SERVICE.service" -n 15 --no-pager -o cat >&2; return 1
  fi
}

cmd_stop() {
  local pending
  pending=$(cache_pending_uploads)
  if (( pending > 0 )) && ! (( ASSUME_YES )); then
    warn "$(t stop.pending "$pending")"
    confirm "$(t stop.confirm)" no || { say "$(t common.aborted)"; return 1; }
  fi
  systemctl_user stop "$SERVICE.service" 2>/dev/null || true
  mount_active && fusermount3 -uz "$MOUNTPOINT" 2>/dev/null
  ok "$(t stop.ok)"
}

cmd_restart() { cmd_stop && cmd_start; }

# Sign in to Google again (the browser opens once), then bring the mount back.
# This is the whole fix when the token was refused (invalid_grant).
cmd_reconnect() {
  have rclone || die "$(t doctor.noRclone)"
  remote_exists || die "$(t doctor.noRemote "$REMOTE" "$CLI_NAME")"
  title "$(t reconnect.title "$DISPLAY_NAME")"
  provider_reconnect_intro
  interactive || die "$(t reconnect.nonInteractive "$CLI_NAME")"
  rclone config reconnect "$REMOTE:" </dev/tty || die "$(t reconnect.failed "$CLI_NAME")"
  secure_rclone_conf
  if remote_token_ok; then ok "$(t reconnect.ok "$REMOTE")"; else
    fail "$(t reconnect.verifyFailed)"
    [[ -n $REMOTE_TOKEN_ERROR ]] && say "    ${C_DIM}${REMOTE_TOKEN_ERROR}${C_RESET}"
    return 1
  fi
  rm -f "$(login_flag)"
  unit_exists || return 0
  # Clear the failure counter and any backoff, then start fresh.
  systemctl_user reset-failed "$SERVICE.service" >/dev/null 2>&1 || true
  systemctl_user stop "$SERVICE.service" >/dev/null 2>&1 || true
  cmd_start
}

# auth-guard <unit-name> — run by systemd as ExecStopPost, never by hand.
# If the run that just ended died because Google refused the login, write the
# flag and stop the unit (cancels the queued restart). Any other failure (no
# network, a hiccup) is left to the normal restart with backoff.
cmd_auth_guard() {
  [[ -n ${1:-} ]] && SERVICE=$1
  [[ ${SERVICE_RESULT:-success} == success || -z ${INVOCATION_ID:-} ]] && return 0
  local line="" i
  # rclone's last words can reach the journal a moment after it exited.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    line=$(journalctl --user _SYSTEMD_INVOCATION_ID="$INVOCATION_ID" -o cat --no-pager 2>/dev/null | grep -iE "$AUTH_ERROR_RE" | tail -n 1)
    [[ -n $line ]] && break
    sleep 0.2
  done
  [[ -n $line ]] || return 0
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$line" | redact_secrets > "$(login_flag)"
  printf '%s\n' "$(t guard.stopping "$SERVICE" "$CLI_NAME")"
  systemctl_user --no-block stop "$SERVICE.service"
}

cmd_logs() {
  local follow=1 lines=100
  while (( $# )); do
    case $1 in
      -n|--lines) lines=$2; shift 2 ;;
      --no-follow) follow=0; shift ;;
      *) shift ;;
    esac
  done
  if (( follow )) && interactive; then
    exec journalctl --user -u "$SERVICE.service" -n "$lines" -f --no-pager
  else
    journalctl --user -u "$SERVICE.service" -n "$lines" --no-pager
  fi
}

cmd_open() {
  mount_active || warn "$(t open.notMounted)"
  mkdir -p "$MOUNTPOINT"
  if have xdg-open; then nohup xdg-open "$MOUNTPOINT" >/dev/null 2>&1 & else nautilus "$MOUNTPOINT" >/dev/null 2>&1 & fi
}

cmd_quota() {
  local json
  json=$(provider_quota_json)
  if (( JSON_OUTPUT )); then printf '%s\n' "$json"; return; fi
  local total used free
  total=$(jq -r '.total // empty' <<<"$json"); used=$(jq -r '.used // empty' <<<"$json"); free=$(jq -r '.free // empty' <<<"$json")
  [[ -n $used ]] || die "$(t quota.unavailable)"
  say "$(t quota.line "$(human_bytes "$used")" "$(human_bytes "${total:-0}")" "$(human_bytes "${free:-0}")")"
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
DOCTOR_FAILS=0; DOCTOR_WARNS=0; DOCTOR_FIX=0
d_ok()   { ok   "$*"; }
d_warn() { warn "$*"; DOCTOR_WARNS=$((DOCTOR_WARNS + 1)); }
d_fail() { fail "$*"; DOCTOR_FAILS=$((DOCTOR_FAILS + 1)); }

cmd_doctor() {
  [[ ${1:-} == --fix ]] && DOCTOR_FIX=1
  title "$(t doctor.title "$DISPLAY_NAME")"

  # 1. tools
  if have rclone; then d_ok "$(t doctor.rclone "$(rclone version 2>/dev/null | head -n 1 | awk '{print $2}')")"; else d_fail "$(t doctor.noRclone)"; fi
  if have fusermount3; then d_ok "$(t doctor.fuse)"; else d_fail "$(t doctor.noFuse)"; fi

  # 2. rclone.conf
  if [[ -f $RCLONE_CONF ]]; then
    local mode; mode=$(rclone_conf_mode)
    if [[ $mode == 600 ]]; then d_ok "$(t doctor.confPerms "$RCLONE_CONF")"; else
      if (( DOCTOR_FIX )); then secure_rclone_conf; d_ok "$(t doctor.confPermsFixed "$RCLONE_CONF")"; else d_warn "$(t doctor.confPermsBad "$RCLONE_CONF" "$mode" "$CLI_NAME")"; fi
    fi
  else
    d_fail "$(t doctor.noConf "$RCLONE_CONF")"
  fi

  # 3. remote
  local remote_ok=0
  if have rclone && remote_exists; then
    local type; type=$(remote_type)
    if [[ $type == "$BACKEND_TYPE" ]]; then d_ok "$(t doctor.remote "$REMOTE" "$type")"; remote_ok=1; else d_fail "$(t doctor.remoteWrongType "$REMOTE" "$type" "$BACKEND_TYPE")"; fi
  else
    d_fail "$(t doctor.noRemote "$REMOTE" "$CLI_NAME")"
  fi

  # 4. provider specifics (own credentials, etc.)
  (( remote_ok )) && provider_doctor_extra

  # 5. network + token
  if provider_network_ok; then d_ok "$(t doctor.network)"; else d_warn "$(t doctor.noNetwork)"; fi
  if (( remote_ok )); then
    # A responsive mount already proves the token works (rclone mount holds it),
    # and skipping the extra round trip spares the shared client's quota.
    if mount_active && mount_responsive; then
      d_ok "$(t doctor.tokenViaMount)"
    elif remote_token_ok; then
      d_ok "$(t doctor.token)"
    else
      case $REMOTE_TOKEN_KIND in
        throttled)   d_warn "$(t doctor.tokenThrottled "$CLI_NAME")" ;;
        invalid)     d_fail "$(t doctor.tokenBad "$CLI_NAME")"; provider_token_hint ;;
        *)           d_warn "$(t doctor.tokenUnreachable)" ;;
      esac
      [[ -n $REMOTE_TOKEN_ERROR ]] && say "    ${C_DIM}${REMOTE_TOKEN_ERROR}${C_RESET}"
    fi
  fi

  # 6. unit
  if unit_exists; then
    local managed; managed=$(unit_is_managed && echo template || echo adopted)
    d_ok "$(t doctor.unit "$(unit_path)" "$(t "managed.$managed")")"
    if unit_has_flag "--vfs-cache-mode full"; then d_ok "$(t doctor.vfsFull)"; else d_warn "$(t doctor.vfsNotFull)"; fi
    if service_enabled; then d_ok "$(t doctor.enabled "$SERVICE")"; else
      if (( DOCTOR_FIX )); then systemctl_user enable "$SERVICE.service" >/dev/null 2>&1 && d_ok "$(t doctor.enabledFixed "$SERVICE")"; else d_warn "$(t doctor.notEnabled "$SERVICE")"; fi
    fi
    if service_has_backoff; then d_ok "$(t doctor.backoff)"; else
      if (( DOCTOR_FIX )); then install_backoff_dropin && d_ok "$(t doctor.backoffFixed "$(backoff_dropin_path)")"; else d_warn "$(t doctor.noBackoff "$CLI_NAME")"; fi
    fi
    if service_has_guard; then d_ok "$(t doctor.guard)"; else
      if (( DOCTOR_FIX )); then install_guard_dropin && d_ok "$(t doctor.guardFixed "$(guard_dropin_path)")"; else d_warn "$(t doctor.noGuard "$CLI_NAME")"; fi
    fi
    login_refused && d_fail "$(t doctor.loginRefused "$CLI_NAME")"
    local active; active=$(service_active_state)
    [[ $(service_sub_state) == auto-restart* ]] && active=failed
    case $active in
      active) d_ok "$(t doctor.active "$SERVICE")" ;;
      failed) d_fail "$(t doctor.failed "$SERVICE" "$(service_last_error)" "$CLI_NAME")" ;;
      *) d_warn "$(t doctor.inactive "$SERVICE" "$active" "$CLI_NAME")" ;;
    esac
  else
    d_fail "$(t doctor.noUnit "$(unit_path)" "$CLI_NAME")"
  fi

  # 7. mount
  if mount_active; then
    if mount_responsive; then d_ok "$(t doctor.mounted "$MOUNTPOINT")"; else d_fail "$(t doctor.mountHung "$MOUNTPOINT" "$CLI_NAME")"; fi
  else
    if [[ -d $MOUNTPOINT ]] && [[ -n $(ls -A "$MOUNTPOINT" 2>/dev/null) ]]; then d_warn "$(t doctor.mountpointDirty "$MOUNTPOINT")"; fi
    if [[ $(service_active_state) == active ]]; then d_fail "$(t doctor.notMountedActive "$MOUNTPOINT")"; else d_warn "$(t doctor.notMounted "$MOUNTPOINT" "$CLI_NAME")"; fi
  fi

  # 8. cache
  local cb cm cmb pending free
  cb=$(cache_bytes); cm=$(unit_flag --vfs-cache-max-size); cmb=$(size_to_bytes "${cm:-off}"); pending=$(cache_pending_uploads); free=$(cache_disk_free)
  if [[ -n $cm && $cmb -gt 0 ]] && (( cb * 100 / cmb >= 90 )); then d_warn "$(t doctor.cacheFull "$(human_bytes "$cb")" "$cm")"; else d_ok "$(t doctor.cache "$(human_bytes "$cb")" "${cm:-∞}" "$(cache_dir)")"; fi
  if (( pending > 0 )); then d_warn "$(t doctor.pending "$pending")"; else d_ok "$(t doctor.noPending)"; fi
  if [[ ${free:-0} =~ ^[0-9]+$ ]] && (( free < 2 * 1024 * 1024 * 1024 )); then d_warn "$(t doctor.diskLow "$(human_bytes "$free")")"; fi

  # 9. desktop integration
  if bookmark_present; then d_ok "$(t doctor.bookmark)"; else
    if (( DOCTOR_FIX )); then bookmark_add; d_ok "$(t doctor.bookmarkFixed)"; else d_warn "$(t doctor.noBookmark "$CLI_NAME")"; fi
  fi
  if have "$CLI_NAME"; then d_ok "$(t doctor.inPath "$CLI_NAME")"; else info "$(t doctor.notInPath "$CLI_NAME")"; fi

  hr
  if (( DOCTOR_FAILS == 0 && DOCTOR_WARNS == 0 )); then ok "$(t doctor.allGood)"
  elif (( DOCTOR_FAILS == 0 )); then warn "$(t doctor.warnings "$DOCTOR_WARNS")"
  else fail "$(t doctor.failures "$DOCTOR_FAILS" "$DOCTOR_WARNS")"; fi
  (( DOCTOR_FAILS == 0 ))
}

# ---------------------------------------------------------------------------
# remove — undo everything on this machine; never touches data in the cloud
# ---------------------------------------------------------------------------
cmd_remove() {
  local keep_remote=0 purge_cache=0 force=0
  while (( $# )); do
    case $1 in
      --keep-remote) keep_remote=1 ;;
      --purge-cache) purge_cache=1 ;;
      --force) force=1 ;;
    esac
    shift
  done
  title "$(t remove.title "$DISPLAY_NAME")"
  say "$(t remove.intro)"
  confirm "$(t remove.confirm)" no || { say "$(t common.aborted)"; return 1; }

  local pending; pending=$(cache_pending_uploads)
  if (( pending > 0 && ! force )); then
    die "$(t remove.pendingRefuse "$pending" "$CLI_NAME")"
  fi

  # service
  if unit_exists; then
    systemctl_user disable --now "$SERVICE.service" >/dev/null 2>&1 || true
    mount_active && fusermount3 -uz "$MOUNTPOINT" 2>/dev/null
    if unit_is_managed || (( ASSUME_YES )) || confirm "$(t remove.unitAdopted "$(unit_path)")" no; then
      rm -f "$(unit_path)"; systemctl_user daemon-reload; ok "$(t remove.unitRemoved "$(unit_path)")"
    else
      info "$(t remove.unitKept "$(unit_path)")"
    fi
    # Our own drop-ins point at this CLI; they go with it.
    rm -f "$(backoff_dropin_path)" "$(guard_dropin_path)"
    rmdir "$(dirname "$(guard_dropin_path)")" 2>/dev/null
    systemctl_user daemon-reload
  fi

  # desktop bits
  bookmark_remove && ok "$(t remove.bookmark)"
  unlink_cli

  # remote credentials
  if (( ! keep_remote )) && have rclone && remote_exists; then
    if (( ASSUME_YES )) || confirm "$(t remove.remoteConfirm "$REMOTE")" no; then
      rclone config delete "$REMOTE" && ok "$(t remove.remoteDeleted "$REMOTE")"
    else
      info "$(t remove.remoteKept "$REMOTE")"
    fi
  fi

  # cache
  if [[ -d $(cache_dir) || -d $(cache_meta_dir) ]]; then
    if (( purge_cache )) || confirm "$(t remove.cacheConfirm "$(human_bytes "$(cache_bytes)")" "$(cache_dir)")" no; then
      rm -rf "$(cache_dir)" "$(cache_meta_dir)"; ok "$(t remove.cachePurged)"
    else
      info "$(t remove.cacheKept "$(cache_dir)")"
    fi
  fi

  # mount point directory (only when empty)
  if [[ -d $MOUNTPOINT ]] && ! mount_active; then
    rmdir "$MOUNTPOINT" 2>/dev/null && ok "$(t remove.mountpointRemoved "$MOUNTPOINT")" || info "$(t remove.mountpointKept "$MOUNTPOINT")"
  fi

  rm -rf "$STATE_DIR"
  ok "$(t remove.done)"
}
