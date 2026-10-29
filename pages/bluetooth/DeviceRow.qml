import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One Bluetooth device. `dev` is a primitives-only row from Model.deviceRow;
// the page resolves the live device by address when an action fires.
CursorSurface {
  id: row

  property var dev: null
  property string pending: ""
  property bool adapterOn: true

  signal primary()
  signal remove()

  readonly property bool busy: pending !== "" || (!!dev && (dev.pairing || dev.state === 2 || dev.state === 3))
  readonly property string primaryText: !dev ? ""
    : dev.connected ? "Disconnect"
    : dev.known ? "Connect"
    : "Pair"

  Layout.fillWidth: true
  hasCursor: mouse.containsMouse
  current: !!dev && dev.connected
  implicitHeight: content.implicitHeight + Style.spacing.lg * 2

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  RowLayout {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.spacing.xl

    Text {
      textFormat: Text.PlainText
      text: row.dev ? Model.deviceGlyph(row.dev.icon, row.dev.connected) : ""
      color: row.dev && row.dev.connected ? Commons.Color.accent : Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      horizontalAlignment: Text.AlignHCenter
      Layout.preferredWidth: Style.space(24)
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        text: row.dev ? row.dev.label : ""
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: !!row.dev && row.dev.connected
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Text {
        textFormat: Text.PlainText
        text: Model.statusText(row.dev, row.pending)
        visible: text !== ""
        color: row.busy || (row.dev && row.dev.connected)
          ? Commons.Color.foreground
          : Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
    }

    Button {
      text: row.busy ? "…" : row.primaryText
      bordered: true
      enabled: !row.busy && (row.adapterOn || (row.dev && row.dev.connected))
      opacity: enabled ? 1.0 : 0.5
      onClicked: row.primary()
    }

    PanelActionButton {
      visible: !!row.dev && row.dev.known
      iconText: Model.glyph(Model.G.remove)
      tooltipText: "Remove device"
      hoverColor: Commons.Color.urgent
      enabled: row.pending === ""
      onClicked: row.remove()
    }
  }
}
