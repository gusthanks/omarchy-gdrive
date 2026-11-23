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

# Login guard: the template carries it, rendered with real paths (no placeholder left).
unit=$(REPO=$repo run 'render_unit "$REPO/templates/rclone-gdrive.service" 5G')
grep -q '@@' <<<"$unit" && fail "a placeholder was left in the rendered unit"
grep -q '^ExecStopPost=-.* auth-guard %N$' <<<"$unit" || fail "rendered unit lacks the auth-guard ExecStopPost"
grep -qF "ExecCondition=/bin/sh -c 'test ! -e \"\$\$1\" || test \"\$\$2\" -nt \"\$\$1\"' _ " <<<"$unit" || fail "rendered unit lacks the ExecCondition"
grep -q '^ExecStartPost=-/usr/bin/rm -f .*/rclone-gdrive.login-refused$' <<<"$unit" || fail "rendered unit lacks the flag cleanup"

# doctor --fix: the guard goes into its own drop-in.
run 'install_guard_dropin' || fail "install_guard_dropin failed"
gdrop="$tmp/config/systemd/user/rclone-gdrive.service.d/60-omarchy-login-guard.conf"
grep -q 'auth-guard %N' "$gdrop" || fail "guard drop-in lacks auth-guard"

# login_refused: flag present → refused; rclone.conf newer (a manual reconnect) → not.
flag="$tmp/config/omarchy-gdrive/rclone-gdrive.login-refused"
run 'login_refused' && fail "refused without a flag"
mkdir -p "$(dirname "$flag")"; echo x > "$RCLONE_CONFIG"; touch -d '-1 min' "$RCLONE_CONFIG"; echo x > "$flag"
run 'login_refused' || fail "flag present but not refused"
touch "$RCLONE_CONFIG"; touch -d '-1 min' "$flag"
run 'login_refused' && fail "a newer rclone.conf did not lift the flag"
rm -f "$flag"

# auth-guard: a refused login writes the flag and stops the unit; anything else is left alone.
guard() {  # guard <journal line> <service result>
  : > "$tmp/systemctl.log"
  JLINE=$1 SERVICE_RESULT=$2 INVOCATION_ID=abc run 'journalctl() { printf "%s\n" "$JLINE"; }; sleep() { :; }; cmd_auth_guard rclone-gdrive' >/dev/null
}
guard "$line" exit-code
[[ -s $flag ]] || fail "auth-guard did not write the flag"
grep -qx -- '--no-block stop rclone-gdrive.service' "$tmp/systemctl.log" || fail "auth-guard did not stop the unit"
rm -f "$flag"
guard "dial tcp: lookup www.googleapis.com: no such host" exit-code
[[ ! -e $flag ]] || fail "a network error wrote the flag"
[[ ! -s $tmp/systemctl.log ]] || fail "a network error stopped the unit"
guard "$line" success
[[ ! -e $flag ]] || fail "a clean stop wrote the flag"
echo "ok - login guard: rendered, drop-in, flag logic, auth-guard"
