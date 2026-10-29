import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mute button + volume slider + percentage, one line.
//
//   VolumeRow {
//     value: node.audio.volume; muted: node.audio.muted
//     iconText: "…"
//     onMoved: function(v) { node.audio.volume = v }
//     onMuteToggled: node.audio.muted = !node.audio.muted
//   }
RowLayout {
  id: root

  property real value: 0
  property real maximum: 1
  property bool muted: false
  property string iconText: ""
  property string muteTooltip: muted ? "Unmute" : "Mute"
  // Shown instead of the percentage (e.g. "L 20%" for balance).
  property string valueText: ""
  property real step: 0.05
  property real minimum: 0

  signal moved(real value)
  signal muteToggled()

  spacing: Style.spacing.lg
  Layout.fillWidth: true

  // PanelSlider colors itself from a bar; a settings window has none, so hand
  // it the theme the same way Omarchy's dev gallery does.
  QtObject {
    id: themeBar
    readonly property color foreground: Commons.Color.foreground
    readonly property color background: Commons.Color.background
    readonly property color urgent: Commons.Color.urgent
    readonly property string fontFamily: Style.font.family
  }

  Button {
    visible: root.iconText !== ""
    iconText: root.iconText
    iconSize: Style.font.iconLarge
    tooltipText: root.muteTooltip
    opacity: root.muted ? 0.6 : 1.0
    enabled: root.enabled
    onClicked: root.muteToggled()
  }

  PanelSlider {
    id: slider
    bar: themeBar
    Layout.fillWidth: true
    minimum: root.minimum
    maximum: root.maximum
    step: root.step
    value: root.value
    opacity: root.muted ? 0.5 : 1.0
    enabled: root.enabled
    onMoved: function(v) { root.moved(v) }
    onRightClicked: root.muteToggled()
  }

  Text {
    textFormat: Text.PlainText
    text: root.valueText !== "" ? root.valueText
      : Math.round((slider.dragging ? slider.liveValue : root.value) * 100) + "%"
    color: Util.alpha(Commons.Color.foreground, root.muted ? 0.5 : 0.8)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
    horizontalAlignment: Text.AlignRight
    Layout.preferredWidth: Style.space(44)
  }
}
