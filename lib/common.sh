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
: "${CLI_VERSION:=0.1.0}"
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

# A real round trip with a short budget: proves the token (and the network) work.
REMOTE_TOKEN_ERROR=""
remote_token_ok() {
  local out
  out=$(timeout 45 rclone lsjson "$REMOTE:" --max-depth 1 --contimeout 10s --timeout 30s --low-level-retries 3 --retries 2 2>&1 >/dev/null)
  local rc=$?
  # rclone's error lines never contain the token; keep a one-line reason for doctor.
  REMOTE_TOKEN_ERROR=$(grep -vE 'shared Google Drive client_id|^\s*[]},]*\s*$' <<<"$out" | grep -E 'ERROR|CRITICAL|Failed|rateLimit|invalid_grant|token' | tail -n 1 | sed -E 's/^[0-9/ :]+ (ERROR|CRITICAL|NOTICE) ?:? ?//' | cut -c1-160)
  REMOTE_TOKEN_KIND=ok
  if (( rc != 0 )); then
    if grep -qiE 'rateLimitExceeded|userRateLimitExceeded|quotaExceeded|429' <<<"$out"; then REMOTE_TOKEN_KIND=throttled
    elif grep -qiE 'invalid_grant|expired or revoked|empty token|couldn.t fetch token|unauthorized_client|invalid_client|deleted_client' <<<"$out"; then REMOTE_TOKEN_KIND=invalid
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

service_last_error() {
  journalctl --user -u "$SERVICE.service" -p err -n 1 -o cat --no-pager 2>/dev/null | tail -n 1
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
      "$template"
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
  info "$(t deps.installing "${missing[*]}")"
  confirm "$(t deps.confirm "${missing[*]}")" || die "$(t common.aborted)"
  sudo pacman -S --needed --noconfirm "${missing[@]}" || die "$(t deps.failed)"
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
declare -F provider_quota_json >/dev/null || provider_quota_json() { printf '{}'; }  # {"total":..,"used":..,"free":..}
declare -F provider_network_ok >/dev/null || provider_network_ok() { curl -fsS -m 5 -o /dev/null https://example.com/ 2>/dev/null; }

# ---------------------------------------------------------------------------
# Summary state for the panel / status
# ---------------------------------------------------------------------------
# unconfigured | stopped | starting | mounted | error
summary_state() {
  local active=$1 mounted=$2 remote_ok=$3 unit_ok=$4
  if [[ $remote_ok != true || $unit_ok != true ]]; then printf 'unconfigured'; return; fi
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
  [[ $rclone_ok == true ]] && remote_exists && remote_ok=true
  unit_exists && unit_ok=true
  [[ $remote_ok == true ]] && provider_own_credentials && own=true
  service_enabled && enabled=true
  active=$(service_active_state); sub=$(service_sub_state)
  mount_active && mounted=true
  [[ $mounted == true ]] && mount_responsive && responsive=true
  cache_b=$(cache_bytes); cache_max=$(unit_flag --vfs-cache-max-size); cache_max_b=$(size_to_bytes "${cache_max:-off}")
  pending=$(cache_pending_uploads)
  last_err=$(service_last_error)
  managed=${MANAGED:-$(unit_is_managed && echo template || echo adopted)}
  [[ $unit_ok == true ]] || managed=""
  state=$(summary_state "$active" "$mounted" "$remote_ok" "$unit_ok")
  [[ $state == mounted && $responsive != true ]] && state=error

  if (( JSON_OUTPUT )); then
    jq -n \
      --arg provider "$PROVIDER_ID" --arg displayName "$DISPLAY_NAME" \
      --arg remote "$REMOTE" --arg mountpoint "$MOUNTPOINT" --arg service "$SERVICE" --arg managed "$managed" \
      --argjson rclone "$rclone_ok" --argjson remoteExists "$remote_ok" --argjson unitExists "$unit_ok" --argjson ownClient "$own" \
      --arg activeState "$active" --arg subState "$sub" --argjson enabled "$enabled" \
      --argjson mounted "$mounted" --argjson responsive "$responsive" \
      --argjson cacheBytes "${cache_b:-0}" --arg cacheMax "${cache_max:-off}" --argjson cacheMaxBytes "${cache_max_b:-0}" \
      --argjson pendingUploads "${pending:-0}" --arg lastError "$last_err" --arg state "$state" \
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
  [[ $state == mounted ]]
}

cmd_start() {
  unit_exists || die "$(t err.noUnit "$CLI_NAME")"
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
        invalid)     d_fail "$(t doctor.tokenBad "$REMOTE")" ;;
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
    local active; active=$(service_active_state)
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
