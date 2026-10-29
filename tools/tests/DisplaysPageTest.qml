import QtQuick
import "../../pages"
import "../../pages/displays/MonitorModel.js" as M

// Drive pages/DisplaysPage.qml headlessly with pending edits only:
//   OMATINGS_CHECK_WAIT=4000 tools/check.sh tools/tests/DisplaysPageTest.qml
// Never calls apply/keep/revert, brightness or night-light setters — those
// change the live session. configPath points at /tmp.
Item {
  id: root
  property var sys: null
  property var app: null
  property int failures: 0
  width: 800

  function check(name, cond, detail) {
    if (cond) console.log("pass:", name)
    else { failures++; console.log("OMATINGS_CHECK_FAIL", name, detail === undefined ? "" : JSON.stringify(detail)) }
  }

  DisplaysPage {
    id: p
    width: 800
    configPath: "/tmp/omatings-displays/monitors.lua"
  }

  function activated() {
    p.sys = sys
    p.app = app
    p.activated()
    later.start()
  }

  Timer {
    id: later
    interval: 1800
    onTriggered: {
      check("loaded", p.loaded && p.pending.length > 0, p.pending.length)
      check("not dirty after load", !p.dirty)
      check("something selected", p.selected !== null, p.selectedName)
      console.log("selected:", p.selectedName, "primary:", p.primaryName, "brightness:", JSON.stringify(p.brightnessLevels), "targets:", JSON.stringify(p.brightnessTargets),
                  "night light:", p.nightLight, "toggles:", JSON.stringify(p.activeToggles), "implicitHeight:", p.implicitHeight)

      var internal = p.pending.filter(function(m) { return m.internal })
      if (internal.length && internal[0].enabled) check("built-in brightness offered", p.brightnessTargets.indexOf(internal[0].name) === 0, p.brightnessTargets)
      if (internal.length) {
        p.select(internal[0].name)
        p.setScale("1.5")
        check("scale edit is pending", p.dirty && M.scaleValue(p.selected.scale) === "1.5", p.selected.scale)
        var rects = M.layoutRects(p.pending)
        var clean = true
        for (var i = 0; i < rects.length; i++) for (var j = i + 1; j < rects.length; j++) if (M.overlaps(rects[i], rects[j])) clean = false
        check("no overlaps after scale change", clean, rects)
        console.log("summary:", p.pendingSummary())
        console.log("live lua that Apply would run:\n" + M.liveLua(p.pending))
        p.makePrimary()
        check("make primary", p.primaryName === internal[0].name, p.primaryName)
        p.setRotation("1")
        check("rotation", p.selected.transform % 4 === 1)
        console.log("block that Keep would write:\n" + M.buildConfig("", p.pending).text)
        p.resetEdits()
        check("reset", !p.dirty)
      }
      console.log(root.failures === 0 ? "all display page tests passed" : root.failures + " display page test(s) failed")
    }
  }
}
