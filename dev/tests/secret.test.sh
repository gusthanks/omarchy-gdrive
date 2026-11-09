#!/usr/bin/env bash
# gdrive_set_client_secret: the secret lands in the right stanza byte for byte,
# never on a command line, and the file ends up mode 600. Runs on a throwaway
# rclone.conf in a temp dir; never calls rclone, never reads your real config.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A fake awk that records its argv, so we can prove the secret is not there.
mkdir -p "$tmp/bin"
real_awk=$(command -v awk)
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/argv"\nexec %s "$@"\n' "$tmp" "$real_awk" > "$tmp/bin/awk"
chmod +x "$tmp/bin/awk"

export RCLONE_CONFIG="$tmp/rclone.conf" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache"
cat > "$RCLONE_CONFIG" <<'CONF'
[other]
type = drive
client_secret = keep-me

[gdrive]
type = drive
client_id = 123-mock.apps.googleusercontent.com
client_secret = old

[last]
type = local
CONF
chmod 644 "$RCLONE_CONFIG"

secret='GOCSPX-mock\n\\t$HOME`x`"q"'"'"'s&|/'
PATH="$tmp/bin:$PATH" bash -c '
  source "$1/lib/i18n.sh"; source "$1/lib/gdrive.sh"; source "$1/lib/common.sh"
  REMOTE=gdrive
  gdrive_set_client_secret "$2"
' _ "$repo" "$secret"

fail() { echo "FAIL: $*" >&2; exit 1; }
got=$(awk '/^\[gdrive\]/{f=1;next} /^\[/{f=0} f && /^client_secret = /{sub(/^client_secret = /,""); print}' "$RCLONE_CONFIG")
[[ $got == "$secret" ]] || fail "secret mangled: <$got> != <$secret>"
[[ $(grep -c '^client_secret' "$RCLONE_CONFIG") == 2 ]] || fail "expected exactly 2 client_secret lines"
grep -qx 'client_secret = keep-me' "$RCLONE_CONFIG" || fail "other remote's secret changed"
[[ $(stat -c %a "$RCLONE_CONFIG") == 600 ]] || fail "rclone.conf is not mode 600"
[[ -s $tmp/argv ]] || fail "awk was not called through the recorder"
! grep -qF 'GOCSPX' "$tmp/argv" || fail "secret appeared on awk's command line"
[[ -z $(ls -A "$tmp" | grep '^\.rclone\.conf\.') ]] || fail "temp file left behind"

# A secret with a newline is refused (it could inject config lines).
if bash -c 'source "$1/lib/i18n.sh"; source "$1/lib/gdrive.sh"; source "$1/lib/common.sh"; REMOTE=gdrive; gdrive_set_client_secret "$2"' _ "$repo" $'a\n[evil]'; then
  fail "secret with a newline was accepted"
fi
grep -q '^\[evil\]' "$RCLONE_CONFIG" && fail "newline injected a section"
echo "ok - client secret stays off argv, keeps its bytes, file is 600"
