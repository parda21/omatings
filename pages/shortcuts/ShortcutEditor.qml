import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../../Core"
import "ShortcutLogic.js" as Logic

// Add/edit form for a custom shortcut. The page owns writing; this only
// collects a draft and shows conflicts.
//
//   ShortcutEditor { entry: null /* or a managed entry */; binds: ...; apps: ...
//                    onSaveRequested: (draft) => ...; onCancelRequested: ... }
SettingsSection {
  id: root

  property var entry: null           // existing managed entry when editing
  property var binds: []             // parsed active binds (for conflicts)
  property var apps: []              // [{ value, label, description }]
  property var window: null
  property bool busy: false

  property string keys: ""
  property string description: ""
  property string action: "app"
  property string appId: ""
  property string command: ""

  signal saveRequested(var draft)
  signal cancelRequested()

  readonly property var _combo: Logic.splitCombo(keys)
  readonly property string _ownId: entry ? Logic.comboIdFromString(entry.keys) : ""
  readonly property var conflicts: keys ? Logic.findConflicts(binds, _combo.modmask, _combo.key, _ownId ? [_ownId] : []) : []
  readonly property bool valid: keys !== "" && description.trim() !== ""
    && (action === "app" ? appId !== "" : command.trim() !== "")

  title: entry ? "Edit shortcut" : "New shortcut"

  function reset(e) {
    entry = e || null
    keys = e ? e.keys : ""
    description = e ? e.description : ""
    action = e ? e.action : "app"
    appId = e && e.action === "app" ? e.value : ""
    command = e && e.action === "command" ? e.value : ""
    descField.text = description
    cmdField.text = command
  }

  function appLabel(id) {
    for (var i = 0; i < apps.length; i++) if (apps[i].value === id) return apps[i].label
    return ""
  }

  SettingsRow {
    label: "Shortcut"
    description: capture.hint !== "" ? capture.hint : "Click the field, then press the keys. Esc cancels."
    KeyCaptureField {
      id: capture
      window: root.window
      combo: root.keys
      onCaptured: function(c) { root.keys = c }
    }
  }

  Text {
    visible: root.conflicts.length > 0
    text: "Already used by: " + root.conflicts.map(function(b) { return b.description || Logic.actionLabel(b.action) || b.dispatcher }).join(", ")
      + ". Saving replaces it."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Commons.Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    Layout.fillWidth: true
  }

  SettingsRow {
    label: "Action"
    ButtonGroup {
      options: [{ value: "app", label: "Launch app" }, { value: "command", label: "Run command" }]
      value: root.action
      onChanged: function(v) { root.action = v }
    }
  }

  SettingsRow {
    visible: root.action === "app"
    label: "App"
    SearchableDropdown {
      showLabel: false
      width: Style.space(300)
      options: root.apps
      value: root.appId
      triggerLabel: root.appId && !root.appLabel(root.appId) ? root.appId : ""
      placeholderText: "Search apps…"
      onChanged: function(v) {
        root.appId = v
        if (descField.text.trim() === "") descField.text = root.appLabel(v)
      }
    }
  }

  SettingsRow {
    visible: root.action === "command"
    label: "Command"
    description: "Runs in a shell, e.g. alacritty -e btop"
    TextField {
      id: cmdField
      width: Style.space(300)
      placeholderText: "Command"
      onTextChanged: root.command = text
    }
  }

  SettingsRow {
    label: "Description"
    description: "Shown in the keybindings menu (Super + K)."
    TextField {
      id: descField
      width: Style.space(300)
      placeholderText: "e.g. Open notes"
      onTextChanged: root.description = text
    }
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.spacing.lg
    Item { Layout.fillWidth: true }
    Button {
      text: "Cancel"
      onClicked: root.cancelRequested()
    }
    Button {
      text: root.busy ? "Saving…" : "Save"
      bordered: true
      enabled: root.valid && !root.busy
      opacity: enabled ? 1 : 0.45
      onClicked: root.saveRequested({
        keys: root.keys,
        description: root.description.trim(),
        action: root.action,
        value: root.action === "app" ? root.appId : root.command.trim()
      })
    }
  }
}
