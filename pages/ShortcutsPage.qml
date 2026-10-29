import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "../Core/ManagedBlock.js" as MB
import "shortcuts"
import "shortcuts/ShortcutLogic.js" as Logic

// Shortcuts: browse every active binding, add/edit/remove custom ones and
// disable built-in ones.
//
// Active bindings come from `hyprctl binds` (key, modifiers, description);
// the action behind Lua binds (Hyprland reports them as "__lua") comes from
// the same Lua source scan `omarchy menu keybindings` uses. Changes live only
// in the managed block "bindings" at the end of ~/.config/hypr/bindings.lua:
// `o.bind(...)` for custom shortcuts, `hl.unbind(...)` to disable or replace
// existing ones. The user's own lines are never touched.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // Overridable for tests (see tools/tests/ShortcutsPageWriteTest.qml).
  property string configPath: ""
  // false: write the file only, never reload Hyprland. Used by tests.
  property bool liveApply: true

  readonly property string path: configPath !== "" ? configPath : (sys ? sys.hyprDir + "/bindings.lua" : "")

  property var binds: []        // parsed active binds, annotated
  property var entries: []      // managed block entries
  property var userIds: ({})    // combo ids bound in the user's own lines
  property var actions: ({})    // Lua source scan cache
  property var apps: []
  property bool loading: false
  property bool busy: false
  property string query: ""
  property bool editorOpen: false
  property int editIndex: -1

  readonly property var groups: Logic.groupBinds(binds, query)
  readonly property var disabled: entries.filter(function(e) { return e.kind === "disable" })

  spacing: Style.spacing.huge

  function activated() {
    reload()
    if (apps.length === 0) loadApps()
  }

  // ---- loading ------------------------------------------------------------
  function reload() {
    if (!sys) return
    loading = true
    sys.readFile(page.path, function(text) {
      var body = MB.read(text, "bindings", "--")
      page.entries = Logic.parseEntries(body || "")
      page.userIds = Logic.parseUserCombos(MB.remove(text, "bindings", "--"))
      page.loadBinds()
    })
  }

  function loadBinds() {
    sys.run(["hyprctl", "binds"], function(r) {
      if (r.code !== 0) {
        page.loading = false
        if (app) app.toast("Could not read keybindings: " + (r.stderr || r.stdout), true)
        return
      }
      var parsed = Logic.parseBindsText(r.stdout)
      page.binds = page.annotate(parsed, page.actions)
      page.loading = false
      page.loadActions(parsed)
    })
  }

  // Reuse Omarchy's Lua source scan (build_lua_bind_cache from
  // omarchy-menu-keybindings) to learn what each Lua bind runs. Only the
  // function is extracted and run; the menu itself never opens.
  function loadActions(parsed) {
    sys.sh("src=$(command -v omarchy-menu-keybindings) || exit 0\n"
      + "fn=$(awk '/^build_lua_bind_cache\\(\\) \\{/{on=1} on{print} on&&/^LUA$/{lua=1} lua&&/^}$/{exit}' \"$src\")\n"
      + "case \"$fn\" in 'build_lua_bind_cache() {'*'}') ;; *) exit 0 ;; esac\n"
      + "declare -A LUA_BIND_KEY_MAP LUA_BIND_DISPATCHER_MAP LUA_BIND_ARG_MAP\n"
      + "eval \"$fn\"\n"
      + "build_lua_bind_cache\n"
      + "for k in \"${!LUA_BIND_DISPATCHER_MAP[@]}\"; do printf '%s\\x1f%s\\x1f%s\\n' \"$k\" \"${LUA_BIND_DISPATCHER_MAP[$k]}\" \"${LUA_BIND_ARG_MAP[$k]}\"; done",
      [], function(r) {
        page.actions = Logic.parseActionCache(r.stdout)
        page.binds = page.annotate(parsed, page.actions)
      })
  }

  function annotate(parsed, actions) {
    var customIds = ({})
    entries.forEach(function(e) { if (e.kind === "bind") customIds[Logic.comboIdFromString(e.keys)] = e })
    return parsed.map(function(b) {
      var copy = JSON.parse(JSON.stringify(b))
      copy.action = Logic.lookupAction(actions, b)
      var e = customIds[b.id]
      copy.custom = e !== undefined && (e.description || "") === (b.description || "")
      copy.user = !copy.custom && userIds[b.id] === true
      return copy
    })
  }

  function loadApps() {
    sys.sh("IFS=: read -ra dirs <<< \"${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\"\n"
      + "files=()\n"
      + "for d in \"${dirs[@]}\"; do [ -d \"$d/applications\" ] || continue; while IFS= read -r -d '' f; do files+=(\"$f\"); done < <(find \"$d/applications\" -name '*.desktop' -print0 2>/dev/null | sort -z); done\n"
      + "[ ${#files[@]} -eq 0 ] && exit 0\n"
      + "awk 'FNR==1{if(f!=\"\")print f\"\\t\"n\"\\t\"h; f=FILENAME; n=\"\"; h=\"\"; s=0}"
      + " /^\\[/{s=($0==\"[Desktop Entry]\")}"
      + " s&&/^Name=/&&n==\"\"{n=substr($0,6)}"
      + " s&&/^(NoDisplay|Hidden)=true/{h=\"true\"}"
      + " s&&/^Type=/&&$0!=\"Type=Application\"{h=\"true\"}"
      + " END{if(f!=\"\")print f\"\\t\"n\"\\t\"h}' \"${files[@]}\"",
      [], function(r) { page.apps = Logic.parseDesktopEntries(r.stdout) })
  }

  // ---- writing ------------------------------------------------------------
  function writeEntries(next, successText, callback) {
    if (!sys || busy) return
    busy = true
    var body = Logic.renderEntries(next)
    sys.readFile(page.path, function(text) {
      var out = body ? MB.replace(text, "bindings", body, "--") : MB.remove(text, "bindings", "--")
      sys.writeFile(page.path, out, function(ok, r) {
        if (!ok) {
          page.busy = false
          if (app) app.toast("Could not save shortcuts: " + (r.stderr || "unknown error"), true)
          if (callback) callback(false)
          return
        }
        page.entries = next
        var done = function(errors) {
          page.busy = false
          if (errors) { if (app) app.toast("Saved, but Hyprland reports errors:\n" + errors, true) }
          else if (app) app.toast(successText, false)
          if (callback) callback(!errors)
          page.reload()
        }
        if (page.liveApply) sys.hyprReload(done)
        else done("")
      })
    })
  }

  function openEditor(index) {
    editIndex = index
    editor.reset(index >= 0 ? entries[index] : null)
    editorOpen = true
  }

  function closeEditor() {
    editorOpen = false
    editIndex = -1
  }

  function disabledIndex(keys) {
    for (var i = 0; i < entries.length; i++)
      if (entries[i].kind === "disable" && entries[i].keys === keys) return i
    return -1
  }

  function entryIndexForBind(b) {
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e.kind === "bind" && Logic.comboIdFromString(e.keys) === b.id) return i
    }
    return -1
  }

  // draft: { keys, description, action, value }
  function saveDraft(draft, force) {
    var old = editIndex >= 0 ? entries[editIndex] : null
    var c = Logic.splitCombo(draft.keys)
    var newId = Logic.comboId(c.modmask, c.key)
    var ignore = old ? [Logic.comboIdFromString(old.keys)] : []
    var conflicts = Logic.findConflicts(binds, c.modmask, c.key, ignore)

    var ownClash = conflicts.filter(function(b) { return b.custom })
    if (ownClash.length) {
      if (app) app.toast(Logic.comboLabel(c.modmask, c.key) + " is already your shortcut \"" + ownClash[0].description + "\". Edit or remove that one first.", true)
      return
    }

    var entry = { kind: "bind", keys: draft.keys, description: draft.description, action: draft.action, value: draft.value, replaces: false, was: "" }
    if (old && Logic.comboIdFromString(old.keys) === newId && old.replaces) {
      entry.replaces = true
      entry.was = old.was
    }

    if (conflicts.length && !force) {
      var was = conflicts.map(function(b) { return b.description || Logic.actionLabel(b.action) || b.dispatcher }).join(", ")
      app.confirm(Logic.comboLabel(c.modmask, c.key) + " is bound to \"" + was + "\". Replace it? The old binding is unbound.",
        "Replace", function() { page.saveDraft(draft, true) })
      return
    }
    if (conflicts.length) {
      entry.replaces = true
      entry.was = conflicts.map(function(b) { return b.description || Logic.actionLabel(b.action) || b.dispatcher }).join(", ")
    }

    var next = entries.slice()
    if (old) next[editIndex] = entry
    else next.push(entry)
    var msg = entry.replaces && !(old && old.replaces)
      ? "Saved. " + Logic.comboLabel(c.modmask, c.key) + " was \"" + entry.was + "\" before."
      : "Shortcut saved"
    writeEntries(next, msg, function(ok) { if (ok) page.closeEditor() })
  }

  function removeEntry(index) {
    var e = entries[index]
    if (!e) return
    var c = Logic.splitCombo(e.keys)
    var label = Logic.comboLabel(c.modmask, c.key)
    var msg = e.kind === "disable"
      ? "Enable \"" + (e.was || label) + "\" (" + label + ") again?"
      : "Remove shortcut \"" + e.description + "\" (" + label + ")?" + (e.replaces ? " " + label + " goes back to \"" + e.was + "\"." : "")
    app.confirm(msg, e.kind === "disable" ? "Enable" : "Remove", function() {
      var next = page.entries.slice()
      next.splice(index, 1)
      page.writeEntries(next, e.kind === "disable" ? "Shortcut enabled" : "Shortcut removed")
    })
  }

  function disableBind(b) {
    var label = Logic.comboLabel(b.modmask, b.key)
    var note = b.user ? " It is set in your bindings.lua; this adds an unbind after it." : ""
    app.confirm("Disable \"" + b.description + "\" (" + label + ")?" + note, "Disable", function() {
      var next = page.entries.concat([{ kind: "disable", keys: b.combo, was: b.description }])
      page.writeEntries(next, "Disabled " + label)
    })
  }

  Timer { id: queryTimer; interval: 150; onTriggered: page.query = search.text }

  // ---- header -------------------------------------------------------------
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.spacing.lg

    TextField {
      id: search
      Layout.fillWidth: true
      placeholderText: "Search shortcuts, keys or commands"
      onTextChanged: queryTimer.restart()
    }
    Button {
      text: "Add shortcut"
      iconText: String.fromCodePoint(0xF067)
      bordered: true
      enabled: !page.editorOpen
      opacity: enabled ? 1 : 0.45
      onClicked: page.openEditor(-1)
    }
  }

  ShortcutEditor {
    id: editor
    visible: page.editorOpen
    binds: page.binds
    apps: page.apps
    window: page.app ? page.app.window : null
    busy: page.busy
    onSaveRequested: function(draft) { page.saveDraft(draft, false) }
    onCancelRequested: page.closeEditor()
  }

  Text {
    visible: page.loading && page.binds.length === 0
    text: "Loading shortcuts…"
    textFormat: Text.PlainText
    color: Util.alpha(Commons.Color.foreground, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  Text {
    visible: !page.loading && page.groups.length === 0 && page.query !== ""
    text: "No shortcuts match \"" + page.query + "\"."
    textFormat: Text.PlainText
    color: Util.alpha(Commons.Color.foreground, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // ---- groups -------------------------------------------------------------
  Repeater {
    model: page.groups

    SettingsSection {
      id: group
      required property var modelData
      title: modelData.title + "  ·  " + modelData.items.length
      description: modelData.title === "Custom" ? "Added here. Stored in bindings.lua in a block managed by Settings."
        : modelData.title === "Your bindings" ? "Hand-written in ~/.config/hypr/bindings.lua." : ""

      Repeater {
        model: group.modelData.items

        BindRow {
          required property var modelData
          bind: modelData
          onEditRequested: page.openEditor(page.entryIndexForBind(modelData))
          onRemoveRequested: page.removeEntry(page.entryIndexForBind(modelData))
          onDisableRequested: page.disableBind(modelData)
        }
      }
    }
  }

  // ---- disabled -----------------------------------------------------------
  SettingsSection {
    visible: page.disabled.length > 0 && page.query === ""
    title: "Disabled"
    description: "Turned off here. Enable to restore the original binding."

    Repeater {
      model: page.disabled

      RowLayout {
        id: disabledRow
        required property var modelData
        readonly property var combo: Logic.splitCombo(modelData.keys)
        Layout.fillWidth: true
        spacing: Style.spacing.xxl

        KeyCaps {
          Layout.preferredWidth: Style.space(210)
          modmask: disabledRow.combo.modmask
          key: disabledRow.combo.key
          dim: true
        }
        Text {
          Layout.fillWidth: true
          text: disabledRow.modelData.was || disabledRow.modelData.keys
          textFormat: Text.PlainText
          color: Util.alpha(Commons.Color.foreground, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.strikeout: true
          elide: Text.ElideRight
        }
        Button {
          text: "Enable"
          onClicked: page.removeEntry(page.disabledIndex(disabledRow.modelData.keys))
        }
      }
    }
  }
}
