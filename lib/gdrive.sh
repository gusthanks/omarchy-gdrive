# shellcheck shell=bash
# lib/gdrive.sh — the Google Drive specific half of omarchy-gdrive.
#
# Knows about: the `drive` backend, Google's OAuth client_id/client_secret,
# the retirement of rclone's shared client_id (2026), the Google Cloud Console
# steps and Drive quota. Everything else is in lib/common.sh.

CLI_NAME="omarchy-gdrive"
PROVIDER_ID="gdrive"
DISPLAY_NAME="Google Drive"
BACKEND_TYPE="drive"
DEFAULT_REMOTE="gdrive"
DEFAULT_MOUNTPOINT="$HOME/GoogleDrive"
DEFAULT_SERVICE="rclone-gdrive"

GDRIVE_SCOPE="drive"
GDRIVE_CONSOLE_URL="https://console.cloud.google.com/"
: "${REPO_URL:=https://github.com/gusthanks/omarchy-gdrive}"
GDRIVE_DOCS_URL="$REPO_URL/blob/main/docs/own-client-id.md"
GDRIVE_RCLONE_DOC_URL="https://rclone.org/drive/#making-your-own-client-id"
GDRIVE_API_PROBE_URL="https://www.googleapis.com/discovery/v1/apis"

# Options parsed from the command line by cmd_setup.
GDRIVE_CREDENTIALS_FILE=""
GDRIVE_ACCEPT_SHARED=0

provider_network_ok() {
  # Any HTTP answer (even 4xx) proves we can reach Google; -f would hide that.
  curl -sS -m 5 -o /dev/null -w '%{http_code}' "$GDRIVE_API_PROBE_URL" 2>/dev/null | grep -qE '^[1-5][0-9][0-9]$'
}

# The same test, as a jq filter on the remote's config object, for the cached
# status poll (status_remote_facts). Keep the two in step.
PROVIDER_OWN_CLIENT_JQ='((.client_id // "") != "" and (.client_secret // "") != "")'

# 0 when the remote carries its own client_id (and secret), 1 when it relies
# on rclone's shared one.
provider_own_credentials() {
  local id secret
  id=$(remote_option client_id)
  secret=$(remote_option client_secret)
  [[ -n $id && -n $secret ]]
}

provider_doctor_extra() {
  if provider_own_credentials; then
    d_ok "$(t gdrive.doctor.ownClient "$REMOTE")"
  else
    d_warn "$(t gdrive.doctor.sharedClient "$REMOTE" "$CLI_NAME")"
  fi
}

provider_quota_json() {
  # `rclone about` is slow on Drive (often 10–20 s); callers cache the result.
  timeout 45 rclone about "$REMOTE:" --json 2>/dev/null || printf '{}'
}

# Why this matters, in plain words. Shown once during setup.
provider_setup_intro() {
  title "$(t gdrive.why.title)"
  say "$(t gdrive.why.1)"
  say "$(t gdrive.why.2)"
  say "$(t gdrive.why.3)"
  say ""
  say "$(t gdrive.why.docs "$GDRIVE_DOCS_URL")"
}

# ---------------------------------------------------------------------------
# Credentials: find the client_secret_*.json Google hands out, or ask.
# ---------------------------------------------------------------------------
gdrive_find_credentials_json() {
  local downloads
  downloads=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
  # Newest file first. Google names them client_secret_<id>.json.
  find ${downloads:+"$downloads"} "$HOME/Downloads" "$HOME" -maxdepth 1 -type f -name 'client_secret*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -u | sort -rn | head -n 1 | cut -d' ' -f2-
}

# gdrive_read_credentials <file> → sets GDRIVE_CLIENT_ID / GDRIVE_CLIENT_SECRET
gdrive_read_credentials() {
  local file=$1
  GDRIVE_CLIENT_ID=$(jq -r '(.installed // .web // .) | .client_id // empty' "$file" 2>/dev/null)
  GDRIVE_CLIENT_SECRET=$(jq -r '(.installed // .web // .) | .client_secret // empty' "$file" 2>/dev/null)
  [[ -n $GDRIVE_CLIENT_ID && -n $GDRIVE_CLIENT_SECRET ]]
}

# Interactive: returns 0 with GDRIVE_CLIENT_ID/SECRET set, or 1 when the user
# chose to continue with rclone's shared client.
gdrive_obtain_credentials() {
  GDRIVE_CLIENT_ID=""; GDRIVE_CLIENT_SECRET=""

  if [[ -n $GDRIVE_CREDENTIALS_FILE ]]; then
    gdrive_read_credentials "$GDRIVE_CREDENTIALS_FILE" || die "$(t gdrive.creds.badFile "$GDRIVE_CREDENTIALS_FILE")"
    ok "$(t gdrive.creds.loaded "$GDRIVE_CREDENTIALS_FILE")"
    return 0
  fi
  (( GDRIVE_ACCEPT_SHARED )) && return 1

  local found
  found=$(gdrive_find_credentials_json)
  if [[ -n $found ]] && gdrive_read_credentials "$found"; then
    if confirm "$(t gdrive.creds.useFound "$found")"; then
      ok "$(t gdrive.creds.loaded "$found")"
      return 0
    fi
    GDRIVE_CLIENT_ID=""; GDRIVE_CLIENT_SECRET=""
  fi

  if ! interactive; then
    warn "$(t gdrive.creds.nonInteractive)"
    return 1
  fi

  local opt_file opt_paste opt_shared pick
  opt_file=$(t gdrive.creds.optFile); opt_paste=$(t gdrive.creds.optPaste); opt_shared=$(t gdrive.creds.optShared)
  while :; do
    pick=$(choose "$(t gdrive.creds.choose)" "$opt_file" "$opt_paste" "$opt_shared")
    case $pick in
      "$opt_file")
        say "$(t gdrive.creds.howTo "$GDRIVE_DOCS_URL")"
        local f; f=$(prompt "$(t gdrive.creds.pathPrompt)")
        f=${f/#\~/$HOME}
        if [[ -f $f ]] && gdrive_read_credentials "$f"; then ok "$(t gdrive.creds.loaded "$f")"; return 0; fi
        fail "$(t gdrive.creds.badFile "$f")"
        ;;
      "$opt_paste")
        GDRIVE_CLIENT_ID=$(prompt "$(t gdrive.creds.idPrompt)")
        GDRIVE_CLIENT_SECRET=$(prompt "$(t gdrive.creds.secretPrompt)" --password)
        if [[ $GDRIVE_CLIENT_ID == *.apps.googleusercontent.com && -n $GDRIVE_CLIENT_SECRET ]]; then return 0; fi
        fail "$(t gdrive.creds.badPaste)"
        GDRIVE_CLIENT_ID=""; GDRIVE_CLIENT_SECRET=""
        ;;
      *)
        warn "$(t gdrive.creds.sharedWarning)"
        return 1
        ;;
    esac
  done
}

# Writes client_secret into the remote's stanza without passing it on a command
# line (so it never shows up in `ps` or shell history). rclone.conf is a plain
# INI file; the line goes right under the [remote] header.
gdrive_set_client_secret() {
  local secret=$1 tmp
  [[ -f $RCLONE_CONF ]] || return 1
  tmp=$(mktemp "$(dirname "$RCLONE_CONF")/.rclone.conf.XXXXXX")
  awk -v r="[$REMOTE]" -v line="client_secret = $secret" '
    { if (in_r && $0 ~ /^client_secret *=/) next; print }
    $0 == r { print line; in_r = 1; next }
    /^\[/ { in_r = 0 }
  ' "$RCLONE_CONF" > "$tmp" && mv -f "$tmp" "$RCLONE_CONF"
  chmod 600 "$RCLONE_CONF"
}

# Create (or re-credential) the remote, then run Google's OAuth flow in the browser.
provider_create_remote() {
  local had_remote=0
  remote_exists && had_remote=1

  if gdrive_obtain_credentials; then
    if (( had_remote )); then
      rclone config update "$REMOTE" client_id="$GDRIVE_CLIENT_ID" --non-interactive >/dev/null 2>&1
    else
      rclone config create "$REMOTE" "$BACKEND_TYPE" scope="$GDRIVE_SCOPE" client_id="$GDRIVE_CLIENT_ID" --non-interactive >/dev/null 2>&1
    fi
    gdrive_set_client_secret "$GDRIVE_CLIENT_SECRET" || die "$(t gdrive.creds.writeFailed "$RCLONE_CONF")"
    GDRIVE_CLIENT_SECRET=""
    ok "$(t gdrive.creds.saved "$REMOTE")"
  elif (( ! had_remote )); then
    rclone config create "$REMOTE" "$BACKEND_TYPE" scope="$GDRIVE_SCOPE" --non-interactive >/dev/null 2>&1
  fi
  secure_rclone_conf

  title "$(t gdrive.auth.title)"
  say "$(t gdrive.auth.1)"
  say "$(t gdrive.auth.2)"
  say "$(t gdrive.auth.3)"
  say ""
  if ! interactive; then die "$(t gdrive.auth.nonInteractive "$REMOTE")"; fi
  rclone config reconnect "$REMOTE:" </dev/tty || die "$(t gdrive.auth.failed "$REMOTE")"
  if remote_token_ok; then ok "$(t gdrive.auth.ok "$REMOTE")"; else die "$(t gdrive.auth.verifyFailed "$REMOTE")"; fi
}

# setup: the remote already exists but still uses the shared client.
provider_offer_credentials() {
  provider_own_credentials && { ok "$(t gdrive.doctor.ownClient "$REMOTE")"; return 0; }
  (( GDRIVE_ACCEPT_SHARED )) && { warn "$(t gdrive.creds.sharedWarning)"; return 0; }
  warn "$(t gdrive.creds.existingShared "$REMOTE")"
  provider_setup_intro
  if confirm "$(t gdrive.creds.upgradeNow)"; then
    provider_create_remote
  else
    info "$(t gdrive.creds.upgradeLater "$CLI_NAME")"
  fi
}
