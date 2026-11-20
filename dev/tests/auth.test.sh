#!/usr/bin/env bash
# A refused Google login (invalid_grant) is recognised, the bar sees it as a
# problem instead of "starting…" forever, and doctor --fix adds the restart
# backoff as a drop-in. Runs in a temp dir with systemctl stubbed: never touches
# your real units, never calls rclone.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export LINE='' XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" RCLONE_CONFIG="$tmp/rclone.conf"
fail() { echo "FAIL: $*" >&2; exit 1; }

run() {
  bash -c '
    source "$1/lib/i18n.sh"; source "$1/lib/gdrive.sh"; source "$1/lib/common.sh"
    T=$2; systemctl_user() { printf "%s\n" "$*" >> "$T/systemctl.log"; }
    shift 2; eval "$*"
  ' _ "$repo" "$tmp" "$@"
}

# The exact line rclone logs when Google refuses the refresh token.
line='ERROR+4: Failed to create file system for "gdrive:": couldn'"'"'t find root directory ID: Get "https://www.googleapis.com/drive/v3/files/root?alt=json": couldn'"'"'t fetch token: invalid_grant: maybe token expired? - try refreshing with "rclone config reconnect gdrive:"'
LINE=$line run 'is_auth_error "$LINE"' || fail "invalid_grant line not recognised"
run 'is_auth_error "dial tcp: lookup www.googleapis.com: no such host"' && fail "a network error was taken for a refused login"

# Waiting between two failed starts is a problem, not "starting".
[[ $(run 'summary_state activating false true true auto-restart') == error ]] || fail "auto-restart not reported as error"
[[ $(run 'summary_state activating false true true start') == starting ]] || fail "a real start was reported as error"
[[ $(run 'summary_state active true true true running') == mounted ]] || fail "mounted state broken"

# doctor --fix: the backoff goes into a drop-in, never into the unit itself.
run 'install_backoff_dropin' || fail "install_backoff_dropin failed"
dropin="$tmp/config/systemd/user/rclone-gdrive.service.d/50-omarchy-backoff.conf"
[[ -f $dropin ]] || fail "drop-in not written at $dropin"
grep -qx 'RestartSteps=8' "$dropin" || fail "drop-in lacks RestartSteps"
grep -qx 'RestartMaxDelaySec=1h' "$dropin" || fail "drop-in lacks RestartMaxDelaySec"
grep -qx 'daemon-reload' "$tmp/systemctl.log" || fail "no daemon-reload after writing the drop-in"
[[ ! -e $tmp/config/systemd/user/rclone-gdrive.service ]] || fail "the unit file itself was created"

# The template carries the same backoff.
grep -qx 'RestartSteps=8' "$repo/templates/rclone-gdrive.service" || fail "template lacks RestartSteps"
echo "ok - refused login recognised, auto-restart is an error, backoff drop-in written"
