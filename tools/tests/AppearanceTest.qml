import QtQuick
import "../../pages/appearance/Appearance.js" as A

// Appearance page tests — never touch the live session:
//   OMATINGS_CHECK_WAIT=6000 tools/check.sh tools/tests/AppearanceTest.qml
//
// 1. Pure Lua generation / parsing (Appearance.js).
// 2. Loads AppearancePage with dryRun + a /tmp looknfeel path, reads the
//    live (read-only) state, then drives setLook/reset through the real
//    save path against the temp file.
Item {
  id: test

  property var sys: null
  property var app: null
  property var page: null
  property int failures: 0
  readonly property string dir: "/tmp/omatings-appearance"
  readonly property string path: dir + "/looknfeel.lua"
  readonly property string seed: "-- user stuff\nhl.config({ general = { layout = \"scrolling\" } })\n"

  function check(name, cond, detail) {
    if (cond) console.log("PASS", name)
    else { failures++; console.log("FAIL", name, detail === undefined ? "" : JSON.stringify(detail)) }
  }

  QtObject {
    id: testApp
    property var window: null
    function toast(text, isError) { console.log("[toast" + (isError ? ":error" : "") + "] " + text) }
    function confirm(message, confirmText, fn) { console.log("[confirm] " + message); fn() }
    function openPage(id) {}
  }

  function pureTests() {
    var line = A.optionLine("blur", true)
    check("optionLine nested", line === "hl.config({ decoration = { blur = { enabled = true } } })", line)
    check("optionLine int", A.optionLine("gaps_in", 7) === "hl.config({ general = { gaps_in = 7 } })", A.optionLine("gaps_in", 7))

    var ov = { rounding: 8, gaps_in: 3, blur: true, dim_strength: 0.153, animations: false }
    var body = A.renderBody(ov)
    console.log("body:\n" + body)
    var back = A.parseBody(body)
    check("roundtrip", JSON.stringify(back) === JSON.stringify({ gaps_in: 3, rounding: 8, blur: true, dim_strength: 0.15, animations: false }), back)
    check("order stable", body.split("\n")[0].indexOf("gaps_in") !== -1, body)

    var ev = A.evalLua({ gaps_in: 4, gaps_out: 9, blur: false, rounding: 99 })
    check("evalLua merged", ev === "hl.config({ general = { gaps_in = 4, gaps_out = 9 }, decoration = { rounding = 30, blur = { enabled = false } } })", ev)

    var text1 = A.applyOverrides(seed, { gaps_in: 2 })
    check("block appended", text1.indexOf(seed) === 0 && A.hasBlock(text1), text1)
    var text2 = A.applyOverrides(text1, { gaps_in: 6, shadow: true })
    check("block replaced", (text2.match(/>>> omatings:looknfeel/g) || []).length === 1 && A.readOverrides(text2).gaps_in === 6 && A.readOverrides(text2).shadow === true, text2)
    check("empty removes", A.applyOverrides(text2, {}) === seed, A.applyOverrides(text2, {}))
    check("removeBlock", A.removeBlock(text2) === seed, A.removeBlock(text2))
    check("foreign lines ignored", JSON.stringify(A.parseBody("hl.config({ general = { gaps_in = oops } })\nfoo")) === "{}")

    check("getoption css", A.parseGetOption("gaps_out", '{"option": "general:gaps_out", "css": "10 10 10 10", "set": true }') === 10)
    check("getoption int", A.parseGetOption("rounding", { int: 6 }) === 6)
    check("getoption bool", A.parseGetOption("blur", { bool: true }) === true)
    check("getoption float", A.parseGetOption("dim_strength", { float: 0.5 }) === 0.5)
    check("getoption bad", A.parseGetOption("rounding", "nope") === null)

    var ts = A.parseTextSize("text size: 12 (default) px\ngtk text-scaling-factor: 1.0\n")
    check("text size default", ts && ts.size === 12 && ts.isDefault, ts)
    ts = A.parseTextSize("text size: 16 px\n")
    check("text size custom", ts && ts.size === 16 && !ts.isDefault, ts)

    check("bg name", A.backgroundName("/x/3-sunset-lake.png") === "Sunset Lake", A.backgroundName("/x/3-sunset-lake.png"))
    check("fileUrl escapes", A.fileUrl("/a b/c#1.png") === "file:///a%20b/c%231.png", A.fileUrl("/a b/c#1.png"))

    var th = A.parseThemes("C\ttokyo-night\nT\ttokyo-night\tTokyo Night\tstock\t/p.png\n")
    check("parseThemes", th.current === "tokyo-night" && th.themes.length === 1 && th.themes[0].preview === "/p.png", th)
  }

  function activated() {
    pureTests()

    sys.sh('rm -rf "$1" && mkdir -p "$1" && printf "%s" "$2" > "$1/looknfeel.lua"', [dir, seed], function() {
      var c = Qt.createComponent("../../pages/AppearancePage.qml")
      if (c.status !== Component.Ready) { check("page loads", false, c.errorString()); return }
      page = c.createObject(test, { width: 900, looknfeelPath: test.path, dryRun: true })
      page.sys = sys
      page.app = testApp
      page.activated()
      stateTimer.start()
    })
  }

  Timer {
    id: stateTimer
    interval: 1500
    onTriggered: {
      console.log("themes:", page.themes.length, "current:", page.currentTheme, "extras:", page.hasExtraThemes)
      for (var i = 0; i < page.themes.length; i++) if (!page.themes[i].preview) console.log("  no preview:", page.themes[i].slug)
      console.log("backgrounds:", page.backgrounds.items.length, "current:", page.backgrounds.current)
      for (var j = 0; j < page.backgrounds.items.length; j++) {
        var b = page.backgrounds.items[j]
        console.log("  bg", b.name, A.isCurrentBackground(page.backgrounds, b) ? "*" : "", b.thumb ? "thumb" : "orig")
      }
      console.log("fonts:", page.fonts.length, "current:", page.currentFont)
      console.log("text size:", page.textSize, "default:", page.textSizeIsDefault)
      console.log("look:", JSON.stringify(page.look))
      console.log("overrides:", JSON.stringify(page.lookOverrides), "noGaps:", page.noGapsToggle)
      console.log("implicitHeight:", page.implicitHeight)
      check("themes found", page.themes.length > 0)
      check("current theme in list", page.themes.some(function(t) { return t.slug === page.currentTheme }))
      check("look read", typeof page.look.gaps_in === "number")
      check("tmp file has no block yet", !page.lookHasBlock)

      page.setLook("gaps_in", 7)
      page.setLook("blur", true)
      saveCheck.start()
    }
  }

  Timer {
    id: saveCheck
    interval: 1200
    onTriggered: {
      sys.readFile(test.path, function(text) {
        console.log("saved file:\n" + text)
        check("saved keeps user lines", text.indexOf(test.seed) === 0)
        var ov = A.readOverrides(text)
        check("saved only touched", JSON.stringify(ov) === JSON.stringify({ gaps_in: 7, blur: true }), ov)
        page.resetLook()
        resetCheck.start()
      })
    }
  }

  Timer {
    id: resetCheck
    interval: 800
    onTriggered: {
      sys.readFile(test.path, function(text) {
        check("reset removes block", text === test.seed, text)
        console.log(test.failures === 0 ? "ALL PASS" : "OMATINGS_CHECK_FAIL " + test.failures + " failures")
      })
    }
  }
}
