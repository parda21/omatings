import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MonitorModel.js" as M

// Monitor arrangement: every enabled, non-mirroring display drawn at its
// logical size and position. Drag to move (snaps to edges, never
// overlaps, always stays attached on drop), click to select. Displays that
// are off or mirroring are listed as chips under the canvas.
//
//   ArrangementCanvas {
//     monitors: page.pending; names: page.monitorNames
//     selectedName: page.selectedName
//     onSelected: function(name) { ... }
//     onDropped: function(name, x, y) { ... }   // logical coordinates
//   }
ColumnLayout {
  id: canvas

  property var monitors: []
  // Stable list of names; the tile Repeater only rebuilds when it changes,
  // so a drag survives model updates.
  property var names: []
  property string selectedName: ""
  property string primaryName: ""
  property bool interactive: true

  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal selected(string name)
  signal dropped(string name, real x, real y)

  spacing: Style.spacing.lg

  readonly property var offLayout: {
    var out = []
    for (var i = 0; i < monitors.length; i++) if (!M.inLayout(monitors[i])) out.push(monitors[i])
    return out
  }

  Item {
    id: area
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(250)
    clip: true

    // Frozen during a drag so the scale doesn't change under the pointer.
    property var frozenView: null
    readonly property real pad: Style.space(28)
    readonly property real snapPx: Style.space(14)
    readonly property var liveView: {
      var b = M.bounds(M.layoutRects(canvas.monitors))
      var aw = Math.max(1, width - pad * 2)
      var ah = Math.max(1, height - pad * 2)
      var f = (b.width > 0 && b.height > 0) ? Math.min(aw / b.width, ah / b.height) : 0.05
      f = Math.min(f, 0.12)
      return { f: f, ox: (width - b.width * f) / 2 - b.x * f, oy: (height - b.height * f) / 2 - b.y * f }
    }
    readonly property var view: frozenView || liveView

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(canvas.foreground, 0.03)
      border.width: 1
      border.color: Util.alpha(canvas.foreground, 0.08)
    }

    Text {
      visible: canvas.monitors.length > 0 && M.layoutRects(canvas.monitors).length === 0
      anchors.centerIn: parent
      text: "No display is on"
      color: Util.alpha(canvas.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Repeater {
      model: canvas.names

      Item {
        id: tile
        required property string modelData
        readonly property var mon: M.findMonitor(canvas.monitors, modelData)
        readonly property var rect: mon ? M.rectOf(mon) : ({ x: 0, y: 0, width: 0, height: 0 })
        readonly property bool isSelected: canvas.selectedName === modelData
        readonly property real f: area.view.f

        property bool dragging: false
        property real dragX: 0
        property real dragY: 0

        visible: mon !== null && M.inLayout(mon)
        x: area.view.ox + (dragging ? dragX : rect.x) * f
        y: area.view.oy + (dragging ? dragY : rect.y) * f
        width: Math.max(Style.space(16), rect.width * f)
        height: Math.max(Style.space(12), rect.height * f)
        z: dragging ? 10 : (isSelected ? 5 : 1)

        Rectangle {
          anchors.fill: parent
          anchors.margins: 1
          radius: Style.cornerRadius
          color: tile.isSelected ? Util.alpha(canvas.accent, 0.22) : Util.alpha(canvas.foreground, tileMouse.containsMouse ? 0.12 : 0.07)
          border.width: tile.isSelected ? 2 : 1
          border.color: tile.isSelected ? canvas.accent : Util.alpha(canvas.foreground, 0.35)
        }

        Column {
          anchors.centerIn: parent
          width: parent.width - Style.spacing.md * 2
          spacing: Style.spacing.xxs

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: tile.mon ? M.displayName(tile.mon) : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: canvas.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: tile.height > Style.space(46)
            text: tile.mon ? tile.mon.name + "  ·  " + tile.rect.width + "×" + tile.rect.height : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Util.alpha(canvas.foreground, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: canvas.primaryName === tile.modelData && tile.height > Style.space(30)
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: Style.spacing.md
          text: String.fromCodePoint(0xF005) + " Primary"
          textFormat: Text.PlainText
          color: canvas.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: tileMouse
          anchors.fill: parent
          hoverEnabled: true
          preventStealing: true
          cursorShape: !canvas.interactive ? Qt.ArrowCursor : (tile.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

          property point start: Qt.point(0, 0)
          property real startX: 0
          property real startY: 0

          function proposed(mouse) {
            var p = mapToItem(area, mouse.x, mouse.y)
            return {
              name: tile.modelData,
              x: startX + (p.x - start.x) / tile.f,
              y: startY + (p.y - start.y) / tile.f,
              width: tile.rect.width,
              height: tile.rect.height
            }
          }

          onPressed: function(mouse) {
            canvas.selected(tile.modelData)
            if (!canvas.interactive) return
            area.frozenView = area.liveView
            start = mapToItem(area, mouse.x, mouse.y)
            startX = tile.rect.x
            startY = tile.rect.y
            tile.dragX = startX
            tile.dragY = startY
          }
          onPositionChanged: function(mouse) {
            if (!pressed || !canvas.interactive || !area.frozenView) return
            var p = mapToItem(area, mouse.x, mouse.y)
            if (!tile.dragging && Math.abs(p.x - start.x) + Math.abs(p.y - start.y) < Style.space(4)) return
            tile.dragging = true
            var r = M.dragRect(proposed(mouse), M.layoutRects(canvas.monitors, tile.modelData), area.snapPx / tile.f)
            tile.dragX = r.x
            tile.dragY = r.y
          }
          onReleased: function(mouse) {
            if (tile.dragging) {
              var r = M.dropRect({ name: tile.modelData, x: tile.dragX, y: tile.dragY, width: tile.rect.width, height: tile.rect.height },
                                 M.layoutRects(canvas.monitors, tile.modelData), area.snapPx / tile.f)
              tile.dragging = false
              if (r.x !== tile.rect.x || r.y !== tile.rect.y) canvas.dropped(tile.modelData, r.x, r.y)
            }
            area.frozenView = null
          }
          onCanceled: {
            tile.dragging = false
            area.frozenView = null
          }
        }
      }
    }
  }

  Flow {
    Layout.fillWidth: true
    visible: canvas.offLayout.length > 0
    spacing: Style.spacing.md

    Repeater {
      model: canvas.offLayout

      Button {
        required property var modelData
        text: M.displayName(modelData) + "  ·  " + (modelData.enabled ? "mirrors " + modelData.mirror : "off")
        iconText: String.fromCodePoint(0xF0379)
        selected: canvas.selectedName === modelData.name
        bordered: true
        opacity: modelData.enabled ? 1 : 0.6
        onClicked: canvas.selected(modelData.name)
      }
    }
  }
}
