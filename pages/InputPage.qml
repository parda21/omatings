import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "../Core/ManagedBlock.js" as MB
import "input"
import "input/InputLogic.js" as Logic

// Keyboard & Mouse: layouts, key options, repeat, pointer and touchpad.
//
// Values shown are the live Hyprland values (`hyprctl getoption`). A change
// is applied live with `hyprctl eval` for instant feedback and persisted in
// the managed block "input" at the end of ~/.config/hypr/input.lua (one
// hl.config call holding only the values changed here), followed by a
// reload + config error check. Slider writes are debounced.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // Overridable for tests (see tools/tests/InputPageWriteTest.qml).
  property string configPath: ""
  // false: never touch the running session (no hyprctl eval/reload,
  // no touchpad toggle). Used by tests.
  property bool liveApply: true

  readonly property string path: configPath !== "" ? configPath : (sys ? sys.hyprDir + "/input.lua" : "")
  readonly property string touchpadStateFile: (sys ? sys.home : "") + "/.local/state/omarchy/toggles/hypr/touchpad-disabled-name"

  // Live values keyed by Lua path ("repeat_rate", "touchpad.natural_scroll").
  property var live: ({})
  // Our managed overrides: { input: { ... } }.
  property var block: ({})
  property var rules: ({ layouts: [], variants: ({}) })
  property string touchpad: ""
  property bool touchpadEnabled: true
  property bool touchpadBusy: false
  property var mouseNames: []
  property bool loaded: false

  property bool _writing: false
  property bool _dirty: false
  property var _pendingLive: ({})

  readonly property var layouts: Logic.parseLayouts(val("kb_layout"), val("kb_variant"))
  readonly property var kbModel: Logic.parseKbOptions(val("kb_options"))
  readonly property bool hasOverrides: block.input !== undefined && Object.keys(block.input).length > 0

  spacing: Style.spacing.huge

  function activated() {
    reload()
  }

  // ---- state --------------------------------------------------------------
  function val(p) {
    var v = live[p]
    return v === undefined ? "" : v
  }

  function reload() {
    if (!sys) return
    // Don't clobber optimistic values while a write is queued.
    if (persistTimer.running || _writing) return

    sys.readFile(page.path, function(text) {
      var body = MB.read(text, "input", "--")
      page.block = body ? Logic.parseConfig(body) : ({})
    })
    sys.sh("for o in \"$@\"; do hyprctl getoption \"input:$o\" -j 2>/dev/null | tr -d '\\n'; echo; done",
      Logic.optionNames(), function(r) {
        page.live = Logic.parseLiveOptions(r.stdout)
        page.loaded = true
      })
    sys.json(["hyprctl", "devices", "-j"], function(d) {
      page.touchpad = Logic.findTouchpad(d)
      page.mouseNames = Logic.mice(d)
    })
    sys.sh("[ -f \"$1\" ]", [touchpadStateFile], function(r) { page.touchpadEnabled = r.code !== 0 })
    if (rules.layouts.length === 0) {
      sys.readFile("/usr/share/X11/xkb/rules/base.lst", function(text, exists) {
        if (exists) page.rules = Logic.parseXkbRules(text)
      })
    }
  }

  // set({ "repeat_rate": 30 }) — applies live, persists (debounced if asked).
  function set(map, debounce) {
    var nextLive = JSON.parse(JSON.stringify(live))
    var nextBlock = block
    var pend = JSON.parse(JSON.stringify(_pendingLive))
    for (var p in map) {
      nextLive[p] = map[p]
      nextBlock = Logic.setPath(nextBlock, "input." + p, map[p])
      pend[p] = map[p]
    }
    live = nextLive
    block = nextBlock
    _pendingLive = pend
    if (!liveTimer.running) liveTimer.start()
    if (debounce) persistTimer.restart()
    else { persistTimer.stop(); persist() }
  }

  function flushLive() {
    var lua = Logic.liveLuaMany(_pendingLive)
    _pendingLive = ({})
    if (!lua || !liveApply || !sys) return
    sys.hyprEval(lua, function(r) {
      var out = String(r.stdout || "").trim()
      if (r.code !== 0 || (out !== "" && out !== "ok"))
        console.warn("omatings input: live apply failed:", out || r.stderr)
    })
  }

  function persist(callback) {
    if (!sys) return
    if (_writing) { _dirty = true; return }
    _writing = true
    var body = Logic.renderConfig(block)
    sys.readFile(page.path, function(text) {
      var next = body ? MB.replace(text, "input", body, "--") : MB.remove(text, "input", "--")
      sys.writeFile(page.path, next, function(ok, r) {
        if (!ok) {
          _finishWrite()
          if (app) app.toast("Could not save input settings: " + (r.stderr || "unknown error"), true)
          if (callback) callback(false)
          return
        }
        if (!liveApply) {
          _finishWrite()
          if (callback) callback(true)
          return
        }
        sys.hyprReload(function(errors) {
          _finishWrite()
          if (errors) { if (app) app.toast("Saved, but Hyprland reports errors:\n" + errors, true) }
          else if (app) app.toast("Input settings saved", false)
          if (callback) callback(errors === "")
        })
      })
    })
  }

  function _finishWrite() {
    _writing = false
    if (_dirty) { _dirty = false; persist() }
  }

  function setLayouts(list) {
    if (list.length === 0) return
    var joined = Logic.joinLayouts(list)
    var map = { kb_layout: joined.kb_layout, kb_variant: joined.kb_variant }
    // A single layout can't be switched; keep the grp: option only if useful.
    if (list.length < 2 && kbModel.layoutSwitch) map.kb_options = Logic.withKbOption(val("kb_options"), "layoutSwitch", "")
    if (list.length >= 2 && !kbModel.layoutSwitch) map.kb_options = Logic.withKbOption(val("kb_options"), "layoutSwitch", "grp:alts_toggle")
    set(map, false)
  }

  function setKbOption(field, value) {
    set({ kb_options: Logic.withKbOption(val("kb_options"), field, value) }, false)
  }

  function setTouchpadEnabled(on) {
    if (!liveApply || !sys) { touchpadEnabled = on; return }
    touchpadBusy = true
    sys.run(["omarchy-toggle-touchpad", on ? "on" : "off"], function(r) {
      touchpadBusy = false
      if (r.code !== 0) {
        if (app) app.toast("Could not change the touchpad: " + (r.stderr || r.stdout), true)
      } else {
        touchpadEnabled = on
      }
    })
  }

  function resetAll() {
    block = ({})
    persistTimer.stop()
    persist(function() { page.reloadLive() })
  }

  function reloadLive() {
    sys.sh("for o in \"$@\"; do hyprctl getoption \"input:$o\" -j 2>/dev/null | tr -d '\\n'; echo; done",
      Logic.optionNames(), function(r) { page.live = Logic.parseLiveOptions(r.stdout) })
  }

  Timer { id: persistTimer; interval: 600; onTriggered: page.persist() }
  Timer { id: liveTimer; interval: 90; onTriggered: page.flushLive() }

  // ---- layouts ------------------------------------------------------------
  SettingsSection {
    title: "Keyboard layouts"
    description: "Shortcuts follow the first layout."

    Repeater {
      model: page.layouts

      RowLayout {
        id: layoutRow
        required property var modelData
        required property int index
        readonly property var variantOptions: [{ value: "", label: "Default" }].concat(page.rules.variants[modelData.layout] || [])

        Layout.fillWidth: true
        spacing: Style.spacing.lg

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xxs
          Text {
            text: Logic.layoutLabel(page.rules, layoutRow.modelData.layout, "")
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
          Text {
            text: layoutRow.index === 0 ? layoutRow.modelData.layout + " · primary" : layoutRow.modelData.layout
            textFormat: Text.PlainText
            color: Util.alpha(Commons.Color.foreground, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Dropdown {
          showLabel: false
          Layout.preferredWidth: Style.spacing.dropdownWidth
          visible: layoutRow.variantOptions.length > 1
          options: layoutRow.variantOptions
          value: layoutRow.modelData.variant
          onChanged: function(v) {
            var list = JSON.parse(JSON.stringify(page.layouts))
            list[layoutRow.index].variant = v
            page.setLayouts(list)
          }
        }

        Button {
          iconText: String.fromCodePoint(0xF062)
          tooltipText: "Move up"
          enabled: layoutRow.index > 0
          opacity: enabled ? 1 : 0.35
          onClicked: page.setLayouts(Logic.moveItem(page.layouts, layoutRow.index, layoutRow.index - 1))
        }
        Button {
          iconText: String.fromCodePoint(0xF063)
          tooltipText: "Move down"
          enabled: layoutRow.index < page.layouts.length - 1
          opacity: enabled ? 1 : 0.35
          onClicked: page.setLayouts(Logic.moveItem(page.layouts, layoutRow.index, layoutRow.index + 1))
        }
        Button {
          iconText: String.fromCodePoint(0xF1F8)
          tooltipText: "Remove"
          enabled: page.layouts.length > 1
          opacity: enabled ? 1 : 0.35
          onClicked: {
            var list = page.layouts.slice()
            list.splice(layoutRow.index, 1)
            page.setLayouts(list)
          }
        }
      }
    }

    Text {
      visible: page.layouts.length > 0 && Logic.isNonLatin(page.layouts[0].layout)
      text: "The first layout can't type Latin letters, so most shortcuts won't work. Move a Latin layout to the top."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      Layout.fillWidth: true
    }

    SettingsRow {
      label: "Add layout"
      SearchableDropdown {
        showLabel: false
        width: Style.spacing.searchableDropdownWidth
        options: page.rules.layouts
        value: ""
        triggerLabel: "Choose a layout…"
        placeholderText: "Search layouts…"
        onChanged: function(v) {
          if (!v) return
          for (var i = 0; i < page.layouts.length; i++) {
            if (page.layouts[i].layout === v && !page.layouts[i].variant) return
          }
          page.setLayouts(page.layouts.concat([{ layout: v, variant: "" }]))
        }
      }
    }

    SettingsRow {
      visible: page.layouts.length > 1
      label: "Switch layouts with"
      Dropdown {
        showLabel: false
        width: Style.spacing.dropdownWidth
        options: Logic.SWITCH_OPTIONS
        value: page.kbModel.layoutSwitch
        onChanged: function(v) { page.setKbOption("layoutSwitch", v) }
      }
    }
  }

  // ---- keyboard -----------------------------------------------------------
  SettingsSection {
    title: "Keyboard"

    SettingsRow {
      label: "Compose key"
      description: "Press it, then two keys to type special characters (e.g. ' then e for é)."
      Dropdown {
        showLabel: false
        width: Style.spacing.dropdownWidth
        options: Logic.COMPOSE_OPTIONS
        value: page.kbModel.compose
        onChanged: function(v) { page.setKbOption("compose", v) }
      }
    }

    SettingsRow {
      label: "Caps Lock key"
      description: page.kbModel.compose === "compose:caps" ? "Caps Lock is your compose key. Pick another compose key to change this." : "What the Caps Lock key does."
      Dropdown {
        showLabel: false
        width: Style.spacing.dropdownWidth
        enabled: page.kbModel.compose !== "compose:caps"
        opacity: enabled ? 1 : 0.45
        options: Logic.CAPS_OPTIONS
        value: page.kbModel.compose === "compose:caps" ? "" : page.kbModel.caps
        onChanged: function(v) { page.setKbOption("caps", v) }
      }
    }

    SettingsRow {
      label: "Both Shift keys toggle Caps Lock"
      description: "Released again by the next single Shift press."
      ToggleSwitch {
        checked: page.kbModel.bothShifts
        onToggled: page.setKbOption("bothShifts", !checked)
      }
    }

    SettingsRow {
      label: "Repeat delay"
      description: "How long to hold a key before it repeats."
      SliderControl {
        from: 100; to: 1000; step: 10; decimals: 0; suffix: " ms"
        value: Number(page.val("repeat_delay")) || 0
        onMoved: function(v) { page.set({ repeat_delay: Math.round(v) }, true) }
      }
    }

    SettingsRow {
      label: "Repeat rate"
      description: "Characters per second while a key is held."
      SliderControl {
        from: 5; to: 100; step: 1; decimals: 0; suffix: " /s"
        value: Number(page.val("repeat_rate")) || 0
        onMoved: function(v) { page.set({ repeat_rate: Math.round(v) }, true) }
      }
    }

    SettingsRow {
      label: "Test typing"
      TextField {
        width: Style.space(300)
        placeholderText: "Hold a key here to try the repeat settings"
      }
    }

    SettingsRow {
      label: "Num Lock on at startup"
      ToggleSwitch {
        checked: page.val("numlock_by_default") === true
        onToggled: page.set({ numlock_by_default: !checked }, false)
      }
    }
  }

  // ---- mouse --------------------------------------------------------------
  SettingsSection {
    title: "Mouse"
    description: page.mouseNames.length ? "Applies to " + page.mouseNames.join(", ") + "." : ""

    SettingsRow {
      label: "Pointer speed"
      description: "Also applies to the touchpad."
      SliderControl {
        from: -1; to: 1; step: 0.05; signed: true
        value: Number(page.val("sensitivity")) || 0
        onMoved: function(v) { page.set({ sensitivity: v }, true) }
      }
    }

    SettingsRow {
      label: "Acceleration"
      description: "Flat moves the pointer exactly as far as the mouse. Adaptive speeds up with faster movement."
      ButtonGroup {
        options: [{ value: "adaptive", label: "Adaptive" }, { value: "flat", label: "Flat" }]
        value: page.val("accel_profile") === "flat" ? "flat" : "adaptive"
        onChanged: function(v) { page.set({ accel_profile: v }, false) }
      }
    }

    SettingsRow {
      label: "Natural scrolling"
      description: "Content follows your fingers, like on a phone."
      ToggleSwitch {
        checked: page.val("natural_scroll") === true
        onToggled: page.set({ natural_scroll: !checked }, false)
      }
    }

    SettingsRow {
      label: "Scroll speed"
      SliderControl {
        from: 0.1; to: 3; step: 0.1; decimals: 1; suffix: "×"
        value: Number(page.val("scroll_factor")) || 1
        onMoved: function(v) { page.set({ scroll_factor: v }, true) }
      }
    }

    SettingsRow {
      label: "Left-handed"
      description: "Swap the left and right buttons."
      ToggleSwitch {
        checked: page.val("left_handed") === true
        onToggled: page.set({ left_handed: !checked }, false)
      }
    }
  }

  // ---- touchpad -----------------------------------------------------------
  SettingsSection {
    visible: page.touchpad !== ""
    title: "Touchpad"

    SettingsRow {
      label: "Touchpad"
      description: page.touchpadEnabled ? page.touchpad : "Turned off (omarchy toggle touchpad)."
      ToggleSwitch {
        checked: page.touchpadEnabled
        busy: page.touchpadBusy
        onToggled: page.setTouchpadEnabled(!checked)
      }
    }

    SettingsRow {
      label: "Natural scrolling"
      description: "Content follows your fingers."
      ToggleSwitch {
        checked: page.val("touchpad.natural_scroll") === true
        onToggled: page.set({ "touchpad.natural_scroll": !checked }, false)
      }
    }

    SettingsRow {
      label: "Tap to click"
      ToggleSwitch {
        checked: page.val("touchpad.tap_to_click") === true
        onToggled: page.set({ "touchpad.tap_to_click": !checked }, false)
      }
    }

    SettingsRow {
      label: "Disable while typing"
      ToggleSwitch {
        checked: page.val("touchpad.disable_while_typing") === true
        onToggled: page.set({ "touchpad.disable_while_typing": !checked }, false)
      }
    }

    SettingsRow {
      label: "Click with fingers"
      description: "Two fingers right-click, three fingers middle-click. Off: click in the bottom corners instead."
      ToggleSwitch {
        checked: page.val("touchpad.clickfinger_behavior") === true
        onToggled: page.set({ "touchpad.clickfinger_behavior": !checked }, false)
      }
    }

    SettingsRow {
      label: "Three-finger drag"
      description: "Move windows and select text by dragging with three fingers."
      ToggleSwitch {
        checked: Number(page.val("touchpad.drag_3fg")) > 0
        onToggled: page.set({ "touchpad.drag_3fg": checked ? 0 : 1 }, false)
      }
    }

    SettingsRow {
      label: "Scroll speed"
      SliderControl {
        from: 0.1; to: 2; step: 0.05; decimals: 2; suffix: "×"
        value: Number(page.val("touchpad.scroll_factor")) || 1
        onMoved: function(v) { page.set({ "touchpad.scroll_factor": v }, true) }
      }
    }
  }

  // ---- reset --------------------------------------------------------------
  SettingsSection {
    visible: page.hasOverrides
    SettingsRow {
      label: "Reset to Omarchy defaults"
      description: "Removes the settings made here. Your own lines in input.lua stay."
      Button {
        text: "Reset"
        bordered: true
        onClicked: page.app.confirm("Reset keyboard, mouse and touchpad settings made here?", "Reset", function() { page.resetAll() })
      }
    }
  }
}
