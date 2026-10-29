import QtQuick
import qs.Ui

// Dropdown that always shows `current` (the kit's Dropdown assigns `value`
// itself on selection, which would break a plain binding). React to
// `picked(value)` and update the model; `current` follows.
Dropdown {
  id: dd

  property string current: ""
  signal picked(string value)

  showLabel: false
  value: current
  onCurrentChanged: value = current

  onChanged: function(v) {
    dd.picked(v)
    dd.value = Qt.binding(function() { return dd.current })
  }
}
