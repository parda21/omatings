import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One selectable audio device (sink or source). `selected` marks the current
// default; clicking emits `clicked()` and the page makes it the default.
CursorSurface {
  id: row

  property string glyph: ""
  property string label: ""
  property string detail: ""
  property bool selected: false
  property bool busy: false

  signal clicked()

  Layout.fillWidth: true
  hasCursor: mouse.containsMouse && !selected
  current: selected
  implicitHeight: content.implicitHeight + Style.spacing.lg * 2

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
      text: row.glyph
      color: row.selected ? Commons.Color.accent : Commons.Color.foreground
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
        text: row.label
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: row.selected
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Text {
        visible: text !== ""
        textFormat: Text.PlainText
        text: row.detail
        color: Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
    }

    Text {
      visible: row.selected || row.busy
      textFormat: Text.PlainText
      text: row.busy ? "Switching…" : "Default"
      color: row.selected ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: row.selected ? Qt.ArrowCursor : Qt.PointingHandCursor
    onClicked: if (!row.selected) row.clicked()
  }
}
