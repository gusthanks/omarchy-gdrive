import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The popup content of the Google Drive widget. It reads everything from its
// `drive` object: Panel.qml in the bar, dev/MockDrive.qml in the dev harness
// (mock data, no CLI, no rclone). A property or action used here must exist
// on both.
Column {
  id: view
  required property var drive

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
        text: Model.stateIcon(view.drive.state)
        color: view.drive.state === "error" ? view.drive.urgentColor : (view.drive.mountedish ? view.drive.fgColor : view.drive.dimColor)
        font.pixelSize: Style.font.display
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: Math.max(Style.space(100), parent.width - Style.space(44))
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PlainText {
          text: view.drive.t("title")
          font.pixelSize: Style.font.title
          font.bold: true
          width: parent.width
        }

        PlainText {
          text: {
            if (!view.drive.configured) return view.drive.stateText(view.drive.state) + " · " + view.drive.t("hero.setupHint")
            var where = view.drive.st.mountpoint ? view.drive.t("hero.mountedAt").arg(Model.shortenHome(view.drive.st.mountpoint, view.drive.home)) : ""
            return view.drive.stateText(view.drive.state) + (where ? " " + where : "")
          }
          color: view.drive.state === "error" ? view.drive.urgentColor : view.drive.dimColor
          font.pixelSize: Style.font.caption
          font.bold: true
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }
    }

    ToggleSwitch {
      id: mountSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: view.drive.configured
      checked: view.drive.mountedish
      busy: view.drive.busy || view.drive.state === "starting"
      foreground: view.drive.fgColor
      accent: view.drive.accentColor
      onToggled: view.drive.toggleMount()
    }
  }

  PanelSeparator { visible: view.drive.configured; width: parent.width; foreground: view.drive.fgColor }

  // ---- Shared client warning ----
  PlainText {
    visible: view.drive.configured && view.drive.st.ownClient === false
    width: parent.width
    wrapMode: Text.WordWrap
    text: "󰀦 " + view.drive.t("sharedClient")
    color: view.drive.urgentColor
    font.pixelSize: Style.font.caption
  }

  // ---- Local cache ----
  Column {
    width: parent.width
    spacing: Style.space(6)
    visible: view.drive.configured

    Row {
      width: parent.width
      PanelSectionHeader {
        text: view.drive.t("cache.title")
        foreground: view.drive.fgColor
        fontFamily: view.drive.fontFamily
        width: parent.width - cacheValue.implicitWidth
      }
      PlainText {
        id: cacheValue
        text: view.drive.st.cacheMaxBytes > 0
          ? view.drive.t("cache.usage").arg(view.drive.fmtBytes(view.drive.st.cacheBytes)).arg(view.drive.fmtBytes(view.drive.st.cacheMaxBytes, 0))
          : view.drive.t("cache.usageUnlimited").arg(view.drive.fmtBytes(view.drive.st.cacheBytes))
        color: view.drive.dimColor
        font.pixelSize: Style.font.caption
      }
    }

    ProgressTrack {
      width: parent.width
      value: Model.percent(view.drive.st.cacheBytes, view.drive.st.cacheMaxBytes)
      fill: value >= 90 ? view.drive.urgentColor : view.drive.accentColor
    }

    PlainText {
      width: parent.width
      text: view.drive.st.pendingUploads > 0
        ? "󰅧 " + view.drive.t("cache.pending").arg(view.drive.fmtNum(view.drive.st.pendingUploads))
        : view.drive.t("cache.clean")
      color: view.drive.st.pendingUploads > 0 ? view.drive.fgColor : view.drive.dimColor
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Drive quota ----
  Column {
    width: parent.width
    spacing: Style.space(6)
    visible: view.drive.configured

    Row {
      width: parent.width
      PanelSectionHeader {
        text: view.drive.t("quota.title")
        foreground: view.drive.fgColor
        fontFamily: view.drive.fontFamily
        width: parent.width - quotaValue.implicitWidth
      }
      PlainText {
        id: quotaValue
        text: {
          if (view.drive.quota) return view.drive.t("quota.usage").arg(view.drive.fmtBytes(view.drive.quota.used)).arg(view.drive.fmtBytes(view.drive.quota.total, 0))
          if (!view.drive.mountedish) return view.drive.t("quota.unavailable")
          return view.drive.quotaLoading ? view.drive.t("quota.loading") : "—"
        }
        color: view.drive.dimColor
        font.pixelSize: Style.font.caption
      }
    }

    ProgressTrack {
      width: parent.width
      value: view.drive.quota ? Model.percent(view.drive.quota.used, view.drive.quota.total) : 0
      fill: value >= 90 ? view.drive.urgentColor : view.drive.accentColor
    }
  }

  // ---- Last error ----
  Column {
    width: parent.width
    spacing: Style.space(4)
    visible: view.drive.state === "error" && view.drive.st.lastError !== ""

    PanelSectionHeader {
      text: view.drive.t("error.title")
      foreground: view.drive.urgentColor
      fontFamily: view.drive.fontFamily
      width: parent.width
    }
    PlainText {
      width: parent.width
      wrapMode: Text.WrapAnywhere
      maximumLineCount: 4
      elide: Text.ElideRight
      text: Model.neutralizeMarkup(view.drive.st.lastError, 320)
      color: view.drive.dimColor
      font.pixelSize: Style.font.caption
    }
  }

  PanelSeparator { width: parent.width; foreground: view.drive.fgColor }

  // ---- Actions ----
  Flow {
    width: parent.width
    spacing: Style.space(6)

    ActionBtn {
      visible: !view.drive.configured
      iconText: "󰒓"   // md-cog
      text: view.drive.t("action.setup")
      tooltipText: view.drive.t("action.tooltip.setup")
      onClicked: view.drive.openSetup()
    }
    ActionBtn {
      iconText: "󰝰"   // md-folder-open
      text: view.drive.t("action.open")
      tooltipText: view.drive.t("action.tooltip.open")
      onClicked: view.drive.openFolder()
    }
    ActionBtn {
      visible: view.drive.configured
      iconText: view.drive.mountedish ? "󰏤" : "󰐊"  // md-pause / md-play
      text: view.drive.mountedish ? view.drive.t("action.pause") : view.drive.t("action.resume")
      tooltipText: view.drive.mountedish ? view.drive.t("action.tooltip.pause") : view.drive.t("action.tooltip.resume")
      enabled: !view.drive.busy
      onClicked: view.drive.toggleMount()
    }
    ActionBtn {
      iconText: "󰆍"   // md-console
      text: view.drive.t("action.logs")
      tooltipText: view.drive.t("action.tooltip.logs")
      onClicked: view.drive.openLogs()
    }
    ActionBtn {
      iconText: "󰓜"   // md-stethoscope
      text: view.drive.t("action.doctor")
      tooltipText: view.drive.t("action.tooltip.doctor")
      onClicked: view.drive.openDoctor()
    }
    ActionBtn {
      iconText: "󰑐"   // md-refresh
      tooltipText: view.drive.t("action.tooltip.refresh")
      onClicked: { view.drive.refresh(); view.drive.refreshQuota(true) }
    }
  }

  PlainText {
    width: parent.width
    text: view.drive.t("hint.keys")
    color: view.drive.dimColor
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
  }

  // ---- Small reusable pieces ----
  component PlainText: Text {
    color: view.drive.fgColor
    font.family: view.drive.fontFamily
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    elide: Text.ElideRight
  }

  component ActionBtn: Button {
    fontSize: Style.font.caption
    iconSize: Style.font.bodySmall
    foreground: view.drive.fgColor
    accent: view.drive.accentColor
    fontFamily: view.drive.fontFamily
    horizontalPadding: Style.space(8)
    verticalPadding: Style.space(5)
    bordered: true
  }

  component ProgressTrack: Item {
    property real value: 0      // 0..100
    property color fill: view.drive.accentColor
    implicitHeight: Style.space(6)
    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: view.drive.trackColor
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
