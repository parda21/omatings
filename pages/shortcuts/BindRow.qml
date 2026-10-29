import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ShortcutLogic.js" as Logic

// One active binding: keycaps, description, action, and row actions.
RowLayout {
  id: root

  property var bind: ({})
  property color foreground: Commons.Color.foreground

  signal editRequested()
  signal removeRequested()
  signal disableRequested()

  Layout.fillWidth: true
  spacing: Style.spacing.xxl

  KeyCaps {
    Layout.preferredWidth: Style.space(210)
    Layout.alignment: Qt.AlignVCenter
    modmask: root.bind.modmask || 0
    key: root.bind.key || ""
  }

  ColumnLayout {
    Layout.fillWidth: true
    Layout.alignment: Qt.AlignVCenter
    spacing: Style.spacing.xxs

    Text {
      text: root.bind.description || ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      Layout.fillWidth: true
    }
    Text {
      readonly property string actionText: Logic.actionLabel(root.bind.action)
      visible: actionText !== "" && actionText !== root.bind.description
      text: actionText
      textFormat: Text.PlainText
      color: Util.alpha(root.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
      Layout.fillWidth: true
    }
  }

  Button {
    visible: root.bind.custom === true
    iconText: String.fromCodePoint(0xF040)
    tooltipText: "Edit"
    onClicked: root.editRequested()
  }
  Button {
    visible: root.bind.custom === true
    iconText: String.fromCodePoint(0xF1F8)
    tooltipText: "Remove"
    onClicked: root.removeRequested()
  }
  Button {
    visible: root.bind.custom !== true
    iconText: String.fromCodePoint(0xF05E)
    tooltipText: "Disable"
    onClicked: root.disableRequested()
  }
}
