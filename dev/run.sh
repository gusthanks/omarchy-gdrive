#!/usr/bin/env bash
# Run the Google Drive dev harness in its OWN Quickshell instance.
# It never touches the live Omarchy shell or the installed plugin, so the bar
# is not reloaded or restarted while you test or take screenshots. All data
# is MOCK (dev/MockDrive.qml): no CLI, no rclone, no account, no real files.
#
#   dev/run.sh preview      the popup content in a window, to play with
#   dev/run.sh panel        docs/panel.png         (mounted, uploads pending)
#   dev/run.sh shared       docs/panel-shared.png  (shared client_id warning)
#   dev/run.sh error        docs/panel-error.png   (revoked token)
#   dev/run.sh setup        docs/panel-setup.png   (before setup)
#   dev/run.sh bar          docs/bar.png           (the pill)
#   dev/run.sh docs         all of the captures above, plus panel in pt-BR
#   dev/run.sh check        compile every plugin type, Panel.qml included
#                           (declared, never instantiated); run before deploy
#   dev/run.sh test         unit tests: Model.js, i18n catalogs, the
#                           client-secret writer on a throwaway rclone.conf,
#                           and the ask-before-sudo-pacman check (stubbed sudo)
#
# LANGUAGE picks the shell language for the run (default en), e.g.
# LANGUAGE=pt-BR dev/run.sh panel. Captures render offscreen (HEADLESS=1, the
# default), so nothing shows on the desktop; HEADLESS=0 uses a background
# layer surface instead. DEV_SCALE stands in for the monitor scale (1.6).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
omarchy_shell="$OMARCHY_PATH/shell"
export HEADLESS="${HEADLESS:-1}"

# A throwaway Quickshell config: Omarchy's Commons/Ui libraries, this repo as
# "gdrive", and the harness as shell.qml. The language file is pinned here
# instead of reading ~/.config/omarchy/language.
cfg="${XDG_RUNTIME_DIR:-/tmp}/gusthx-gdrive-dev"
rm -rf "$cfg"
mkdir -p "$cfg"
ln -s "$omarchy_shell/Commons" "$cfg/Commons"
ln -s "$omarchy_shell/Ui" "$cfg/Ui"
ln -s "$repo" "$cfg/gdrive"
cp "$repo/dev/Harness.qml" "$cfg/shell.qml"
cp "$repo/dev/LayerStage.qml" "$repo/dev/MockDrive.qml" "$cfg/"
lang="${LANGUAGE:-en}"; lang="${lang%%:*}"
printf '%s\n' "$lang" > "$cfg/language"
export OMARCHY_LANGUAGE_FILE="$cfg/language"

suffix=""; [ "$lang" != en ] && suffix="-$lang"

render() { # mode out
  local log="$cfg/$1.log"
  local platform=()
  [ "$HEADLESS" = 1 ] && platform=(env QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR="${DEV_SCALE:-1.6}")
  rm -f "$2"
  MODE="$1" OUT="$2" timeout 30 "${platform[@]}" quickshell -n -p "$cfg/shell.qml" >"$log" 2>&1 || true
  local noise='qmlscanner|portal|polkit|QT_QPA_PLATFORM|actually running wayland|window masks|--- WARNING ---|No PanelWindow backend|toplevel-mapping'
  if grep -aE 'WARN|ERROR' "$log" | grep -vE "$noise" | grep -q .; then
    grep -aE 'WARN|ERROR' "$log" | grep -vE "$noise" >&2
  fi
  [ -f "$2" ] && echo "${2#"$repo"/}" || { echo "no image written for $1 (log: $log)" >&2; return 1; }
}

mkdir -p "$repo/docs"
case "${1:-preview}" in
  preview) MODE=preview quickshell -n -p "$cfg/shell.qml" ;;
  panel)   render panel  "$repo/docs/panel$suffix.png" ;;
  shared)  render shared "$repo/docs/panel-shared$suffix.png" ;;
  error)   render error  "$repo/docs/panel-error$suffix.png" ;;
  setup)   render setup  "$repo/docs/panel-setup$suffix.png" ;;
  bar)     render bar    "$repo/docs/bar$suffix.png" ;;
  docs)    for m in panel shared error setup bar; do "$0" "$m"; done
           LANGUAGE=pt-BR "$0" panel ;;
  test)    node --test "$repo/dev/tests/"
           for t in "$repo"/dev/tests/*.test.sh; do "$t"; done
           bash -n "$repo/bin/omarchy-gdrive" "$repo"/lib/*.sh "$repo"/dev/*.sh "$repo"/dev/tests/*.sh ;;
  check)
    # Compile-only: types are declared inside Components that never get created,
    # so no window opens. Needs the Wayland backend (Panel uses PanelWindow).
    files=$(cd "$repo" && ls *.qml | sed 's/\.qml$//')
    { echo 'import QtQuick'; echo 'import Quickshell'; echo 'import "gdrive" as G'; echo 'ShellRoot {'
      i=0; for f in $files; do echo "  Component { id: c$i; G.$f {} }"; i=$((i+1)); done
      echo '  Component.onCompleted: {'
      i=0; for f in $files; do echo "    console.warn(\"CHECK $f\", c$i.status === Component.Ready ? \"OK\" : c$i.errorString())"; i=$((i+1)); done
      echo '    Qt.quit()'; echo '  }'; echo '}'; } > "$cfg/shell.qml"
    timeout 20 quickshell -n -p "$cfg/shell.qml" >"$cfg/check.log" 2>&1 || true
    if grep -q 'Failed to load configuration' "$cfg/check.log"; then grep -aE 'ERROR' "$cfg/check.log" >&2; exit 1; fi
    grep -a 'CHECK ' "$cfg/check.log" | sed 's/^.*CHECK /CHECK /'
    grep -a 'CHECK ' "$cfg/check.log" | grep -q . || { echo "check produced no output (log: $cfg/check.log)" >&2; exit 1; }
    ! grep -a 'CHECK ' "$cfg/check.log" | grep -vq ' OK$' ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
