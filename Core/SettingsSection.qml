import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A titled group of settings rows, drawn as a bordered card the way Omarchy
// panels draw their surfaces. Children are stacked vertically:
//
//   SettingsSection {
//     title: "Layout"
//     description: "Optional helper text under the title."
//     SettingsRow { label: "Scale"; Dropdown { ... } }
//   }
ColumnLayout {
  id: root

  property string title: ""
  property string description: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  // Remove the card border/padding (e.g. for a full-bleed canvas).
  property bool flat: false

  default property alias content: body.data

  Layout.fillWidth: true
  spacing: Style.spacing.md

  PanelSectionHeader {
    visible: root.title !== ""
    text: root.title.toUpperCase()
    foreground: root.foreground
    Layout.fillWidth: true
  }

  Text {
    visible: root.description !== ""
    text: root.description
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Util.alpha(root.foreground, 0.7)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    Layout.fillWidth: true
  }

  BorderSurface {
    id: card
    Layout.fillWidth: true
    implicitHeight: body.implicitHeight + (root.flat ? 0 : Style.spacing.xxl * 2)
    color: root.flat ? "transparent" : Style.normalFill
    radius: Style.cornerRadius
    borderSpec: root.flat ? Border.none() : Border.controlSpec("normal", root.foreground, root.accent)

    ColumnLayout {
      id: body
      anchors.fill: parent
      anchors.margins: root.flat ? 0 : Style.spacing.xxl
      spacing: Style.spacing.lg
    }
  }
}
