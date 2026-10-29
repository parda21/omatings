import QtQuick
import "../../pages/input/InputLogic.js" as L
import "../../Core/ManagedBlock.js" as MB

// Pure-function tests for pages/input/InputLogic.js:
//   tools/check.sh tools/tests/InputLogicTest.qml
Item {
  property var sys: null
  property var app: null
  property int failures: 0

  function canon(v) {
    if (Array.isArray(v)) return v.map(canon)
    if (v && typeof v === "object") {
      var out = ({})
      Object.keys(v).sort().forEach(function(k) { out[k] = canon(v[k]) })
      return out
    }
    return v
  }

  function eq(name, got, want) {
    var g = JSON.stringify(canon(got)), w = JSON.stringify(canon(want))
    if (g !== w) { failures++; console.log("OMATINGS_CHECK_FAIL " + name + "\n  got:  " + g + "\n  want: " + w) }
  }

  function activated() {
    // live options
    var live = L.parseLiveOptions(
      '{"option": "input:kb_layout", "str": "de", "set": true }\n'
      + '{"option": "input:accel_profile", "str": "[[EMPTY]]", "set": false }\n'
      + '{"option": "input:touchpad:tap-to-click", "bool": true, "set": false }\n'
      + '{"option": "input:sensitivity", "float": 0.350000, "set": true }\n'
      + 'garbage\n'
      + '{"option": "input:repeat_rate", "int": 40, "set": true }\n')
    eq("live", live, { kb_layout: "de", accel_profile: "", "touchpad.tap_to_click": true, sensitivity: 0.35, repeat_rate: 40 })

    // render + parse roundtrip
    var cfg = L.setPath({}, "input.repeat_rate", 30)
    cfg = L.setPath(cfg, "input.touchpad.tap_to_click", false)
    cfg = L.setPath(cfg, "input.kb_layout", "de,us")
    cfg = L.setPath(cfg, "input.kb_options", "compose:caps,\"odd\"")
    cfg = L.setPath(cfg, "input.sensitivity", -0.25)
    var lua = L.renderConfig(cfg)
    eq("render", lua, 'hl.config({\n  input = {\n    kb_layout = "de,us",\n    kb_options = "compose:caps,\\"odd\\"",\n    repeat_rate = 30,\n    sensitivity = -0.25,\n    touchpad = {\n      tap_to_click = false,\n    },\n  },\n})')
    eq("parse roundtrip", L.parseConfig(lua), cfg)
    eq("parse hand edit", L.parseConfig("-- note\nhl.config({ input = { [\"kb_layout\"] = 'us'; repeat_rate=25 } })"), { input: { kb_layout: "us", repeat_rate: 25 } })
    eq("parse garbage", L.parseConfig("hl.config({ input = { x = os.getenv('A') } })"), {})
    eq("parse none", L.parseConfig(""), {})

    // setPath removal prunes empty tables
    eq("remove", L.setPath(L.setPath({}, "input.touchpad.natural_scroll", true), "input.touchpad.natural_scroll", undefined), {})
    eq("render empty", L.renderConfig({}), "")

    // live lua
    eq("liveLua", L.liveLua("touchpad.natural_scroll", true), "hl.config({ input = { touchpad = { natural_scroll = true } } })")
    eq("liveLuaMany", L.liveLuaMany({ repeat_rate: 30, repeat_delay: 200 }), "hl.config({ input = { repeat_rate = 30, repeat_delay = 200 } })")

    // managed block integration
    var file = "-- user\nhl.config({ input = { touchpad = { natural_scroll = true } } })\n"
    var written = MB.replace(file, "input", lua, "--")
    eq("block read back", L.parseConfig(MB.read(written, "input", "--")), cfg)
    eq("user lines kept", written.indexOf(file) === 0, true)

    // layouts
    eq("layouts", L.parseLayouts("de,us", ",intl"), [{ layout: "de", variant: "" }, { layout: "us", variant: "intl" }])
    eq("layouts short variant", L.parseLayouts("de,us", ""), [{ layout: "de", variant: "" }, { layout: "us", variant: "" }])
    eq("join", L.joinLayouts([{ layout: "de", variant: "" }, { layout: "us", variant: "intl" }]), { kb_layout: "de,us", kb_variant: ",intl" })
    eq("join no variants", L.joinLayouts([{ layout: "de", variant: "" }]), { kb_layout: "de", kb_variant: "" })
    eq("move", L.moveItem(["a", "b", "c"], 2, 0), ["c", "a", "b"])
    eq("nonlatin", [L.isNonLatin("ru"), L.isNonLatin("de")], [true, false])

    // xkb rules
    var rules = L.parseXkbRules("! model\n  pc105 Generic\n\n! layout\n  us              English (US)\n  de              German\n\n! variant\n  intl            us: English (US, intl., with dead keys)\n  nodeadkeys      de: German (no dead keys)\n\n! option\n  grp                  Switching\n")
    eq("rules layouts", rules.layouts, [{ value: "us", label: "English (US)", description: "us" }, { value: "de", label: "German", description: "de" }].sort(function(a, b) { return a.label.localeCompare(b.label) }))
    eq("rules variants", rules.variants, { us: [{ value: "intl", label: "English (US, intl., with dead keys)" }], de: [{ value: "nodeadkeys", label: "German (no dead keys)" }] })
    eq("layoutLabel", [L.layoutLabel(rules, "de", ""), L.layoutLabel(rules, "us", "intl"), L.layoutLabel(rules, "xx", "y")], ["German", "English (US, intl., with dead keys)", "xx (y)"])

    // kb_options
    var m = L.parseKbOptions("compose:caps,shift:both_capslock_cancel,grp:alts_toggle,lv3:ralt_switch")
    eq("kbopts parse", m, { caps: "", compose: "compose:caps", layoutSwitch: "grp:alts_toggle", bothShifts: true, other: ["lv3:ralt_switch"] })
    eq("kbopts build", L.buildKbOptions(m), "compose:caps,shift:both_capslock_cancel,grp:alts_toggle,lv3:ralt_switch")
    eq("kbopts caps->ctrl", L.withKbOption(L.withKbOption("compose:caps,shift:both_capslock_cancel", "compose", "compose:ralt"), "caps", "ctrl:nocaps"), "compose:ralt,ctrl:nocaps,shift:both_capslock_cancel")
    eq("kbopts compose wins caps", L.buildKbOptions({ caps: "caps:escape", compose: "compose:caps", layoutSwitch: "", bothShifts: false, other: [] }), "compose:caps")
    eq("kbopts empty", L.parseKbOptions(""), { caps: "", compose: "", layoutSwitch: "", bothShifts: false, other: [] })

    // devices
    var dev = { mice: [{ name: "img4100:00-4d49:4158-mouse" }, { name: "img4100:00-4d49:4158-touchpad" }, { name: "logitech-mx-master-3s" }] }
    eq("touchpad", L.findTouchpad(dev), "img4100:00-4d49:4158-touchpad")
    eq("mice", L.mice(dev), ["img4100:00-4d49:4158-mouse", "logitech-mx-master-3s"])
    eq("no touchpad", L.findTouchpad({ mice: [] }), "")

    console.log("InputLogicTest: " + (failures === 0 ? "all passed" : failures + " failed"))
  }
}
