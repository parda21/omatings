import QtQuick
import "../../pages/shortcuts/ShortcutLogic.js" as L
import "../../Core/ManagedBlock.js" as MB

// Pure-function tests for pages/shortcuts/ShortcutLogic.js:
//   tools/check.sh tools/tests/ShortcutLogicTest.qml
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
    // modifiers / combos
    eq("modmask names", L.modmaskToNames(73), ["SUPER", "ALT", "SHIFT"])
    eq("names mask", L.namesToModmask(["SUPER", "shift", "CTRL"]), 69)
    eq("split", L.splitCombo("SUPER + SHIFT + code:10"), { modmask: 65, key: "code:10" })
    eq("split spaces", L.splitCombo("CTRL+ALT+DELETE"), { modmask: 12, key: "DELETE" })
    eq("combo string", L.comboString(65, "F"), "SUPER + SHIFT + F")
    eq("normalize", [L.normalizeKey("code:10"), L.normalizeKey("return"), L.normalizeKey("Enter"), L.normalizeKey("code:999")], ["1", "RETURN", "RETURN", "CODE:999"])
    eq("id equal code/digit", L.comboIdFromString("SUPER + 1") === L.comboIdFromString("SUPER + code:10"), true)
    eq("id ignores caps/numlock", L.comboId(64 | 16, "f") === L.comboId(64, "F"), true)
    eq("labels", [L.keyLabel("code:19"), L.keyLabel("mouse:272"), L.keyLabel("XF86AudioRaiseVolume"), L.keyLabel("RETURN"), L.keyLabel("f"), L.keyLabel("PRIOR")],
       ["0", "Left click", "Audio Raise Volume", "Enter", "F", "Page Up"])
    eq("combo label", L.comboLabel(65, "code:12"), "Super + Shift + 3")

    // hyprctl binds text
    var text = "bindled\n\tmodmask: 0\n\tsubmap: \n\tkey: XF86AudioRaiseVolume\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Volume up\n\tdispatcher: __lua\n\targ: 6\n\n"
      + "bindd\n\tmodmask: 64\n\tsubmap: \n\tkey: SUPER + code:10\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Switch to workspace 1\n\tdispatcher: __lua\n\targ: 71\n\n"
      + "bindmd\n\tmodmask: 64\n\tsubmap: \n\tkey: SUPER + mouse:272\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Move window\n\tdispatcher: __lua\n\targ: 90\n\n"
      + "bind\n\tmodmask: 64\n\tsubmap: \n\tkey: \n\tkeycode: 36\n\tcatchall: false\n\tdescription: \n\tdispatcher: exec\n\targ: foo, bar\n"
    var binds = L.parseBindsText(text)
    eq("binds count", binds.length, 4)
    eq("bind0", [binds[0].key, binds[0].modmask, binds[0].locked, binds[0].description, binds[0].combo], ["XF86AudioRaiseVolume", 0, true, "Volume up", "XF86AudioRaiseVolume"])
    eq("bind1 stripped key", [binds[1].key, binds[1].combo, binds[1].id], ["code:10", "SUPER + code:10", "64|1"])
    eq("bind2 mouse", binds[2].mouse, true)
    eq("bind3 keycode", [binds[3].key, binds[3].arg], ["code:36", "foo, bar"])

    // action cache
    var cache = L.parseActionCache("64,Switch to workspace 1,code:10\x1flua\x1fhl.dsp.focus({ workspace = \"1\" })\n"
      + "65,Browser, private,B\x1fexec\x1fomarchy-launch-browser --private\n")
    eq("cache lookup", L.lookupAction(cache, binds[1]), { kind: "lua", arg: "hl.dsp.focus({ workspace = \"1\" })" })
    eq("cache comma desc", L.lookupAction(cache, { modmask: 65, description: "Browser, private", key: "b" }), { kind: "exec", arg: "omarchy-launch-browser --private" })
    eq("action labels", [
      L.actionLabel({ kind: "exec", arg: "uwsm-app -- obsidian" }),
      L.actionLabel({ kind: "exec", arg: "omarchy-launch-or-focus '^obsidian$' 'uwsm-app -- obsidian'" }),
      L.actionLabel({ kind: "exec", arg: "omarchy-launch-webapp 'https://x.com/'" }),
      L.actionLabel(null)], ["obsidian", "obsidian", "https://x.com/", ""])

    // grouping + search
    binds.forEach(function(b) { b.action = L.lookupAction(cache, b) })
    var groups = L.groupBinds(binds, "")
    eq("groups", groups.map(function(g) { return g.title + ":" + g.items.length }), ["Windows:1", "Workspaces:1", "Media & hardware:1"])
    eq("search", L.groupBinds(binds, "workspace super").map(function(g) { return g.title }), ["Workspaces"])
    eq("search by action", L.groupBinds(binds, "hl.dsp.focus").length, 1)

    // conflicts
    eq("conflict digit", L.findConflicts(binds, 64, "code:10").length, 1)
    eq("conflict ignore", L.findConflicts(binds, 64, "code:10", ["64|1"]).length, 0)
    eq("no conflict", L.findConflicts(binds, 65, "code:10").length, 0)

    // managed block round trip
    var entries = [
      { kind: "disable", keys: "SUPER + SHIFT + M", was: "Music" },
      { kind: "bind", keys: "SUPER + F", description: "Files \"nautilus\"", action: "app", value: "org.gnome.Nautilus.desktop", replaces: true, was: "Full screen" },
      { kind: "bind", keys: "SUPER + SHIFT + code:10", description: "SSH", action: "command", value: "alacritty -e ssh \\host", replaces: false, was: "" }
    ]
    var body = L.renderEntries(entries)
    eq("render", body,
      "-- Disabled: Music\n"
      + "hl.unbind(\"SUPER + SHIFT + M\")\n"
      + "-- Replaces: Full screen\n"
      + "hl.unbind(\"SUPER + F\")\n"
      + "o.bind(\"SUPER + F\", \"Files \\\"nautilus\\\"\", { launch = \"org.gnome.Nautilus.desktop\" })\n"
      + "o.bind(\"SUPER + SHIFT + code:10\", \"SSH\", \"alacritty -e ssh \\\\host\")")
    eq("parse roundtrip", L.parseEntries(body), entries)
    var file = MB.replace("-- mine\nhl.unbind(\"SUPER + SHIFT + S\")\n", "bindings", body, "--")
    eq("block roundtrip", L.parseEntries(MB.read(file, "bindings", "--")), entries)
    eq("parse empty", L.parseEntries(""), [])
    eq("parse unbind without comment", L.parseEntries("hl.unbind(\"SUPER + X\")"), [{ kind: "disable", keys: "SUPER + X", was: "" }])

    // user combos
    var user = L.parseUserCombos("-- o.bind(\"SUPER + Q\", \"x\", \"y\")\nhl.unbind(\"SUPER + SHIFT + S\")\no.bind(\"SUPER + SHIFT + S\", \"Screenshot\", \"omarchy-capture-screenshot\")\n  o.bind(\"SUPER + code:11\", nil, \"x\")\n")
    eq("user combos", Object.keys(user).sort(), ["64|2", "65|S"])

    // key capture mapping
    eq("qt letter", L.qtKeyToHypr(0x46, 41, "f"), "F")
    eq("qt F5", L.qtKeyToHypr(0x01000034, 71, ""), "F5")
    eq("qt return", L.qtKeyToHypr(0x01000004, 36, "\r"), "RETURN")
    eq("qt space", L.qtKeyToHypr(0x20, 65, " "), "SPACE")
    eq("qt digit uses scancode", L.qtKeyToHypr(0x31, 10, "1"), "code:10")
    eq("qt shifted digit (!)", L.qtKeyToHypr(0x21, 10, "!"), "code:10")
    eq("qt digit no scancode", L.qtKeyToHypr(0x30, 0, "0"), "code:19")
    eq("qt comma no scancode", L.qtKeyToHypr(0x2c, 0, ","), "COMMA")
    eq("qt modifier only", [L.qtKeyToHypr(0x01000022, 133, ""), L.qtKeyToHypr(0x01000020, 50, "")], ["", ""])
    eq("qt volume", L.qtKeyToHypr(0x01000072, 123, ""), "XF86AudioRaiseVolume")
    eq("qt mods", L.qtModsToNames(0x10000000 | 0x02000000 | 0x04000000), ["SUPER", "CTRL", "SHIFT"])
    eq("needs modifier", [L.needsModifier("F"), L.needsModifier("F5"), L.needsModifier("XF86AudioMute"), L.needsModifier("code:10")], [true, false, false, true])

    // desktop entries
    eq("desktop", L.parseDesktopEntries(
      "/home/u/.local/share/applications/foo.desktop\tFoo Local\t\n"
      + "/home/u/.local/share/applications/hidden.desktop\tHidden\ttrue\n"
      + "/usr/share/applications/foo.desktop\tFoo System\t\n"
      + "/usr/share/applications/hidden.desktop\tHidden\t\n"
      + "/usr/share/applications/kde/bar.desktop\tBar\t\n"
      + "/usr/share/applications/noname.desktop\t\t\n"),
      [{ value: "kde-bar.desktop", label: "Bar", description: "kde-bar.desktop" }, { value: "foo.desktop", label: "Foo Local", description: "foo.desktop" }])

    console.log("ShortcutLogicTest: " + (failures === 0 ? "all passed" : failures + " failed"))
  }
}
