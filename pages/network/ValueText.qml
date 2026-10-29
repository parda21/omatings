import QtQuick
import qs.Commons
import qs.Commons as Commons

// Read-only value for a SettingsRow (IP address, MAC, ...). Click copies it.
Text {
  id: root

  property bool copyable: text !== "" && text !== "—"

  signal copyRequested(string value)

  textFormat: Text.PlainText
  horizontalAlignment: Text.AlignRight
  color: mouse.containsMouse && copyable ? Commons.Color.accent : Commons.Color.foreground
  font.family: Style.font.family
  font.pixelSize: Style.font.body

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.copyable
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.copyRequested(root.text)
  }
}
