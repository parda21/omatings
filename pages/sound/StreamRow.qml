import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One application playback stream: name, what it plays, volume + mute.
// `node` is a live PwNode (tracked by the page's PwObjectTracker).
ColumnLayout {
  id: row

  property var node: null
  property string label: ""
  // Fallback writers for nodes whose audio interface is not bound.
  property var setVolume: null
  property var toggleMute: null

  readonly property bool hasAudio: !!(node && node.audio)
  readonly property real volume: hasAudio ? node.audio.volume : 0
  readonly property bool muted: hasAudio ? node.audio.muted : false

  Layout.fillWidth: true
  spacing: Style.spacing.xs

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.spacing.lg

    Text {
      textFormat: Text.PlainText
      text: row.label
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
      Layout.maximumWidth: implicitWidth
      Layout.fillWidth: true
    }
    Text {
      textFormat: Text.PlainText
      text: Model.streamMediaName(row.node)
      visible: text !== ""
      color: Util.alpha(Commons.Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      Layout.fillWidth: true
    }
    Item { Layout.fillWidth: true; visible: Model.streamMediaName(row.node) === "" }
  }

  VolumeRow {
    Layout.fillWidth: true
    value: row.volume
    maximum: 1.5
    muted: row.muted
    iconText: Model.volumeGlyph(row.volume, row.muted)
    onMoved: function(v) { if (typeof row.setVolume === "function") row.setVolume(row.node, v) }
    onMuteToggled: if (typeof row.toggleMute === "function") row.toggleMute(row.node)
  }
}
