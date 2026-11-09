import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "gdrive" as G
import "gdrive/Model.js" as Model

// Isolated dev harness. Runs in its own Quickshell instance (see dev/run.sh),
// never inside the live Omarchy shell, so testing and screenshots do not
// reload or restart the user's bar. All data is MOCK (dev/MockDrive.qml): no
// CLI, no rclone, no account, no real file names.
//
// MODE (env):
//   preview  floating window with the popup content, to play with
//   panel    the popup, mounted, own client, uploads pending  -> $OUT (png)
//   shared   the popup with the shared client_id warning     -> $OUT (png)
//   error    the popup with a revoked token                   -> $OUT (png)
//   setup    the popup before setup                           -> $OUT (png)
//   bar      the bar pill next to a clock                     -> $OUT (png)
ShellRoot {
  id: shell

  readonly property string mode: Quickshell.env("MODE") || "preview"
  readonly property string out: Quickshell.env("OUT") || ""
  readonly property bool capturing: mode !== "preview"
  readonly property bool headless: Quickshell.env("HEADLESS") === "1"
  property Item stage: null

  function save(item, path, scale, done) {
    item.grabToImage(function(r) {
      r.saveToFile(path)
      if (done) done()
    }, Qt.size(item.width * scale, item.height * scale))
  }

  Component {
    id: stageComponent
    Rectangle {
      id: stageRect
      color: Commons.Color.background
      width: loader.item ? loader.item.width : 10
      height: loader.item ? loader.item.height : 10
      Component.onCompleted: shell.stage = stageRect

      Loader {
        id: loader
        sourceComponent: shell.mode === "bar" ? barScene : panelScene
      }
    }
  }

  // HEADLESS=1 (the dev/run.sh default): Qt's offscreen platform, nothing
  // reaches the desktop. Otherwise a background-layer surface below every
  // window. LayerStage is its own file: offscreen has no PanelWindow backend.
  LazyLoader {
    active: shell.capturing && !shell.headless
    source: "LayerStage.qml"
    onItemChanged: if (item) item.content = stageComponent
  }

  FloatingWindow {
    visible: !shell.capturing || shell.headless
    implicitWidth: offLoader.item ? offLoader.item.width : 10
    implicitHeight: offLoader.item ? offLoader.item.height : 10
    color: "transparent"
    Loader { id: offLoader; active: !shell.capturing || shell.headless; sourceComponent: stageComponent }
  }

  Timer {
    running: shell.capturing
    interval: 1200
    onTriggered: shell.save(shell.stage, shell.out, 2, function() { Qt.quit() })
  }

  // ------------------------------------------------------------ scenes
  // The popup: DriveView inside a frame shaped like the shell's popups, at
  // the width Panel.qml asks for.
  Component {
    id: panelScene
    Rectangle {
      id: frame
      readonly property int pad: Style.spacing.popupPadding
      width: Style.space(340) + pad * 2
      height: view.implicitHeight + pad * 2
      color: Commons.Color.background
      border.width: Math.max(1, Style.space(2))
      border.color: Commons.Color.popups.border
      radius: Style.cornerRadius

      MockDrive {
        id: mock
        scenario: shell.mode === "preview" ? "panel" : shell.mode
      }

      G.DriveView {
        id: view
        x: frame.pad
        y: frame.pad
        width: Style.space(340)
        drive: mock
      }
    }
  }

  // The bar pill (mounted, 3 uploads pending) next to a clock.
  Component {
    id: barScene
    Rectangle {
      width: barRow.implicitWidth + Style.space(24)
      height: Style.bar.sizeHorizontal
      color: Commons.Color.background

      MockDrive { id: barMock; scenario: "panel" }

      Row {
        id: barRow
        anchors.centerIn: parent
        spacing: Style.space(12)

        WidgetButton {
          anchors.verticalCenter: parent.verticalCenter
          bar: barMock.bar
          text: Model.barText(barMock.st)
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Monday 15 Jun 2:00 PM"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.bar.iconFont
        }
      }
    }
  }
}
