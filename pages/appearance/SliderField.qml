import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// PanelSlider with a value readout, sized for a SettingsRow control slot.
//
//   SliderField { minimum: 0; maximum: 30; value: 5; suffix: " px"; onMoved: v => … }
RowLayout {
  id: root

  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 1
  property bool integer: true
  property int decimals: 0
  property string suffix: ""
  property int tickCount: 0
  property real sliderWidth: Style.space(220)

  readonly property real shownValue: slider.dragging ? slider.liveValue : root.value

  signal moved(real value)
  signal released(real value)

  spacing: Style.spacing.lg
  opacity: enabled ? 1 : 0.45

  PanelSlider {
    id: slider
    bar: null
    Layout.preferredWidth: root.sliderWidth
    value: root.value
    minimum: root.minimum
    maximum: root.maximum
    step: root.step
    integer: root.integer
    tickCount: root.tickCount
    trackColor: Style.selectedFillFor(Commons.Color.foreground, Commons.Color.accent)
    fillColor: Commons.Color.accent
    knobColor: Commons.Color.foreground
    tickColor: Commons.Color.background
    enabled: root.enabled
    onMoved: function(v) { root.moved(v) }
    onReleased: function(v) { root.released(v) }
  }

  Text {
    Layout.preferredWidth: Style.space(52)
    horizontalAlignment: Text.AlignRight
    text: Number(root.shownValue).toFixed(root.decimals) + root.suffix
    textFormat: Text.PlainText
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.features: { "tnum": 1 }
  }
}
