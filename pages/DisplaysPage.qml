import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "displays"
import "displays/MonitorModel.js" as M

// Displays: arrangement, mode, scale, rotation, VRR, mirroring, brightness
// and night light.
//
// Flow (like GNOME): edits are pending until "Apply". Apply runs the new
// layout live with `hyprctl eval 'hl.monitor(...)'`, then asks "Keep these
// display settings?" for 15 s. Revert (or the timeout) re-applies the
// previous live state; Keep writes the managed "monitors" block into
// `configPath` and reloads Hyprland.
//
// Persisting: see MonitorModel.buildConfig. In short, the block holds one
// full hl.monitor line per connected display (desc:<description> for
// externals, port name for the built-in panel), keeps lines of displays that
// aren't plugged in, and comments out the user's own single-line rules for
// the same outputs with "-- [omatings] " (Hyprland would let the block win
// anyway — later rules take precedence — but Omarchy's clamshell helper
// reads the first rule for the laptop panel, and a dead line above is a trap
// when hand-editing). The generic `output = ""` fallback is never touched.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // Where the managed block lives. Tests point this at /tmp.
  property string configPath: Quickshell.env("HOME") + "/.config/hypr/monitors.lua"
  property int keepSeconds: 15

  // ---- state --------------------------------------------------------------
  property var live: []            // as Hyprland runs it right now
  property var pending: []         // as edited on this page
  property var monitorNames: []    // stable list for the canvas Repeater
  property string selectedName: ""
  property bool loaded: false
  property bool loading: false
  property bool busy: false
  property var revertState: null   // live state before Apply, while asking to keep
  property var appliedState: null  // what Apply set live
  property int countdown: 0
  property var activeToggles: []   // Omarchy laptop-display toggles that override this page
  property string _selectAfterRefresh: ""

  readonly property bool confirming: revertState !== null
  readonly property bool dirty: loaded && M.isDirty(live, pending)
  readonly property var selected: M.findMonitor(pending, selectedName)
  readonly property var selectedLive: M.findMonitor(live, selectedName)
  readonly property string primaryName: M.primaryName(pending)
  readonly property int enabledCount: pending.filter(function(m) { return m.enabled }).length

  // brightness / night light
  // Brightness per display name (only displays that report one). The
  // built-in panel is always offered; an external one when it is selected
  // and answers over DDC.
  property var brightnessLevels: ({})
  property bool brightnessBusy: false
  property var brightnessQueued: null
  readonly property string internalName: {
    for (var i = 0; i < live.length; i++) if (live[i].internal && live[i].enabled) return live[i].name
    return ""
  }
  readonly property var brightnessTargets: {
    var out = []
    if (internalName !== "" && brightnessLevels[internalName] !== undefined) out.push(internalName)
    if (selectedName !== internalName && brightnessLevels[selectedName] !== undefined) out.push(selectedName)
    return out
  }
  property bool nightLight: false
  property bool nightLightBusy: false

  spacing: Style.spacing.huge

  function activated() {
    if (!sys) return
    refresh("")
    refreshNightLight()
  }

  // ---- loading ------------------------------------------------------------
  function refresh(selectName) {
    if (!sys) return
    if (selectName) _selectAfterRefresh = selectName
    loading = true
    sys.json(["hyprctl", "monitors", "all", "-j"], function(list, r) {
      if (!list) {
        loading = false
        if (app) app.toast("Could not read displays: " + String(r.stderr || r.stdout).trim(), true)
        return
      }
      sys.readFile(page.configPath, function(text) {
        loading = false
        page.adopt(M.fromHyprctl(list, text))
      })
    })
    sys.sh("d=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr\"; for f in internal-monitor-disable internal-monitor-mirror internal-monitor-clamshell; do [ -f \"$d/$f.lua\" ] && echo \"$f\"; done; exit 0",
      [], function(r) {
        page.activeToggles = String(r.stdout || "").split("\n").filter(function(s) { return s !== "" })
      })
  }

  function adopt(mons) {
    var oldNames = monitorNames.slice().sort().join(",")
    var names = mons.map(function(m) { return m.name })
    var sameSet = names.slice().sort().join(",") === oldNames
    var hadEdits = dirty && !confirming

    live = mons
    if (!(hadEdits && sameSet)) pending = M.clone(mons)
    if (hadEdits && !sameSet && app) app.toast("Displays changed, so unapplied edits were reset", false)
    if (!sameSet || names.length !== monitorNames.length) monitorNames = names
    loaded = true

    var want = _selectAfterRefresh
    _selectAfterRefresh = ""
    if (want && oldNames !== "" && oldNames.split(",").indexOf(want) < 0 && M.findMonitor(mons, want) && app)
      app.toast(M.displayName(M.findMonitor(mons, want)) + " connected (" + want + ")", false)
    if (want && M.findMonitor(mons, want)) select(want)
    else if (!M.findMonitor(mons, selectedName)) {
      var focused = mons.filter(function(m) { return m.focused })
      select(focused.length ? focused[0].name : (mons.length ? mons[0].name : ""))
    }
    refreshBrightness(internalName)
    if (selectedName !== internalName) refreshBrightness(selectedName)
  }

  function select(name) {
    if (selectedName === name) return
    selectedName = name
    if (name !== internalName && brightnessLevels[name] === undefined) refreshBrightness(name)
  }

  // Hotplug: refresh and select the new display.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name !== "monitoradded" && name !== "monitoraddedv2" && name !== "monitorremoved" && name !== "monitorremovedv2") return
      var data = String(event.data || "")
      if (name === "monitoraddedv2") page._selectAfterRefresh = data.split(",")[1] || ""
      else if (name === "monitoradded") page._selectAfterRefresh = data
      hotplugTimer.restart()
    }
  }

  Timer {
    id: hotplugTimer
    interval: 600
    onTriggered: page.refresh(page._selectAfterRefresh)
  }

  // ---- editing (pending only) --------------------------------------------
  function edit(name, fn, relayout) {
    if (confirming) return
    var next = M.clone(pending)
    var m = M.findMonitor(next, name)
    if (!m) return
    fn(m, next)
    pending = relayout === false ? next : M.settle(next, name)
  }

  function moveTo(name, x, y) {
    edit(name, function(m) { m.x = x; m.y = y })
  }

  function setResolution(value) {
    var mode = M.parseMode(value)
    if (!mode) return
    edit(selectedName, function(m) {
      var keep = M.closestRefresh(m.modes, mode.width, mode.height, m.refresh)
      var best = M.bestRefresh(m.modes, mode.width, mode.height)
      m.width = mode.width
      m.height = mode.height
      m.refresh = Math.abs(keep - m.refresh) < 1 ? keep : (best || m.refresh)
      if (m.scale !== "auto" && !M.isValidScale(m.scale, m.width, m.height)) m.scale = M.nearestValidScale(m.scale, m.width, m.height)
    })
  }

  function setRefresh(value) {
    edit(selectedName, function(m) { m.refresh = Number(value) }, false)
  }

  function setScale(value) {
    edit(selectedName, function(m) { m.scale = M.parseScaleValue(value) })
  }

  function setRotation(value) {
    edit(selectedName, function(m) { m.transform = M.withRotation(m.transform, Number(value)) })
  }

  function setVrr(value) {
    edit(selectedName, function(m) { m.vrr = Number(value) }, false)
  }

  function setEnabled(on) {
    if (!on && enabledCount <= 1 && selected && selected.enabled) {
      if (app) app.toast("At least one display has to stay on", true)
      return
    }
    edit(selectedName, function(m, all) {
      m.enabled = on
      if (on) {
        // Turn on to the right of the current arrangement.
        var b = M.bounds(M.layoutRects(all, m.name))
        m.x = b.x + b.width
        m.y = b.y
        m.mirror = ""
      } else {
        // Displays that mirrored this one go back into the arrangement.
        for (var i = 0; i < all.length; i++) if (all[i].mirror === m.name) all[i].mirror = ""
      }
    })
  }

  function setMirror(value) {
    edit(selectedName, function(m, all) {
      m.mirror = value
      if (value) {
        // Hyprland can't mirror a mirror: re-point anything that mirrored us.
        for (var i = 0; i < all.length; i++) if (all[i].mirror === m.name) all[i].mirror = value
      } else {
        var b = M.bounds(M.layoutRects(all, m.name))
        m.x = b.x + b.width
        m.y = b.y
      }
    })
  }

  function makePrimary() {
    if (confirming || !selected) return
    pending = M.makePrimary(pending, selectedName)
  }

  function resetEdits() {
    pending = M.clone(live)
  }

  // ---- apply / keep / revert ---------------------------------------------
  function apply() {
    if (!sys || busy || confirming || !dirty) return
    var before = M.clone(live)
    var target = M.clone(pending)
    busy = true
    sys.hyprEval(M.liveLua(target), function(r) {
      busy = false
      var out = String(r.stdout || "").trim()
      if (r.code !== 0 || (out !== "" && out !== "ok")) {
        if (app) app.toast("Could not apply display settings: " + (String(r.stderr || "").trim() || out), true)
        page.restore(before, "")
        return
      }
      page.revertState = before
      page.appliedState = target
      page.countdown = page.keepSeconds
      countdownTimer.restart()
      settleTimer.restart()
    })
  }

  function revert(reason) {
    if (!confirming) return
    countdownTimer.stop()
    var before = revertState
    revertState = null
    appliedState = null
    restore(before, reason || "Display settings reverted")
  }

  function restore(state, message) {
    busy = true
    pending = M.clone(state)
    sys.hyprEval(M.liveLua(state), function(r) {
      busy = false
      var out = String(r.stdout || "").trim()
      if (r.code !== 0 || (out !== "" && out !== "ok")) {
        if (app) app.toast("Could not restore the previous display settings: " + (String(r.stderr || "").trim() || out), true)
      } else if (message && app) {
        app.toast(message, false)
      }
      settleTimer.restart()
    })
  }

  function keep() {
    if (!confirming) return
    countdownTimer.stop()
    var state = appliedState
    revertState = null
    appliedState = null
    persist(state)
  }

  function persist(state) {
    if (!sys) return
    busy = true
    var toggle = M.internalToggleAction(state, activeToggles.indexOf("internal-monitor-disable") >= 0)
    sys.readFile(configPath, function(text) {
      var built = M.buildConfig(text, M.persistState(state))
      sys.writeFile(page.configPath, built.text, function(ok, r) {
        if (!ok) {
          busy = false
          if (app) app.toast("Could not save " + page.configPath + ": " + String(r.stderr || "").trim(), true)
          return
        }
        // Toggle first (it reloads too), so the panel doesn't flash on
        // between writing the file and switching it off.
        page.runInternalToggle(toggle, function() {
          sys.hyprReload(function(errors) {
            busy = false
            if (errors) {
              if (app) app.toast("Saved, but Hyprland reports config errors:\n" + errors, true)
            } else if (app) {
              var msg = "Display settings saved"
              if (built.commented.length)
                msg += ". " + built.commented.length + " of your own hl.monitor lines in monitors.lua now start with \"-- [omatings]\" (a backup was made)"
              app.toast(msg, false)
            }
            settleTimer.restart()
          })
        })
      })
    })
  }

  // The laptop panel is switched off/on through Omarchy's toggle, which
  // turns it back on by itself when no external display is left.
  function runInternalToggle(action, done) {
    if (!action) { done(); return }
    sys.run(["omarchy", "hyprland", "monitor", "internal", action], function(r) {
      if (r.code !== 0 && app)
        app.toast("Could not turn the built-in display " + action + ": " + String(r.stderr || r.stdout || "").trim(), true)
      done()
    })
  }

  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    onTriggered: {
      page.countdown -= 1
      if (page.countdown <= 0) page.revert("No answer, so the previous display settings are back")
    }
  }

  // Hyprland applies monitor rules on its next tick; read back a bit later.
  Timer {
    id: settleTimer
    interval: 700
    onTriggered: page.refresh(page.selectedName)
  }

  // ---- brightness / night light ------------------------------------------
  function _setLevel(name, value) {
    var next = ({})
    for (var k in brightnessLevels) next[k] = brightnessLevels[k]
    if (value === undefined) delete next[name]
    else next[name] = value
    brightnessLevels = next
  }

  // Read-only: `omarchy brightness display --monitor NAME` prints a percent
  // (backlight for the panel, DDC/Apple for externals) or fails.
  function refreshBrightness(name) {
    if (!sys || !name) return
    var m = M.findMonitor(live, name)
    if (!m || !m.enabled) return
    sys.run(["omarchy", "brightness", "display", "--monitor", name], function(r) {
      var v = parseInt(String(r.stdout || "").trim(), 10)
      page._setLevel(name, (r.code === 0 && isFinite(v)) ? Math.max(0, Math.min(100, v)) : undefined)
    })
  }

  function setBrightness(name, value) {
    if (!sys || !name) return
    var pct = Math.max(1, Math.min(100, Math.round(value)))
    _setLevel(name, pct)
    if (brightnessBusy) { brightnessQueued = { name: name, value: pct }; return }
    brightnessBusy = true
    brightnessQueued = null
    sys.run(["omarchy", "brightness", "display", "--no-osd", "--monitor", name, pct + "%"], function(r) {
      page.brightnessBusy = false
      if (r.code !== 0 && app) app.toast("Could not set brightness: " + String(r.stderr || r.stdout || "").trim(), true)
      var q = page.brightnessQueued
      if (q) page.setBrightness(q.name, q.value)
    })
  }

  function refreshNightLight() {
    if (!sys) return
    sys.json(["omarchy", "toggle", "nightlight", "--status"], function(data) {
      page.nightLight = !!(data && data.enabled)
    })
  }

  function toggleNightLight() {
    if (!sys || nightLightBusy) return
    nightLightBusy = true
    var want = !nightLight
    nightLight = want
    // Output goes to /dev/null: the toggle may start hyprsunset in the
    // background, which would otherwise keep our stdout pipe open forever.
    sys.sh("omarchy toggle nightlight >/dev/null 2>&1 </dev/null", [], function(r) {
      page.nightLightBusy = false
      if (r.code !== 0 && app) app.toast("Could not toggle night light (exit code " + r.code + ")", true)
      page.refreshNightLight()
    })
  }

  // ---- helpers for the UI --------------------------------------------------
  function mirrorOptions() {
    var out = [{ value: "", label: "Don't mirror" }]
    if (!selected) return out
    for (var i = 0; i < pending.length; i++) {
      var m = pending[i]
      if (m.name === selectedName || !m.enabled || m.mirror) continue
      out.push({ value: m.name, label: M.displayName(m) + " (" + m.name + ")" })
    }
    return out
  }

  function pendingSummary() {
    var parts = []
    for (var i = 0; i < pending.length; i++) {
      var s = M.changeSummary(M.findMonitor(live, pending[i].name), pending[i], pending)
      if (s) parts.push(pending[i].name + ": " + s)
    }
    return parts.join("   ")
  }

  // ======================================================================
  // UI
  // ======================================================================

  // Omarchy's own laptop-display modes load after monitors.lua and win.
  // (internal-monitor-disable is what this page uses itself to turn the
  // panel off, so it shows up as the switch, not as a warning.)
  readonly property var overridingToggles: activeToggles.filter(function(t) { return t !== "internal-monitor-disable" })

  BorderSurface {
    Layout.fillWidth: true
    visible: page.overridingToggles.length > 0
    implicitHeight: toggleNote.implicitHeight + Style.spacing.lg * 2
    color: Util.alpha(Commons.Color.urgent, 0.08)
    radius: Style.cornerRadius
    borderSpec: Border.flat(Util.alpha(Commons.Color.urgent, 0.5), 1)

    Text {
      id: toggleNote
      anchors.fill: parent
      anchors.margins: Style.spacing.lg
      text: (page.overridingToggles.indexOf("internal-monitor-clamshell") >= 0
              ? "The lid is closed, so Omarchy keeps the built-in display off. "
              : "Omarchy is mirroring the built-in display (Omarchy menu → Display). ")
        + "That overrides the built-in display settings here until it ends."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  SettingsSection {
    title: "Arrangement"
    description: "Drag displays to match how they sit on your desk. Click one to change its settings below."

    Text {
      visible: page.loaded && page.pending.length === 0
      text: page.loading ? "Looking for displays…" : "No displays found."
      color: Util.alpha(Commons.Color.foreground, 0.7)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    ArrangementCanvas {
      Layout.fillWidth: true
      visible: page.pending.length > 0
      monitors: page.pending
      names: page.monitorNames
      selectedName: page.selectedName
      primaryName: page.primaryName
      interactive: !page.confirming && !page.busy
      onSelected: function(name) { page.select(name) }
      onDropped: function(name, x, y) { page.moveTo(name, x, y) }
    }

    // Apply / reset row
    RowLayout {
      Layout.fillWidth: true
      visible: !page.confirming
      spacing: Style.spacing.lg

      Text {
        Layout.fillWidth: true
        text: page.busy ? "Applying…" : (page.dirty ? page.pendingSummary() : "No unapplied changes")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: page.dirty ? Commons.Color.foreground : Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        text: "Reset"
        bordered: true
        enabled: page.dirty && !page.busy
        opacity: enabled ? 1 : 0.4
        onClicked: page.resetEdits()
      }
      Button {
        text: "Apply"
        iconText: String.fromCodePoint(0xF012C)
        bordered: true
        selected: page.dirty
        enabled: page.dirty && !page.busy
        opacity: enabled ? 1 : 0.4
        onClicked: page.apply()
      }
    }

    // Keep these settings? (shown after Apply)
    BorderSurface {
      Layout.fillWidth: true
      visible: page.confirming
      implicitHeight: keepRow.implicitHeight + Style.spacing.lg * 2
      color: Util.alpha(Commons.Color.accent, 0.10)
      radius: Style.cornerRadius
      borderSpec: Border.flat(Commons.Color.accent, Math.max(1, Style.normalBorderWidth))

      RowLayout {
        id: keepRow
        anchors.fill: parent
        anchors.margins: Style.spacing.lg
        spacing: Style.spacing.lg

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xxs
          Text {
            text: "Keep these display settings?"
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: "Reverting in " + page.countdown + " s"
            textFormat: Text.PlainText
            color: Util.alpha(Commons.Color.foreground, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Button {
          text: "Revert"
          bordered: true
          enabled: !page.busy
          onClicked: page.revert("")
        }
        Button {
          text: "Keep changes"
          bordered: true
          selected: true
          enabled: !page.busy
          onClicked: page.keep()
        }
      }
    }
  }

  SettingsSection {
    visible: page.selected !== null
    title: page.selected ? M.displayName(page.selected) + " · " + page.selected.name : ""
    description: page.selected ? (page.selected.internal ? "Laptop panel" : page.selected.description) : ""

    SettingsRow {
      label: "Use this display"
      description: page.selected && page.selected.internal
        ? "Turns the laptop screen off while another display is connected. It comes back on by itself when you unplug."
        : "Turning a display off moves its windows and workspaces to the others."
      ToggleSwitch {
        checked: page.selected ? page.selected.enabled : false
        interactive: !page.confirming
        onToggled: page.setEnabled(!(page.selected && page.selected.enabled))
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled && !page.selected.mirror)
      label: "Primary display"
      description: page.primaryName === page.selectedName
        ? "This display is at the top-left (0×0). Hyprland has no real primary display; apps and X11 games treat the one at 0×0 as the main screen."
        : "Moves this display to the top-left (0×0) and lines up the others to its right. Apps and X11 games treat the display at 0×0 as the main screen."
      Button {
        text: page.primaryName === page.selectedName ? "Primary" : "Make primary"
        iconText: String.fromCodePoint(0xF005)
        bordered: true
        selected: page.primaryName === page.selectedName
        enabled: page.primaryName !== page.selectedName && !page.confirming
        onClicked: page.makePrimary()
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled)
      label: "Resolution"
      PickDropdown {
        width: Style.spacing.dropdownWidth
        options: page.selected ? M.resolutionOptions(page.selected.modes, page.selected) : []
        current: page.selected ? M.resolutionKey(page.selected.width, page.selected.height) : ""
        enabled: !page.confirming
        onPicked: function(v) { page.setResolution(v) }
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled)
      label: "Refresh rate"
      PickDropdown {
        width: Style.spacing.dropdownWidth
        options: page.selected ? M.refreshOptions(page.selected.modes, page.selected.width, page.selected.height, page.selected.refresh) : []
        current: page.selected ? M.refreshValue(page.selected.refresh) : ""
        enabled: !page.confirming
        onPicked: function(v) { page.setRefresh(v) }
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled)
      label: "Scale"
      description: page.selected
        ? "Makes text and windows bigger. Only sizes that divide " + page.selected.width + "×" + page.selected.height + " into whole pixels are offered; looks like "
          + M.logicalSize(page.selected).width + "×" + M.logicalSize(page.selected).height + "."
        : ""
      PickDropdown {
        width: Style.spacing.dropdownWidth
        options: page.selected ? M.scaleOptions(page.selected) : []
        current: page.selected ? M.scaleValue(page.selected.scale) : ""
        enabled: !page.confirming
        onPicked: function(v) { page.setScale(v) }
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled)
      label: "Rotation"
      ButtonGroup {
        options: [
          { value: "0", label: "Normal" },
          { value: "1", label: "90°" },
          { value: "2", label: "180°" },
          { value: "3", label: "270°" }
        ]
        value: page.selected ? String(M.rotationOf(page.selected.transform)) : "0"
        enabled: !page.confirming
        onChanged: function(v) { page.setRotation(v) }
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled)
      label: "Variable refresh rate"
      description: "Adaptive sync. Smoother games and video; switch to fullscreen only if the display flickers."
        + (page.selectedLive && page.selectedLive.vrrActive ? " Active right now." : "")
      PickDropdown {
        width: Style.spacing.dropdownWidth
        options: [
          { value: "-1", label: "System default" },
          { value: "0", label: "Off" },
          { value: "1", label: "On" },
          { value: "2", label: "Fullscreen only" },
          { value: "3", label: "Fullscreen games & video" }
        ]
        current: page.selected ? String(page.selected.vrr) : "-1"
        enabled: !page.confirming
        onPicked: function(v) { page.setVrr(v) }
      }
    }

    SettingsRow {
      visible: !!(page.selected && page.selected.enabled && page.pending.length > 1)
      label: "Mirror"
      description: "Show the same picture as another display. It keeps that display's resolution, so the image may be stretched."
      PickDropdown {
        width: Style.spacing.dropdownWidth
        options: page.selected ? page.mirrorOptions() : []
        current: page.selected ? page.selected.mirror : ""
        enabled: !page.confirming
        onPicked: function(v) { page.setMirror(v) }
      }
    }
  }

  SettingsSection {
    title: "Brightness & night light"

    Repeater {
      model: page.brightnessTargets

      SettingsRow {
        id: brightnessRow
        required property string modelData
        readonly property var mon: M.findMonitor(page.live, modelData)
        stacked: true
        label: "Brightness · " + (mon ? M.displayName(mon) : modelData)

        RowLayout {
          width: parent.width
          spacing: Style.spacing.lg
          PanelSlider {
            id: brightnessSlider
            bar: null
            Layout.fillWidth: true
            trackColor: Style.selectedFillFor(Commons.Color.foreground, Commons.Color.accent)
            minimum: 1
            maximum: 100
            step: 1
            integer: true
            value: Math.max(1, page.brightnessLevels[brightnessRow.modelData] || 1)
            onMoved: function(v) { brightnessDebounce.value = v; brightnessDebounce.restart() }
            onReleased: function(v) { brightnessDebounce.stop(); page.setBrightness(brightnessRow.modelData, v) }
          }
          Text {
            Layout.preferredWidth: Style.space(44)
            horizontalAlignment: Text.AlignRight
            text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : (page.brightnessLevels[brightnessRow.modelData] || 0)) + "%"
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Timer {
          id: brightnessDebounce
          interval: 180
          property real value: 0
          onTriggered: page.setBrightness(brightnessRow.modelData, value)
        }
      }
    }

    SettingsRow {
      visible: page.brightnessTargets.length === 0
      label: "Brightness"
      description: "None of the connected displays can change brightness from here. Use the display's own buttons."
    }

    SettingsRow {
      label: "Night light"
      description: "Warmer colors in the evening, with less blue light."
      ToggleSwitch {
        checked: page.nightLight
        busy: page.nightLightBusy
        onToggled: page.toggleNightLight()
      }
    }
  }
}
