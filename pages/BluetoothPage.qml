import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "bluetooth"
import "bluetooth/Model.js" as Model

// Bluetooth: adapter power and visibility, paired devices, nearby devices.
//
// State is live from Quickshell.Bluetooth (BlueZ over D-Bus), the same source
// Omarchy's bluetooth panel uses. Actions go through Omarchy's helpers:
//   omarchy-bluetooth-power on|off        (rfkill soft block, survives reboot)
//   omarchy-bluetooth-device pair|connect|disconnect|forget <address>
// Scanning runs only while this page is actually on screen.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  spacing: Style.spacing.huge

  // The window is showing this page. False in the headless check (no
  // window), so loading the page there never starts a scan.
  readonly property bool onScreen: page.visible && !!app && !!app.window && app.window.visible === true

  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var lists: Model.deviceLists(devices)
  readonly property var knownRows: lists.known
  readonly property var nearbyRows: lists.nearby

  // Adapter state enum: 0 Disabled, 1 Enabled, 2 Enabling, 3 Disabling, 4 Blocked.
  readonly property int adapterState: adapter ? Number(adapter.state) : -1
  readonly property bool adapterOn: !!adapter && adapter.enabled
  readonly property bool adapterTransition: adapterState === 2 || adapterState === 3
  property bool powerBusy: false

  // Read-only diagnostics (rfkill / service) for the off and missing states.
  property bool hardBlocked: false
  property string serviceState: ""
  property bool checkedDiagnostics: false

  // Address -> "connecting" | "pairing" | "disconnecting" | "forgetting".
  property var pendingActions: ({})
  // Address -> label, for result toasts after the device row is gone.
  property var pendingLabels: ({})

  // ---- discovery ----------------------------------------------------------
  // Same ownership model as the built-in panel: only stop a scan this page
  // started, and keep nudging BlueZ (it rejects StartDiscovery while powering
  // up, and scans time out) while the page is on screen.
  readonly property bool scanWanted: onScreen && adapterOn
  property bool owesDiscoveryStop: false

  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: page.scanWanted && !page.adapter.discovering
    onTriggered: {
      page.owesDiscoveryStop = true
      page.adapter.discovering = true
    }
  }

  Timer {
    property int attempts: 0
    interval: 600
    repeat: true
    triggeredOnStart: true
    running: !page.scanWanted && page.owesDiscoveryStop && page.adapter !== null && page.adapter.discovering === true
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      attempts += 1
      if (attempts > 4) { page.owesDiscoveryStop = false; return }
      page.adapter.discovering = false
    }
  }

  Connections {
    target: page.adapter
    function onDiscoveringChanged() {
      if (page.adapter && !page.adapter.discovering && !page.scanWanted) page.owesDiscoveryStop = false
    }
  }

  Component.onDestruction: {
    if (owesDiscoveryStop && adapter !== null && adapter.discovering) adapter.discovering = false
  }

  // ---- lifecycle ----------------------------------------------------------
  // Scanning itself is driven by `scanWanted`, which turns true here (the page
  // just became visible) and false when the page or window is hidden.
  function activated() {
    if (!sys) return
    refreshDiagnostics()
  }

  function refreshDiagnostics() {
    sys.sh("rfkill -J 2>/dev/null; echo '---'; systemctl is-active bluetooth 2>/dev/null", [], function(r) {
      var parts = String(r.stdout || "").split("---")
      var hard = false
      try {
        var data = JSON.parse(parts[0])
        var devs = data && data.rfkilldevices ? data.rfkilldevices : []
        for (var i = 0; i < devs.length; i++)
          if (devs[i].type === "bluetooth" && devs[i].hard === "blocked") hard = true
      } catch (e) {}
      page.hardBlocked = hard
      page.serviceState = String(parts[1] || "").trim()
      page.checkedDiagnostics = true
    })
  }

  // ---- helpers ------------------------------------------------------------
  function deviceFor(address) {
    var devs = devices || []
    for (var i = 0; i < devs.length; i++)
      if (devs[i] && devs[i].address === address) return devs[i]
    return null
  }

  function pendingFor(address) { return pendingActions[address] || "" }

  function setPending(address, action, label) {
    var next = Model.cloneMap(pendingActions)
    if (action) next[address] = action
    else delete next[address]
    pendingActions = next
    if (label) {
      var labels = Model.cloneMap(pendingLabels)
      labels[address] = label
      pendingLabels = labels
    }
  }

  // ---- actions (only from explicit user input) ---------------------------
  function setPower(on) {
    if (!adapter || powerBusy || hardBlocked) return
    powerBusy = true
    sys.run(["omarchy-bluetooth-power", on ? "on" : "off"], function(r) {
      page.powerBusy = false
      if (r.code !== 0) app.toast("Could not turn Bluetooth " + (on ? "on" : "off") + ": " + (String(r.stderr || r.stdout).trim() || "exit " + r.code), true)
      else app.toast(on ? "Bluetooth on" : "Bluetooth off")
      page.refreshDiagnostics()
    })
  }

  function setDiscoverable(on) {
    if (!adapterOn) return
    adapter.discoverable = on
    app.toast(on ? "Visible as “" + adapter.name + "”" : "Hidden from nearby devices")
  }

  function runDevice(action, row, pending) {
    if (!row || !row.address || pendingFor(row.address) !== "") return
    var address = row.address
    var label = row.label
    setPending(address, pending, label)
    sys.run(["omarchy-bluetooth-device", action, address], function(r) {
      page.finishDevice(action, address, label, r)
    })
  }

  // omarchy-bluetooth-device swallows bluetoothctl failures, so judge the
  // outcome from BlueZ state once it has had a moment to settle.
  function finishDevice(action, address, label, result) {
    settle.queue = settle.queue.concat([{ action: action, address: address, label: label, stderr: String(result.stderr || "").trim() }])
    settle.restart()
  }

  function judge(item) {
    var d = deviceFor(item.address)
    var known = !!d && Model.isKnown(d)
    var connected = !!d && d.connected
    var err = item.stderr ? " (" + item.stderr + ")" : ""
    if (item.action === "pair") {
      if (known && connected) { app.toast("Paired with " + item.label); switchAudioTo(item.address) }
      else if (known) app.toast("Paired with " + item.label + ", but it didn't connect", true)
      else app.toast("Pairing with " + item.label + " failed. Make sure it's in pairing mode." + err, true)
    } else if (item.action === "connect") {
      if (connected) { app.toast("Connected to " + item.label); switchAudioTo(item.address) }
      else app.toast("Couldn't connect to " + item.label + ". Is it turned on and in range?" + err, true)
    } else if (item.action === "disconnect") {
      if (!connected) app.toast("Disconnected " + item.label)
      else app.toast("Couldn't disconnect " + item.label + err, true)
    } else if (item.action === "forget") {
      if (!known) app.toast("Removed " + item.label)
      else app.toast("Couldn't remove " + item.label + err, true)
    }
    setPending(item.address, "")
  }

  function primaryAction(row) {
    if (!row) return
    if (row.connected) runDevice("disconnect", row, "disconnecting")
    else if (row.known) runDevice("connect", row, "connecting")
    else runDevice("pair", row, "pairing")
  }

  function removeDevice(row) {
    if (!row) return
    app.confirm("Remove “" + row.label + "”? You'll need to pair it again to use it.", "Remove", function() {
      page.runDevice("forget", row, "forgetting")
    })
  }

  // Like the built-in panel: a freshly connected headset becomes the audio
  // output once PipeWire publishes its sink.
  property string audioSwitchAddress: ""
  property int audioSwitchAttempts: 0

  function switchAudioTo(address) {
    audioSwitchAddress = address
    audioSwitchAttempts = 0
    audioSwitchTimer.restart()
  }

  function tryAudioSwitch() {
    if (audioSwitchAddress === "") return
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (Model.bluetoothSinkMatches(n, audioSwitchAddress)) {
        audioSwitchAddress = ""
        if (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.id === n.id) return
        Pipewire.preferredDefaultAudioSink = n
        sys.run(["omarchy-audio-output-set-default", String(n.id), String(n.name || "")])
        return
      }
    }
    audioSwitchAttempts += 1
    if (audioSwitchAttempts >= 8) audioSwitchAddress = ""
    else audioSwitchTimer.restart()
  }

  Timer {
    id: settle
    property var queue: []
    interval: 800
    onTriggered: {
      var items = queue
      queue = []
      for (var i = 0; i < items.length; i++) page.judge(items[i])
    }
  }

  Timer {
    id: audioSwitchTimer
    interval: 500
    onTriggered: page.tryAudioSwitch()
  }

  // ---- UI -----------------------------------------------------------------
  // No adapter at all.
  SettingsSection {
    visible: !page.adapter
    title: "Bluetooth"
    SettingsRow {
      label: "No Bluetooth adapter found"
      description: !page.checkedDiagnostics ? ""
        : page.serviceState !== "active" ? "The Bluetooth service is not running (" + (page.serviceState || "unknown") + ")."
        : page.hardBlocked ? "Bluetooth is turned off by a hardware switch."
        : "Plug in a Bluetooth adapter or check that it is enabled in the firmware settings."
    }
  }

  SettingsSection {
    visible: !!page.adapter
    title: "Bluetooth"

    SettingsRow {
      label: "Bluetooth"
      description: page.hardBlocked ? "Turned off by a hardware switch or airplane mode key."
        : page.adapterState === 2 ? "Turning on…"
        : page.adapterState === 3 ? "Turning off…"
        : page.adapterOn ? (page.adapter.discovering ? "On · searching for devices" : "On")
        : "Off"
      ToggleSwitch {
        checked: page.adapterOn
        busy: page.powerBusy || page.adapterTransition || page.hardBlocked
        opacity: page.hardBlocked ? 0.5 : 1.0
        onToggled: page.setPower(!page.adapterOn)
      }
    }

    SettingsRow {
      visible: page.adapterOn
      label: "Visible to nearby devices"
      description: "Lets other devices find this computer as “" + (page.adapter ? page.adapter.name : "") + "”"
        + (page.adapter && page.adapter.discoverableTimeout > 0
          ? " for " + Math.round(page.adapter.discoverableTimeout / 60) + " min." : ".")
      ToggleSwitch {
        checked: !!page.adapter && page.adapter.discoverable
        onToggled: page.setDiscoverable(!page.adapter.discoverable)
      }
    }
  }

  SettingsSection {
    visible: !!page.adapter
    title: "My devices"

    Repeater {
      model: page.knownRows
      DeviceRow {
        required property var modelData
        dev: modelData
        pending: page.pendingFor(modelData.address)
        adapterOn: page.adapterOn
        onPrimary: page.primaryAction(modelData)
        onRemove: page.removeDevice(modelData)
      }
    }

    EmptyText {
      visible: page.knownRows.length === 0
      text: "No paired devices"
    }
    EmptyText {
      visible: page.knownRows.length > 0 && !page.adapterOn
      text: "Turn Bluetooth on to connect devices."
    }
  }

  SettingsSection {
    visible: page.adapterOn
    title: "Nearby devices"
    description: "Put a device in pairing mode to see it here."

    Repeater {
      model: page.nearbyRows
      DeviceRow {
        required property var modelData
        dev: modelData
        pending: page.pendingFor(modelData.address)
        adapterOn: page.adapterOn
        onPrimary: page.primaryAction(modelData)
      }
    }

    EmptyText {
      visible: page.nearbyRows.length === 0
      text: page.adapter && page.adapter.discovering ? "Searching for devices…" : "Not searching right now."
    }
  }

  component EmptyText: Text {
    textFormat: Text.PlainText
    color: Util.alpha(Commons.Color.foreground, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
    Layout.leftMargin: Style.spacing.rowPaddingX
  }
}
