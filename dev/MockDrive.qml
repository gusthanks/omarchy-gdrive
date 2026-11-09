import QtQuick
import qs.Commons
import qs.Commons as Commons
import "gdrive/Model.js" as Model

// Stand-in for Panel.qml in the dev harness: the same properties and actions
// DriveView reads, filled with MOCK data. It never runs the CLI, rclone,
// systemctl or journalctl, and never reads your rclone config.
Item {
  id: root

  // panel | shared | error | setup | bar
  property string scenario: "panel"

  // A fake home so the mount point reads "~/GoogleDrive" on any machine.
  readonly property string home: "/home/user"

  readonly property var scenarios: ({
    panel: {
      status: { state: "mounted", mounted: true, responsive: true, ownClient: true, mountpoint: "/home/user/GoogleDrive",
                cacheBytes: 3.4 * 1073741824, cacheMax: "15G", cacheMaxBytes: 15 * 1073741824, pendingUploads: 3, lastError: "" },
      quota: { used: 41.7 * 1073741824, total: 100 * 1073741824, free: 58.3 * 1073741824 }
    },
    shared: {
      status: { state: "mounted", mounted: true, responsive: true, ownClient: false, mountpoint: "/home/user/GoogleDrive",
                cacheBytes: 812 * 1048576, cacheMax: "15G", cacheMaxBytes: 15 * 1073741824, pendingUploads: 0, lastError: "" },
      quota: { used: 9.2 * 1073741824, total: 15 * 1073741824, free: 5.8 * 1073741824 }
    },
    error: {
      status: { state: "error", mounted: false, ownClient: true, mountpoint: "/home/user/GoogleDrive",
                cacheBytes: 1.1 * 1073741824, cacheMax: "15G", cacheMaxBytes: 15 * 1073741824, pendingUploads: 0,
                lastError: "Failed to create file system for \"gdrive:\": couldn't find root directory ID: oauth2: \"invalid_grant\" \"Token has been expired or revoked.\"" },
      quota: null
    },
    setup: {
      status: { state: "unconfigured", ownClient: true, mountpoint: "", cacheBytes: 0, cacheMaxBytes: 0, pendingUploads: 0, lastError: "" },
      quota: null
    }
  })
  readonly property var sample: scenarios[scenario] || scenarios.panel

  property var st: Object.assign(Model.emptyStatus(), sample.status)
  property var quota: sample.quota
  property bool quotaLoading: false
  property bool busy: false

  readonly property string state: st.state
  readonly property bool mountedish: state === "mounted" || state === "starting"
  readonly property bool configured: state !== "unconfigured" && state !== "unknown"

  // A bar-shaped object for WidgetButton.
  property QtObject bar: QtObject {
    property color foreground: Commons.Color.foreground
    property color barForeground: Commons.Color.foreground
    property color urgent: Commons.Color.urgent
    property bool foregroundAnimationEnabled: false
    property string fontFamily: Style.font.family
    property bool vertical: false
    property int barSize: Style.bar.sizeHorizontal
    function showTooltip(item, text) {}
    function hideTooltip(item) {}
    function run(cmd) {}
  }

  readonly property color fgColor: Commons.Color.foreground
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: Commons.Color.urgent
  readonly property color dimColor: Qt.rgba(fgColor.r, fgColor.g, fgColor.b, 0.62)
  readonly property color trackColor: Qt.rgba(fgColor.r, fgColor.g, fgColor.b, 0.12)
  readonly property string fontFamily: Style.font.family

  Commons.Translations {
    id: tr
    directory: Qt.resolvedUrl("gdrive/i18n")
  }

  function t(key) { return tr.t(key) }
  function fmtNum(v, d) { return Commons.I18n.formatNumber(v, d) }
  function fmtBytes(b, d) { return Model.formatBytes(b, d === undefined ? 1 : d, fmtNum) }
  function stateText(s) { return tr.t("state." + (s || "unknown")) }

  // Actions do nothing here (the preview window logs them).
  function toggleMount() { console.log("mock: toggleMount") }
  function openFolder() { console.log("mock: openFolder") }
  function openLogs() { console.log("mock: openLogs") }
  function openDoctor() { console.log("mock: openDoctor") }
  function openSetup() { console.log("mock: openSetup") }
  function refresh() { console.log("mock: refresh") }
  function refreshQuota(force) { console.log("mock: refreshQuota") }
}
