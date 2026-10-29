import QtQuick
import "../../pages"
import "../../Core/ManagedBlock.js" as MB
import "../../pages/input/InputLogic.js" as L

// Drives InputPage's write path against a temp file with liveApply off
// (no hyprctl eval/reload, nothing in ~/.config is touched):
//   OMATINGS_CHECK_WAIT=4000 tools/check.sh tools/tests/InputPageWriteTest.qml
Item {
  id: root
  property var sys: null
  property var app: null
  readonly property string tmp: "/tmp/omatings-input/input.lua"

  InputPage {
    id: page
    configPath: root.tmp
    liveApply: false
  }

  function activated() {
    var seed = "-- my own line\nhl.config({ input = { touchpad = { natural_scroll = true } } })\n"
    sys.sh("rm -rf /tmp/omatings-input; mkdir -p /tmp/omatings-input", [], function() {
      sys.writeFile(root.tmp, seed, function(ok) {
        page.app = root.app
        page.sys = root.sys
        page.activated()
        step1.start()
      })
    })
  }

  Timer {
    id: step1
    interval: 800
    onTriggered: {
      console.log("live loaded:", page.loaded, "layouts:", JSON.stringify(page.layouts), "touchpad:", page.touchpad, "kb:", JSON.stringify(page.kbModel))
      console.log("rules:", page.rules.layouts.length, "layouts")
      page.set({ repeat_rate: 33 }, false)
      page.set({ "touchpad.tap_to_click": false }, true)  // debounced
      page.setLayouts([{ layout: "de", variant: "" }, { layout: "us", variant: "intl" }])
      page.setKbOption("caps", "ctrl:nocaps")
      step2.start()
    }
  }

  Timer {
    id: step2
    interval: 1500
    onTriggered: {
      sys.readFile(root.tmp, function(text) {
        console.log("---- file ----\n" + text + "--------------")
        var cfg = L.parseConfig(MB.read(text, "input", "--"))
        var want = { input: { kb_layout: "de,us", kb_variant: ",intl", kb_options: "compose:caps,ctrl:nocaps,shift:both_capslock_cancel,grp:alts_toggle", repeat_rate: 33, touchpad: { tap_to_click: false } } }
        // kb_options depends on the live value; compare the rest strictly.
        var got = JSON.parse(JSON.stringify(cfg))
        if (got.input) delete got.input.kb_options
        delete want.input.kb_options
        if (JSON.stringify(got) !== JSON.stringify(want)) console.log("OMATINGS_CHECK_FAIL block mismatch: " + JSON.stringify(cfg))
        if (text.indexOf("-- my own line\nhl.config({ input = { touchpad = { natural_scroll = true } } })\n") !== 0) console.log("OMATINGS_CHECK_FAIL user lines changed")
        page.resetAll()
        step3.start()
      })
    }
  }

  Timer {
    id: step3
    interval: 700
    onTriggered: sys.readFile(root.tmp, function(text) {
      if (text.indexOf("omatings:input") !== -1) console.log("OMATINGS_CHECK_FAIL reset left the block")
      else console.log("reset ok")
    })
  }
}
