import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Google Drive bar widget for Omarchy. All state comes from the bundled CLI
// (`bin/omarchy-gdrive status --json`); this file only draws it and forwards
// actions. Secrets never pass through here: the CLI reads rclone's config
// itself and the JSON it prints carries no token.
Panel {
  id: root
  moduleName: "gusthx.gdrive"
  ipcTarget: "gusthx.gdrive"
  manageIpc: false

  Commons.Translations {
    id: tr
    directory: Qt.resolvedUrl("i18n")
  }

  // ---- Settings (shell.json entry) ----
  // leftClick: "open" (default, opens the folder) or "panel" (opens this menu).
  readonly property string leftClick: String(setting("leftClick", "open")) === "panel" ? "panel" : "open"
  readonly property int pollSeconds: Math.max(3, parseInt(setting("pollSeconds", 15), 10) || 15)

  // ---- Paths ----
  readonly property string home: Quickshell.env("HOME")
  readonly property string cliPath: String(Qt.resolvedUrl("bin/omarchy-gdrive")).replace(/^file:\/\//, "")

  // ---- Live state ----
  property var st: Model.emptyStatus()
  property var quota: null
  property bool quotaLoading: false
  property double quotaFetchedAt: 0
  property bool busy: false

  readonly property string state: st.state
  readonly property bool mountedish: state === "mounted" || state === "starting"
  readonly property bool configured: state !== "unconfigured" && state !== "unknown"

  // ---- Theme ----
  readonly property color fgColor: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dimColor: Qt.rgba(fgColor.r, fgColor.g, fgColor.b, 0.62)
  readonly property color trackColor: Qt.rgba(fgColor.r, fgColor.g, fgColor.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function fmtNum(v, d) { return Commons.I18n.formatNumber(v, d) }
  function fmtBytes(b, d) { return Model.formatBytes(b, d === undefined ? 1 : d, fmtNum) }
  function stateText(s) { return tr.t("state." + (s || "unknown")) }

  readonly property string barDisplayText: Model.barText(st)
  readonly property string barTooltip: {
    var hint = tr.t(leftClick === "panel" ? "bar.hint.panel" : "bar.hint.open")
    var line = stateText(state)
    if (state === "mounted" && st.pendingUploads > 0) line += " · " + tr.t("bar.pending").arg(fmtNum(st.pendingUploads))
    return Model.neutralizeMarkup(tr.t("bar.tooltip").arg(line).arg(hint), 240)
  }

  // ---- CLI plumbing ----
  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshQuota(force) {
    if (!mountedish || quotaProc.running) return
    var now = Date.now()
    if (!force && quotaFetchedAt > 0 && now - quotaFetchedAt < 15 * 60 * 1000) return
    quotaLoading = true
    quotaProc.running = true
  }

  function toggleMount() {
    if (busy || !configured) return
    busy = true
    actionProc.command = ["bash", root.cliPath, mountedish ? "stop" : "start", "--yes"]
    actionProc.running = true
  }

  function openFolder() {
    Quickshell.execDetached(["bash", root.cliPath, "open"])
  }

  function runInTerminal(subcommand, appId) {
    var cmd = "omarchy-launch-or-focus-tui --app-id=" + appId + " bash " + Model.shellQuote(root.cliPath) + " " + subcommand
    if (root.bar) root.bar.run(cmd)
    else Quickshell.execDetached(["bash", "-lc", cmd])
  }

  function openLogs() { root.close(); runInTerminal("logs", "org.omarchy.gdrive-logs") }
  function openDoctor() {
    root.close()
    var cmd = "omarchy-launch-floating-terminal-with-presentation bash " + Model.shellQuote(root.cliPath) + " doctor"
    if (root.bar) root.bar.run(cmd); else Quickshell.execDetached(["bash", "-lc", cmd])
  }
  function openSetup() {
    root.close()
    var cmd = "omarchy-launch-floating-terminal-with-presentation bash " + Model.shellQuote(root.cliPath) + " setup"
    if (root.bar) root.bar.run(cmd); else Quickshell.execDetached(["bash", "-lc", cmd])
  }

  Process {
    id: statusProc
    command: ["bash", root.cliPath, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        if (parsed) root.st = parsed
      }
    }
    onExited: function(code) {
      // The CLI exits 1 when not mounted; that is still valid JSON. Anything
      // worse (missing bash, broken checkout) leaves the last good state.
      if (code > 1 && root.st.state === "unknown") root.st = Object.assign(Model.emptyStatus(), { state: "error", lastError: "omarchy-gdrive status failed (" + code + ")" })
    }
  }

  Process {
    id: quotaProc
    command: ["bash", root.cliPath, "quota", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var q = Model.parseQuota(text)
        if (q) { root.quota = q; root.quotaFetchedAt = Date.now() }
      }
    }
    onExited: root.quotaLoading = false
  }

  Process {
    id: actionProc
    onExited: {
      root.busy = false
      root.refresh()
      settleTimer.restart()
    }
  }

  // A mount takes a few seconds to appear after `start`; poll again shortly.
  Timer {
    id: settleTimer
    interval: 2500
    onTriggered: root.refresh()
  }

  Timer {
    interval: (root.opened ? 4 : root.pollSeconds) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      refreshQuota(false)
    }
  }
  onMountedishChanged: if (mountedish && opened) refreshQuota(true)

  ShellIpc {
    target: "gusthx.gdrive"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
    function openFolder() { root.openFolder() }
    function toggleMount() { root.toggleMount() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Bar pill ----
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barDisplayText
    active: Model.isUrgent(root.st)
    dimmed: root.state === "stopped" || root.state === "unconfigured"
    tooltipText: root.barTooltip
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.toggleMount()
      else if (b === Qt.RightButton) { if (root.leftClick === "panel") root.openFolder(); else root.toggle() }
      else { if (root.leftClick === "panel") root.toggle(); else root.openFolder() }
    }
  }

  // ---- Popup ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: mainColumn.implicitHeight

      onCloseRequested: root.close()
      onReturnRequested: root.toggleMount()
      onTextKey: function(t) {
        if (t === "o" || t === "O") root.openFolder()
        else if (t === "p" || t === "P") root.toggleMount()
        else if (t === "l" || t === "L") root.openLogs()
        else if (t === "d" || t === "D") root.openDoctor()
        else if (t === "r" || t === "R") { root.refresh(); root.refreshQuota(true) }
        else if (t === "s" || t === "S") { if (!root.configured) root.openSetup() }
      }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---- Hero: icon, title, state, mount switch ----
        Item {
          width: parent.width
          implicitHeight: Math.max(heroRow.implicitHeight, mountSwitch.implicitHeight)

          Row {
            id: heroRow
            anchors.left: parent.left
            anchors.right: mountSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            PlainText {
              text: Model.stateIcon(root.state)
              color: root.state === "error" ? root.urgentColor : (root.mountedish ? root.fgColor : root.dimColor)
              font.pixelSize: Style.font.display
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: Math.max(Style.space(100), parent.width - Style.space(44))
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PlainText {
                text: tr.t("title")
                font.pixelSize: Style.font.title
                font.bold: true
                width: parent.width
              }

              PlainText {
                text: {
                  if (!root.configured) return root.stateText(root.state) + " · " + tr.t("hero.setupHint")
                  var where = root.st.mountpoint ? tr.t("hero.mountedAt").arg(Model.shortenHome(root.st.mountpoint, root.home)) : ""
                  return root.stateText(root.state) + (where ? " " + where : "")
                }
                color: root.state === "error" ? root.urgentColor : root.dimColor
                font.pixelSize: Style.font.caption
                font.bold: true
                width: parent.width
              }
            }
          }

          ToggleSwitch {
            id: mountSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.configured
            checked: root.mountedish
            busy: root.busy || root.state === "starting"
            foreground: root.fgColor
            accent: root.accentColor
            onToggled: root.toggleMount()
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fgColor }

        // ---- Shared client warning ----
        PlainText {
          visible: root.configured && root.st.ownClient === false
          width: parent.width
          wrapMode: Text.WordWrap
          text: "󰀦 " + tr.t("sharedClient")
          color: root.urgentColor
          font.pixelSize: Style.font.caption
        }

        // ---- Local cache ----
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.configured

          Row {
            width: parent.width
            PanelSectionHeader {
              text: tr.t("cache.title")
              foreground: root.fgColor
              fontFamily: root.fontFamily
              width: parent.width - cacheValue.implicitWidth
            }
            PlainText {
              id: cacheValue
              text: root.st.cacheMaxBytes > 0
                ? tr.t("cache.usage").arg(root.fmtBytes(root.st.cacheBytes)).arg(root.fmtBytes(root.st.cacheMaxBytes, 0))
                : tr.t("cache.usageUnlimited").arg(root.fmtBytes(root.st.cacheBytes))
              color: root.dimColor
              font.pixelSize: Style.font.caption
            }
          }

          ProgressTrack {
            width: parent.width
            value: Model.percent(root.st.cacheBytes, root.st.cacheMaxBytes)
            fill: value >= 90 ? root.urgentColor : root.accentColor
          }

          PlainText {
            width: parent.width
            text: root.st.pendingUploads > 0
              ? "󰅧 " + tr.t("cache.pending").arg(root.fmtNum(root.st.pendingUploads))
              : tr.t("cache.clean")
            color: root.st.pendingUploads > 0 ? root.fgColor : root.dimColor
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Drive quota ----
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.configured

          Row {
            width: parent.width
            PanelSectionHeader {
              text: tr.t("quota.title")
              foreground: root.fgColor
              fontFamily: root.fontFamily
              width: parent.width - quotaValue.implicitWidth
            }
            PlainText {
              id: quotaValue
              text: {
                if (root.quota) return tr.t("quota.usage").arg(root.fmtBytes(root.quota.used)).arg(root.fmtBytes(root.quota.total, 0))
                if (!root.mountedish) return tr.t("quota.unavailable")
                return root.quotaLoading ? tr.t("quota.loading") : "—"
              }
              color: root.dimColor
              font.pixelSize: Style.font.caption
            }
          }

          ProgressTrack {
            width: parent.width
            value: root.quota ? Model.percent(root.quota.used, root.quota.total) : 0
            fill: value >= 90 ? root.urgentColor : root.accentColor
          }
        }

        // ---- Last error ----
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.state === "error" && root.st.lastError !== ""

          PanelSectionHeader {
            text: tr.t("error.title")
            foreground: root.urgentColor
            fontFamily: root.fontFamily
            width: parent.width
          }
          PlainText {
            width: parent.width
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 4
            elide: Text.ElideRight
            text: Model.neutralizeMarkup(root.st.lastError, 320)
            color: root.dimColor
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fgColor }

        // ---- Actions ----
        Flow {
          width: parent.width
          spacing: Style.space(6)

          ActionBtn {
            visible: !root.configured
            iconText: "󰒓"   // md-cog
            text: tr.t("action.setup")
            tooltipText: tr.t("action.tooltip.setup")
            onClicked: root.openSetup()
          }
          ActionBtn {
            iconText: "󰝰"   // md-folder-open
            text: tr.t("action.open")
            tooltipText: tr.t("action.tooltip.open")
            onClicked: root.openFolder()
          }
          ActionBtn {
            visible: root.configured
            iconText: root.mountedish ? "󰏤" : "󰐊"  // md-pause / md-play
            text: root.mountedish ? tr.t("action.pause") : tr.t("action.resume")
            tooltipText: root.mountedish ? tr.t("action.tooltip.pause") : tr.t("action.tooltip.resume")
            enabled: !root.busy
            onClicked: root.toggleMount()
          }
          ActionBtn {
            iconText: "󰆍"   // md-console
            text: tr.t("action.logs")
            tooltipText: tr.t("action.tooltip.logs")
            onClicked: root.openLogs()
          }
          ActionBtn {
            iconText: "󰓜"   // md-stethoscope
            text: tr.t("action.doctor")
            tooltipText: tr.t("action.tooltip.doctor")
            onClicked: root.openDoctor()
          }
          ActionBtn {
            iconText: "󰑐"   // md-refresh
            tooltipText: tr.t("action.tooltip.refresh")
            onClicked: { root.refresh(); root.refreshQuota(true) }
          }
        }

        PlainText {
          width: parent.width
          text: tr.t("hint.keys")
          color: root.dimColor
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // ---- Small reusable pieces ----
  component PlainText: Text {
    color: root.fgColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    elide: Text.ElideRight
  }

  component ActionBtn: Button {
    fontSize: Style.font.caption
    iconSize: Style.font.bodySmall
    foreground: root.fgColor
    accent: root.accentColor
    fontFamily: root.fontFamily
    horizontalPadding: Style.space(8)
    verticalPadding: Style.space(5)
    bordered: true
  }

  component ProgressTrack: Item {
    property real value: 0      // 0..100
    property color fill: root.accentColor
    implicitHeight: Style.space(6)
    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: root.trackColor
    }
    Rectangle {
      width: Math.max(0, Math.min(1, parent.value / 100)) * parent.width
      height: parent.height
      radius: height / 2
      color: parent.fill
      Behavior on width { NumberAnimation { duration: 180 } }
    }
  }
}
