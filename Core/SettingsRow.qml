import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// One setting: label + optional description on the left, the control on the
// right. The control is the row's child:
//
//   SettingsRow {
//     label: "Refresh rate"
//     description: "Higher is smoother."
//     Dropdown { showLabel: false; options: [...]; value: ...; onChanged: ... }
//   }
//
// Set `stacked: true` to put a wide control (slider, text field) under the
// label instead of beside it.
GridLayout {
  id: root

  property string label: ""
  property string description: ""
  property bool stacked: false
  property color foreground: Commons.Color.foreground

  default property alias control: controlSlot.data

  Layout.fillWidth: true
  columns: stacked ? 1 : 2
  columnSpacing: Style.spacing.xxl
  rowSpacing: Style.spacing.sm

  ColumnLayout {
    Layout.fillWidth: true
    Layout.alignment: Qt.AlignVCenter
    spacing: Style.spacing.xxs

    Text {
      text: root.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      Layout.fillWidth: true
      elide: Text.ElideRight
    }

    Text {
      visible: root.description !== ""
      text: root.description
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.alpha(root.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      Layout.fillWidth: true
    }
  }

  Item {
    id: controlSlot
    Layout.alignment: root.stacked ? Qt.AlignLeft : (Qt.AlignRight | Qt.AlignVCenter)
    Layout.fillWidth: root.stacked
    // Stacked controls size to the row (bind `width: parent.width`).
    implicitWidth: root.stacked ? 0 : childrenRect.width
    implicitHeight: childrenRect.height
  }
}
