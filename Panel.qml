import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Drive for Google: the bar widget (not affiliated with Google). All state comes from the bundled CLI
// (`bin/omarchy-gdrive status --json`); this file only draws it and forwards
// actions; the popup content is DriveView.qml. Secrets never pass through
// here: the CLI reads rclone's config itself and the JSON it prints carries
// no token, id or secret (the last error line is scrubbed too).
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
  function t(key) { return tr.t(key) }

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
      if (code > 1 && root.st.state === "unknown") root.st = Object.assign(Model.emptyStatus(), { state: "error", lastError: tr.t("error.statusFailed").arg(code) })
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

      DriveView {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        drive: root
      }
    }
  }
}
