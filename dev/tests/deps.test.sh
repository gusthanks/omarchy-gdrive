#!/usr/bin/env bash
# ensure_deps: the only root command (sudo pacman) runs only after a "yes",
# either typed at the prompt or given as --yes. Without a terminal and without
# --yes nothing is installed. sudo is a stub that records its argv; nothing is
# installed and pacman is never really called.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" NO_COLOR=1

# run <assume_yes> <interactive 0|1> <missing tools...> -- feeds stdin to the prompt.
# Prints the recorded sudo argv (or nothing) to $tmp/sudo; returns ensure_deps' status.
run() {
  local yes=$1 tty=$2; shift 2
  rm -f "$tmp/sudo"
  bash -c '
    source "$1/lib/i18n.sh"; source "$1/lib/gdrive.sh"; source "$1/lib/common.sh"
    out=$2 ASSUME_YES=$3 tty=$4; shift 4
    absent=" $* "
    # pacman is there, gum is not (the plain read prompt answers from stdin).
    have() { [[ $1 == pacman ]] && return 0; [[ $1 == gum ]] && return 1; [[ $absent != *" $1 "* ]]; }
    interactive() { (( tty )); }
    sudo() { printf "%s\n" "$*" > "$out"; }
    ensure_deps
  ' _ "$repo" "$tmp/sudo" "$yes" "$tty" "$@" >"$tmp/out" 2>&1
}

fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2; exit 1; }
expected="pacman -S --needed --noconfirm rclone fuse3"

# Nothing missing: no prompt, no sudo.
run 0 0 </dev/null || fail "ensure_deps failed with nothing missing"
[[ ! -e $tmp/sudo ]] || fail "sudo ran with nothing missing"

# No terminal, no --yes: refuses, never runs sudo.
if run 0 0 rclone fusermount3 </dev/null; then fail "installed without a terminal and without --yes"; fi
[[ ! -e $tmp/sudo ]] || fail "sudo ran without a terminal and without --yes"
grep -q 'deps.needTerminal' "$tmp/out" || fail "no hint to use a terminal or --yes"

# A terminal, the user answers no: aborts, never runs sudo.
if printf 'n\n' | run 0 1 rclone fusermount3; then fail "installed after the user said no"; fi
[[ ! -e $tmp/sudo ]] || fail "sudo ran after the user said no"

# A terminal, the user answers yes: runs exactly the command it showed.
printf 'y\n' | run 0 1 rclone fusermount3 || fail "did not install after the user said yes"
[[ $(cat "$tmp/sudo") == "$expected" ]] || fail "unexpected sudo argv: $(cat "$tmp/sudo")"
grep -qF "sudo $expected" "$tmp/out" || fail "the command was not shown before running it"

# --yes: no question asked, even without a terminal.
run 1 0 rclone fusermount3 </dev/null || fail "--yes did not install"
[[ $(cat "$tmp/sudo") == "$expected" ]] || fail "unexpected sudo argv with --yes: $(cat "$tmp/sudo")"

echo "ok - sudo pacman runs only after a yes (prompt or --yes), never without a terminal"
