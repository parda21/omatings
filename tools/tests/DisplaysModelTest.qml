import QtQuick
import "../../pages/displays/MonitorModel.js" as M

// Exercise pages/displays/MonitorModel.js:
//   tools/check.sh tools/tests/DisplaysModelTest.qml
// Pure-function asserts on a fixture, then the persist path against the
// real ~/.config/hypr/monitors.lua (read-only) with the result written to
// /tmp/omatings-displays/monitors.lua and syntax-checked with luac.
// Never calls hyprctl eval / reload.
Item {
  property var sys: null
  property var app: null
  property int failures: 0

  function check(name, cond, detail) {
    if (cond) console.log("pass:", name)
    else { failures++; console.log("OMATINGS_CHECK_FAIL", name, detail === undefined ? "" : JSON.stringify(detail)) }
  }

  readonly property var fixture: [
    { id: 0, name: "eDP-1", description: "Samsung Display Corp. ATNA40HQ04-0", make: "Samsung Display Corp.", model: "ATNA40HQ04-0 ",
      width: 2880, height: 1800, physicalWidth: 300, physicalHeight: 190, refreshRate: 120.0, x: 3840, y: 180, scale: 2,
      transform: 0, vrr: true, disabled: false, mirrorOf: "none", availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz"] },
    { id: 1, name: "DP-1", description: "Samsung Electric Company C49HG9x H1AK500000", make: "Samsung Electric Company", model: "C49HG9x",
      width: 3840, height: 1080, physicalWidth: 1200, physicalHeight: 340, refreshRate: 119.974, x: 0, y: 0, scale: 1,
      transform: 0, vrr: false, disabled: false, mirrorOf: "none",
      availableModes: ["3840x1080@119.97Hz", "3840x2160@60.00Hz", "3840x2160@59.94Hz", "3840x1080@59.97Hz", "1920x1080@60.00Hz", "1920x1080@60.00Hz"] }
  ]

  readonly property string fixtureConfig: [
    "local omarchy_monitor_scale = \"auto\"",
    "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = omarchy_monitor_scale })",
    "hl.monitor({ output = \"eDP-1\", mode = \"2880x1800@120\", position = \"3840x180\", scale = 2 })",
    "hl.monitor({ output = \"desc:Samsung Electric Company C49HG9x H1AK500000\", mode = \"3840x1080@119.97\", position = \"0x0\", scale = 1, vrr = 2 })",
    "-- hl.monitor({ output = \"DP-2\", mode = \"2560x1440@144\", position = \"0x0\", scale = 1 })",
    "hl.monitor({ output = \"HDMI-A-1\", mode = \"preferred\", position = \"auto\", scale = 1 })",
    ""
  ].join("\n")

  function pureTests() {
    var mons = M.fromHyprctl(fixture, fixtureConfig)
    check("two monitors, internal first", mons.length === 2 && mons[0].name === "eDP-1", mons.map(function(m) { return m.name }))
    var edp = M.findMonitor(mons, "eDP-1"), dp = M.findMonitor(mons, "DP-1")
    check("refresh snapped to mode", dp.refresh === 119.97, dp.refresh)
    check("vrr read from config", dp.vrr === 2 && edp.vrr === -1, [dp.vrr, edp.vrr])
    check("modes deduped", dp.modes.length === 5, dp.modes.length)
    check("logical size eDP @2", JSON.stringify(M.logicalSize(edp)) === "{\"width\":1440,\"height\":900}", M.logicalSize(edp))
    var rot = JSON.parse(JSON.stringify(edp)); rot.transform = 1
    check("logical size rotated", JSON.stringify(M.logicalSize(rot)) === "{\"width\":900,\"height\":1440}", M.logicalSize(rot))
    check("identifier internal", M.identifierFor(edp, mons) === "eDP-1")
    check("identifier external", M.identifierFor(dp, mons) === "desc:Samsung Electric Company C49HG9x H1AK500000")
    check("valid scale 1.5 on 2880x1800", M.isValidScale(1.5, 2880, 1800))
    check("invalid scale 1.4 on 1920x1080", !M.isValidScale(1.4, 1920, 1080))
    check("nearest valid 1.4 on 1920x1080 is 4/3 (like Hyprland)", Math.abs(M.nearestValidScale(1.4, 1920, 1080) - 4 / 3) < 1e-9, M.nearestValidScale(1.4, 1920, 1080))
    var opts = M.scaleOptions({ width: 1366, height: 768, scale: 1, physicalWidth: 340, physicalHeight: 190 }).map(function(o) { return o.value })
    console.log("scale options 1366x768:", JSON.stringify(opts))
    check("1366x768 drops invalid 1.25", opts.indexOf("1.25") === -1 && opts.indexOf("2") >= 0, opts)
    console.log("scale options 2880x1800:", JSON.stringify(M.scaleOptions(edp).map(function(o) { return o.label })))
    check("auto scale eDP (high PPI) = 2", M.autoScale(edp) === 2, M.autoScale(edp))
    console.log("resolutions DP-1:", JSON.stringify(M.resolutionOptions(dp.modes, dp)))
    console.log("refresh DP-1 3840x2160:", JSON.stringify(M.refreshOptions(dp.modes, 3840, 2160, 0)))

    // snapping
    var others = [{ x: 0, y: 0, width: 3840, height: 1080 }]
    var r = M.dropRect({ name: "eDP-1", x: 3860, y: 200, width: 1440, height: 900 }, others, 40)
    check("snap flush right + bottom aligned", r.x === 3840 && r.y === 180, r)
    r = M.dropRect({ name: "eDP-1", x: 1000, y: 500, width: 1440, height: 900 }, others, 40)
    check("overlap resolved and attached", !M.overlapsAny(r, others) && M.touchesAny(r, others), r)
    r = M.dropRect({ name: "eDP-1", x: 9000, y: 3000, width: 1440, height: 900 }, others, 40)
    check("far away gets attached", M.touchesAny(r, others) && !M.overlapsAny(r, others), r)
    r = M.dropRect({ name: "eDP-1", x: 1190, y: 1100, width: 1440, height: 900 }, others, 40)
    check("snap below, centered", r.y === 1080 && r.x === 1200, r)

    // normalize / primary / settle
    var moved = JSON.parse(JSON.stringify(mons))
    M.findMonitor(moved, "eDP-1").x = -1440; M.findMonitor(moved, "eDP-1").y = 0
    var n = M.normalize(moved)
    check("normalize to 0,0", M.findMonitor(n, "eDP-1").x === 0 && M.findMonitor(n, "DP-1").x === 1440, n.map(function(m) { return [m.name, m.x, m.y] }))
    var p = M.makePrimary(mons, "eDP-1")
    check("make primary", M.primaryName(p) === "eDP-1" && M.findMonitor(p, "DP-1").x === 1440, p.map(function(m) { return [m.name, m.x, m.y] }))
    var grown = JSON.parse(JSON.stringify(mons))
    M.findMonitor(grown, "DP-1").scale = 0.75 // logical 5120 wide -> overlaps the laptop
    var s = M.settle(grown, "DP-1")
    var rs = M.layoutRects(s)
    check("settle removes overlap", !M.overlaps(rs[0], rs[1]) && M.touches(rs[0], rs[1]), rs)

    // lua
    var line = M.ruleLine(dp, mons, false)
    console.log("persist line:", line)
    check("persist line", line === "hl.monitor({ output = \"desc:Samsung Electric Company C49HG9x H1AK500000\", mode = \"3840x1080@119.97\", position = \"0x0\", scale = 1, transform = 0, vrr = 2 })", line)
    console.log("live lua:\n" + M.liveLua(mons))
    var off = JSON.parse(JSON.stringify(edp)); off.enabled = false
    check("disabled rule", M.ruleLine(off, mons, false) === "hl.monitor({ output = \"eDP-1\", disabled = true })")
    var mir = JSON.parse(JSON.stringify(mons)); M.findMonitor(mir, "DP-1").mirror = "eDP-1"
    check("mirror rule", M.ruleLine(M.findMonitor(mir, "DP-1"), mir, false).indexOf("mirror = \"eDP-1\"") > 0)
    var third = JSON.parse(JSON.stringify(edp)); third.scale = 4 / 3
    check("fractional scale written cleanly", M.ruleLine(third, mons, false).indexOf("scale = 1.333333") > 0, M.ruleLine(third, mons, false))

    // persist text
    var built = M.buildConfig(fixtureConfig, mons)
    console.log("built fixture config:\n" + built.text)
    check("user lines for connected outputs commented", built.commented.length === 2, built.commented)
    check("fallback rule untouched", built.text.indexOf("\nhl.monitor({ output = \"\", mode = \"preferred\"") >= 0)
    check("unrelated HDMI rule untouched", built.text.indexOf("\nhl.monitor({ output = \"HDMI-A-1\"") >= 0)
    // round trip: a second build is stable, and keeps rules of unplugged monitors
    var again = M.buildConfig(built.text, mons)
    check("idempotent", again.text === built.text && again.commented.length === 0)
    var onlyLaptop = [M.findMonitor(mons, "eDP-1")]
    var unplugged = M.buildConfig(built.text, onlyLaptop)
    check("keeps unplugged monitor rule", unplugged.kept === 1 && unplugged.text.indexOf("desc:Samsung Electric Company C49HG9x") > 0, unplugged.text)
    var replug = M.buildConfig(unplugged.text, mons)
    check("replug stable", replug.text === built.text, replug.text)
    check("dirty detection", !M.isDirty(mons, JSON.parse(JSON.stringify(mons))) && M.isDirty(mons, p))
    var lidOff = JSON.parse(JSON.stringify(mons)); M.findMonitor(lidOff, "eDP-1").enabled = false; M.findMonitor(lidOff, "eDP-1").x = 0; M.findMonitor(lidOff, "eDP-1").y = 0
    var ps = M.persistState(lidOff)
    var psr = M.layoutRects(ps)
    check("internal never persisted as disabled", M.findMonitor(ps, "eDP-1").enabled && !M.overlaps(psr[0], psr[1]) && M.touches(psr[0], psr[1]), ps.map(function(m) { return [m.name, m.enabled, m.x, m.y] }))
    check("internal off -> omarchy toggle", M.internalToggleAction(lidOff, false) === "off" && M.internalToggleAction(lidOff, true) === "" && M.internalToggleAction(mons, true) === "on" && M.internalToggleAction(mons, false) === "")
    console.log("change summary:", M.changeSummary(edp, M.findMonitor(p, "eDP-1"), p))
  }

  function activated() {
    pureTests()
    var out = "/tmp/omatings-displays/monitors.lua"
    sys.json(["hyprctl", "monitors", "all", "-j"], function(list) {
      sys.readFile(sys.hyprDir + "/monitors.lua", function(text) {
        var mons = M.fromHyprctl(list || [], text)
        console.log("live monitors:", JSON.stringify(mons.map(function(m) { return [m.name, M.identifierFor(m, mons), m.x, m.y, M.scaleValue(m.scale), m.vrr] })))
        var built = M.buildConfig(text, mons)
        console.log("commented user lines:", JSON.stringify(built.commented))
        sys.writeFile(out, built.text, function(ok) {
          check("wrote " + out, ok)
          sys.run(["luac", "-p", out], function(r) {
            check("generated config parses as Lua", r.code === 0, r.stderr)
            console.log("---- " + out + " ----\n" + built.text)
            console.log(failures === 0 ? "all display model tests passed" : failures + " display model test(s) failed")
          })
        })
      })
    })
  }
}
