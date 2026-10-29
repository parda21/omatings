import QtQuick
import QtQuick.Layouts
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ShortcutLogic.js" as Logic

// Click, then press a key combination. Esc (without modifiers) cancels.
// While capturing, a Wayland shortcuts inhibitor asks Hyprland to pass its
// own bindings (SUPER + …) through to us instead of running them.
//
//   KeyCaptureField { window: app.window; combo: "SUPER + F"; onCaptured: (combo) => ... }
BorderSurface {
  id: root

  property string combo: ""          // Hyprland form: "SUPER + SHIFT + code:10"
  property var window: null          // FloatingWindow for the inhibitor
  property bool capturing: false
  property string hint: ""
  property var _held: []
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal captured(string combo)
  signal canceled()

  readonly property var _parsed: Logic.splitCombo(combo)
  readonly property string _label: capturing
    ? (_held.length ? Logic.comboParts(Logic.namesToModmask(_held), "x").slice(0, -1).join(" + ") + " + …" : "Press keys…")
    : (combo ? Logic.comboLabel(_parsed.modmask, _parsed.key) : "Click to set")

  implicitWidth: Style.space(260)
  implicitHeight: Style.spacing.controlHeight + Style.spacing.sm
  radius: Style.cornerRadius
  activeFocusOnTab: true
  color: capturing ? Style.selectedAccentFill : Style.controlFill(activeFocus, mouse.containsMouse, foreground, accent)
  borderSpec: Border.controlSpec(capturing || activeFocus ? "focus" : (mouse.containsMouse ? "hover-cursor" : "normal"), foreground, accent)

  function start() {
    hint = ""
    _held = []
    capturing = true
    forceActiveFocus()
  }

  function stop() {
    capturing = false
    _held = []
  }

  onActiveFocusChanged: if (!activeFocus && capturing) { stop(); canceled() }

  Keys.onPressed: function(event) {
    if (!capturing) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        start(); event.accepted = true
      }
      return
    }
    event.accepted = true
    var mods = Logic.qtModsToNames(event.modifiers)
    if (event.key === Qt.Key_Escape && mods.length === 0) { stop(); canceled(); return }
    var key = Logic.qtKeyToHypr(event.key, event.nativeScanCode, event.text)
    if (key === "") {
      // Modifier only: show what's held so far.
      _held = mods.length ? mods : Logic.qtModsToNames(_modFromKey(event.key))
      return
    }
    if (mods.length === 0 && Logic.needsModifier(key)) {
      hint = "Add a modifier like Super, Ctrl or Alt."
      return
    }
    hint = ""
    stop()
    captured(mods.concat([key]).join(" + "))
  }

  Keys.onReleased: function(event) {
    if (capturing) {
      event.accepted = true
      _held = Logic.qtModsToNames(event.modifiers)
    }
  }

  function _modFromKey(k) {
    if (k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R) return Qt.MetaModifier
    if (k === Qt.Key_Control) return Qt.ControlModifier
    if (k === Qt.Key_Alt) return Qt.AltModifier
    if (k === Qt.Key_Shift) return Qt.ShiftModifier
    return 0
  }

  // Only create the inhibitor when there is a real window (not in tests).
  Loader {
    active: root.window !== null && root.window !== undefined
    sourceComponent: ShortcutInhibitor {
      window: root.window
      enabled: root.capturing
    }
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + Style.spacing.controlPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.controlPaddingX
    spacing: Style.spacing.md

    Text {
      text: String.fromCodePoint(0xF11C)
      color: root.capturing ? root.accent : Util.alpha(root.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
    }
    Text {
      Layout.fillWidth: true
      text: root._label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.combo || root.capturing ? root.foreground : Util.alpha(root.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: root.capturing
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.capturing ? root.forceActiveFocus() : root.start()
  }
}
