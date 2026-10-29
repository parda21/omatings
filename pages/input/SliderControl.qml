import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Slider + value readout for SettingsRow. `moved(value)` fires while
// dragging with the value already snapped to `step`.
//
//   SliderControl { from: 10; to: 100; step: 1; value: 40; suffix: " /s"; onMoved: (v) => ... }
RowLayout {
  id: root

  property real value: 0
  property real from: 0
  property real to: 1
  property real step: 0.05
  property int decimals: 2
  property string suffix: ""
  property bool signed: false
  property color foreground: Commons.Color.foreground

  signal moved(real value)

  spacing: Style.spacing.lg
  implicitWidth: Style.space(300)

  function snap(v) {
    var s = root.step > 0 ? root.step : 1
    var snapped = root.from + Math.round((v - root.from) / s) * s
    return Math.max(root.from, Math.min(root.to, Math.round(snapped * 1000) / 1000))
  }

  function format(v) {
    var t = Number(v).toFixed(root.decimals)
    if (root.signed && v > 0) t = "+" + t
    return t + root.suffix
  }

  PanelSlider {
    id: slider
    bar: null
    Layout.fillWidth: true
    minimum: root.from
    maximum: root.to
    step: root.step
    value: root.value
    trackColor: Style.selectedFill
    fillColor: root.foreground
    knobColor: root.foreground
    tickColor: Commons.Color.background
    onMoved: function(v) {
      var s = root.snap(v)
      if (s !== root.value) root.moved(s)
    }
  }

  Text {
    text: root.format(slider.dragging ? root.snap(slider.liveValue) : root.value)
    textFormat: Text.PlainText
    color: Util.alpha(root.foreground, 0.75)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignRight
    Layout.preferredWidth: Style.space(64)
  }
}
