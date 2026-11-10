import QtQuick
import Quickshell
import Quickshell.Io
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
//   gif      the pill and the popup together: three uploads finish, the
//            mount is paused and resumed. One png per frame ->
//            $OUT/0000.png ... + $OUT/fps (dev/run.sh makes the GIF)
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
        sourceComponent: shell.mode === "bar" ? barScene : (shell.mode === "gif" ? gifScene : panelScene)
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
    onTriggered: shell.mode === "gif"
      ? shell.gifNext()
      : shell.save(shell.stage, shell.out, 2, function() { Qt.quit() })
  }

  // ------------------------------------------------------------ gif mode
  // A fixed script, frame by frame, so the GIF is the same on every run and
  // on any machine speed: the next frame is set up only after the previous
  // one is saved. All values are MOCK.
  readonly property int gifFps: 10
  // [first frame, overrides]: each step lasts until the next one starts.
  readonly property var gifSteps: [
    [0,   { state: "mounted",  pendingUploads: 3, cacheBytes: 3.40 * 1073741824 }],
    [16,  { state: "mounted",  pendingUploads: 2, cacheBytes: 3.42 * 1073741824 }],
    [26,  { state: "mounted",  pendingUploads: 1, cacheBytes: 3.45 * 1073741824 }],
    [36,  { state: "mounted",  pendingUploads: 0, cacheBytes: 3.47 * 1073741824 }],
    [58,  { state: "mounted",  pendingUploads: 0, cacheBytes: 3.47 * 1073741824, busy: true }],
    [63,  { state: "stopped",  pendingUploads: 0, cacheBytes: 3.47 * 1073741824, mounted: false, quota: null }],
    [90,  { state: "starting", pendingUploads: 0, cacheBytes: 3.47 * 1073741824, mounted: false, quota: null, busy: true }],
    [100, { state: "mounted",  pendingUploads: 0, cacheBytes: 3.47 * 1073741824 }]
  ]
  readonly property int gifFrames: 128
  property int gifFrame: 0
  property var gifDrive: null
  property real gifHeight: 0

  function gifApply(f) {
    var step = gifSteps[0][1]
    for (var i = 0; i < gifSteps.length; i++) if (gifSteps[i][0] <= f) step = gifSteps[i][1]
    var d = gifDrive
    var st = Object.assign({}, d.scenarios.panel.status)
    for (var k in step) if (k !== "busy" && k !== "quota") st[k] = step[k]
    d.st = st
    d.busy = !!step.busy
    d.quota = step.hasOwnProperty("quota") ? step.quota : d.scenarios.panel.quota
  }
  function pad(n) { var s = String(n); while (s.length < 4) s = "0" + s; return s }
  function gifNext() {
    if (gifFrame >= gifFrames) {
      gifFpsFile.setText(String(gifFps) + "\n")
      Qt.callLater(Qt.quit)
      return
    }
    // Freeze the size at the first frame's so every png has the same size.
    if (gifHeight === 0) gifHeight = stage.height
    gifApply(gifFrame)
    var f = gifFrame
    gifFrame++
    // let the bindings settle before the grab
    Qt.callLater(function() { shell.save(shell.stage, shell.out + "/" + pad(f) + ".png", 1, function() { gifGap.restart() }) })
  }
  Timer { id: gifGap; interval: 40; onTriggered: shell.gifNext() }
  FileView { id: gifFpsFile; path: shell.mode === "gif" ? shell.out + "/fps" : ""; printErrors: false }

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

  // The GIF: a strip of bar with the pill, and the popup under it, both fed
  // by one MockDrive that gifApply() changes frame by frame. The size is
  // fixed at the first frame's, so every frame has the same dimensions.
  Component {
    id: gifScene
    Rectangle {
      id: gifRoot
      readonly property int pad: Style.spacing.popupPadding
      width: popup.width + Style.space(32)
      height: shell.gifHeight > 0 ? shell.gifHeight : gifCol.implicitHeight + Style.space(32)
      clip: true
      color: Commons.Color.background
      Component.onCompleted: { shell.gifDrive = gifMock; shell.gifApply(0) }

      MockDrive { id: gifMock; scenario: "panel" }

      Column {
        id: gifCol
        x: Style.space(16)
        y: Style.space(16)
        spacing: Style.space(10)

        Rectangle {
          width: popup.width
          height: Style.bar.sizeHorizontal
          color: Commons.Color.background
          border.width: Math.max(1, Style.space(1))
          border.color: Commons.Color.popups.border
          radius: Style.cornerRadius

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            WidgetButton {
              anchors.verticalCenter: parent.verticalCenter
              bar: gifMock.bar
              text: Model.barText(gifMock.st)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "2:00 PM"
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.bar.iconFont
            }
          }
        }

        Rectangle {
          id: popup
          width: Style.space(340) + gifRoot.pad * 2
          height: gifView.implicitHeight + gifRoot.pad * 2
          color: Commons.Color.background
          border.width: Math.max(1, Style.space(2))
          border.color: Commons.Color.popups.border
          radius: Style.cornerRadius

          G.DriveView {
            id: gifView
            x: gifRoot.pad
            y: gifRoot.pad
            width: Style.space(340)
            drive: gifMock
          }
        }
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
