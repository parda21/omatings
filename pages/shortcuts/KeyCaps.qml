import QtQuick
import qs.Commons
import qs.Commons as Commons
import "ShortcutLogic.js" as Logic

// Key combination drawn as keycaps: [Super] [Shift] [F]
Flow {
  id: root

  property int modmask: 0
  property string key: ""
  property color foreground: Commons.Color.foreground
  property bool dim: false

  spacing: Style.spacing.xs

  Repeater {
    model: Logic.comboParts(root.modmask, root.key)

    Rectangle {
      required property var modelData
      width: capText.implicitWidth + Style.spacing.lg * 2
      height: capText.implicitHeight + Style.spacing.xs * 2
      radius: Style.cornerRadius > 0 ? Math.max(3, Style.cornerRadius / 2) : 0
      color: Util.alpha(root.foreground, root.dim ? 0.04 : 0.08)
      border.width: Math.max(1, Style.normalBorderWidth)
      border.color: Util.alpha(root.foreground, root.dim ? 0.1 : 0.2)

      Text {
        id: capText
        anchors.centerIn: parent
        text: parent.modelData
        textFormat: Text.PlainText
        color: Util.alpha(root.foreground, root.dim ? 0.5 : 0.9)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }
}
