import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "network"
import "network/NetModel.js" as Net

// Network page: Wi-Fi, Ethernet, connection details, DNS and Tailscale.
// Injected by the host: `sys` (Core/Sys.qml) and `app` (Settings.qml).
//
// State comes from NetworkManager via nmcli (read-only snapshot script in
// network/NetModel.js). While the page is on screen, `nmcli monitor` streams
// change events and a slow timer catches signal-strength drift. Wi-Fi logic
// follows Omarchy's network panel: secrets go over stdin, never argv; DNS goes
// through `omarchy dns`; QR sharing summons the omarchy.wifiqr card.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  spacing: Style.spacing.huge

  // ---- live state -----------------------------------------------------------
  property bool loaded: false
  property var radio: ({ hardware: true, software: true, known: false })
  property var devices: []
  property var wifiRows: []
  property var details: ({})
  property string routeDevice: ""
  property var speeds: ({})
  property var rfkill: ({ available: false, allBlocked: false, anyHard: false })
  property string dnsProvider: ""
  property var tailscale: ({ installed: false })

  readonly property var wifiDevice: pickDevice("wifi")
  readonly property var ethernetDevices: devices.filter(function(d) { return d.type === "ethernet" })
  readonly property bool wifiOn: radio.software && radio.hardware
  readonly property var connectedWifi: {
    for (var i = 0; i < wifiRows.length; i++) if (wifiRows[i].connected) return wifiRows[i]
    return null
  }
  readonly property var otherWifi: wifiRows.filter(function(r) { return !r.connected })
  readonly property var wifiDetails: wifiDevice ? (details[wifiDevice.device] || null) : null
  readonly property var primary: {
    if (routeDevice !== "" && details[routeDevice]) return details[routeDevice]
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (d.type !== "loopback" && Net.isConnectedState(d.state) && details[d.device]) return details[d.device]
    }
    return null
  }

  // Only poll/stream while the page is actually on screen.
  readonly property bool live: sys !== null && page.visible && Window.window !== null && Window.window.visible

  // ---- action state -----------------------------------------------------------
  property string actionKind: ""   // connect | disconnect | forget | radio | airplane | scan | dns | hidden
  property string actionSsid: ""
  property string failureSsid: ""
  property string failureText: ""
  property string passwordSsid: ""
  property string passwordText: ""
  property string identityText: ""
  property string pendingDns: ""
  readonly property bool busy: actionKind !== ""

  property bool hiddenOpen: false
  property string hiddenSsid: ""
  property string hiddenKind: "psk"
  property string hiddenPassword: ""

  function activated() {
    refresh()
  }

  onLiveChanged: if (live) refresh()

  // ---- reading ------------------------------------------------------------------
  property bool _refreshing: false
  property bool _refreshAgain: false

  function refresh() {
    if (!sys) return
    if (_refreshing) { _refreshAgain = true; return }
    _refreshing = true
    sys.sh(Net.snapshotScript, [], function(r) {
      page._refreshing = false
      page.applySnapshot(r.stdout)
      if (page._refreshAgain) {
        page._refreshAgain = false
        page.refresh()
      }
    })
  }

  function applySnapshot(text) {
    var s = Net.parseSections(text)
    radio = Net.parseRadio(s.radio)
    devices = Net.parseDevices(s.devices)
    details = Net.parseDeviceDetails(s.details || [])
    routeDevice = Net.parseRouteDevice(s.route)
    speeds = Net.parseSpeeds(s.speed)
    rfkill = Net.parseRfkill(s.rfkill)
    var dns = Net.nonEmpty(s.dns)[0] || ""
    if (dns !== "") dnsProvider = dns.trim()
    tailscale = Net.parseTailscale(s.tailscale)

    // Keep the list steady while the user types a password: rebuilding the
    // delegates would drop keyboard focus.
    if (passwordSsid === "") {
      var rows = Net.buildWifiRows(s.wifi, Net.parseSaved(s.saved), "")
      if (JSON.stringify(rows) !== JSON.stringify(wifiRows)) wifiRows = rows
    }
    loaded = true
  }

  function pickDevice(type) {
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].type !== type) continue
      if (Net.isConnectedState(devices[i].state)) return devices[i]
      if (!fallback) fallback = devices[i]
    }
    return fallback
  }

  function firstIp4(d) {
    return d && d.ip4.length > 0 ? d.ip4[0].replace(/\/\d+$/, "") : ""
  }

  // ---- actions ------------------------------------------------------------------
  function beginAction(kind, ssid) {
    actionKind = kind
    actionSsid = ssid || ""
    if (ssid) { failureSsid = ""; failureText = "" }
  }

  function endAction() {
    actionKind = ""
    actionSsid = ""
    refresh()
  }

  // Run argv as a user action with toast feedback.
  function runAction(kind, ssid, argv, successText, onResult) {
    if (busy || !sys) return
    beginAction(kind, ssid)
    sys.run(argv, function(r) {
      var handled = typeof onResult === "function" ? onResult(r) === true : false
      if (!handled) {
        if (r.code === 0) { if (successText) page.app.toast(successText) }
        else page.app.toast(Net.cleanError(r.stderr || r.stdout), true)
      }
      page.endAction()
    })
  }

  function setWifiEnabled(on) {
    runAction("radio", "", ["nmcli", "radio", "wifi", on ? "on" : "off"], on ? "Wi-Fi turned on" : "Wi-Fi turned off")
  }

  function setAirplane(on) {
    runAction("airplane", "", ["rfkill", on ? "block" : "unblock", "all"], on ? "Airplane mode on" : "Airplane mode off")
  }

  function rescan() {
    // Waits for the scan to finish, then the refresh picks up the new list.
    runAction("scan", "", ["nmcli", "device", "wifi", "list", "--rescan", "yes"], "")
  }

  function openPasswordPrompt(ssid) {
    if (passwordSsid !== ssid) { passwordText = ""; identityText = "" }
    passwordSsid = ssid
  }

  function cancelPasswordPrompt() {
    if (failureSsid === passwordSsid) { failureSsid = ""; failureText = "" }
    passwordSsid = ""
    passwordText = ""
    identityText = ""
    refresh()
  }

  function rowFailed(ssid, text) {
    failureSsid = ssid
    failureText = text
  }

  // Primary action on a network row that is not connected.
  function connectRow(net) {
    if (busy || !net || !net.inRange) return
    if (net.known) {
      runAction("connect", net.ssid, ["nmcli", "--wait", "45", "connection", "up", "uuid", net.uuids[0]], "Connected to " + net.ssid,
        function(r) {
          if (r.code === 0) return false
          // A saved profile with a wrong or missing secret: ask again.
          if (net.secured && Net.looksLikeAuthFailure(r.stderr)) {
            page.rowFailed(net.ssid, "Wrong password? Enter it again.")
            page.openPasswordPrompt(net.ssid)
            return true
          }
          page.rowFailed(net.ssid, Net.cleanError(r.stderr, "Could not connect"))
          return false
        })
      return
    }
    if (!net.secured) {
      runAction("connect", net.ssid, ["nmcli", "--wait", "45", "device", "wifi", "connect", net.ssid], "Connected to " + net.ssid,
        function(r) {
          if (r.code !== 0) page.rowFailed(net.ssid, Net.cleanError(r.stderr, "Could not connect"))
          return false
        })
      return
    }
    openPasswordPrompt(net.ssid)
  }

  function submitCredentials(net) {
    if (busy || !net) return
    var pw = passwordText
    var ssid = net.ssid
    var argv
    if (net.kind === "eap" && !net.known) {
      argv = ["bash", "-c", Net.enterpriseConnectScript, "omatings-eap", ssid, identityText]
    } else {
      // Known networks get their saved secret replaced; new ones get a profile
      // that is removed again if the connection fails.
      argv = ["bash", "-c", Net.secretConnectScript, "omatings-wifi", ssid, net.kind, "no", net.known ? net.uuids[0] : ""]
    }
    beginAction("connect", ssid)
    secretProc.start(argv, pw, function(r) {
      if (r.code === 0) {
        page.passwordSsid = ""
        page.passwordText = ""
        page.identityText = ""
        page.app.toast("Connected to " + ssid)
      } else {
        page.rowFailed(ssid, Net.looksLikeAuthFailure(r.stderr) ? "Wrong password" : Net.cleanError(r.stderr, "Could not connect"))
        page.passwordText = ""
        page.app.toast(Net.cleanError(r.stderr, "Could not connect to " + ssid), true)
      }
      page.endAction()
    })
  }

  function disconnectRow(net) {
    var uuid = wifiDevice ? wifiDevice.uuid : ""
    if (!uuid) return
    runAction("disconnect", net ? net.ssid : "", ["nmcli", "connection", "down", "uuid", uuid], "Disconnected")
  }

  function forgetRow(net) {
    if (busy || !net || net.uuids.length === 0) return
    var message = "Forget “" + net.ssid + "”? The saved password is removed"
      + (net.connected ? " and you will be disconnected." : ".")
    app.confirm(message, "Forget", function() {
      page.runAction("forget", net.ssid, ["bash", "-c", Net.forgetScript, "omatings-forget"].concat(net.uuids), "Forgot " + net.ssid)
    })
  }

  // Opens Omarchy's Wi-Fi QR card (plugin omarchy.wifiqr).
  function shareWifi(net) {
    if (!sys) return
    var payload = {}
    if (wifiDevice) payload.iface = wifiDevice.device
    if (net && net.ssid) payload.ssid = net.ssid
    sys.run(["omarchy-shell", "shell", "summon", "omarchy.wifiqr", JSON.stringify(payload)], function(r) {
      if (r.code !== 0 || String(r.stdout).indexOf("ok") === -1)
        page.app.toast(Net.cleanError(r.stderr, "The Wi-Fi QR card is not available (plugin omarchy.wifiqr)"), true)
    })
  }

  function connectHidden() {
    if (busy) return
    var ssid = hiddenSsid.trim()
    if (ssid === "") return
    var kind = hiddenKind
    beginAction("hidden", ssid)
    secretProc.start(["bash", "-c", Net.secretConnectScript, "omatings-wifi", ssid, kind, "yes", ""],
      kind === "open" ? "" : hiddenPassword,
      function(r) {
        if (r.code === 0) {
          page.hiddenOpen = false
          page.hiddenSsid = ""
          page.hiddenPassword = ""
          page.app.toast("Connected to " + ssid)
        } else {
          page.app.toast(Net.cleanError(r.stderr, "Could not connect to " + ssid), true)
        }
        page.endAction()
      })
  }

  function setDns(provider) {
    if (busy || !sys || provider === dnsProvider) return
    if (provider === "Custom") {
      // omarchy-dns asks for the servers on stdin, so it needs a terminal.
      sys.terminal("omarchy-dns Custom")
      app.toast("Enter your DNS servers in the terminal")
      return
    }
    pendingDns = provider
    runAction("dns", "", ["omarchy-dns", provider], "DNS set to " + provider, function(r) {
      if (r.code === 0) page.dnsProvider = provider
      page.pendingDns = ""
      return false
    })
  }

  function openTailscalePanel() {
    if (!sys) return
    sys.run(["omarchy-shell", "shell", "summon", "omarchy.tailscale", "{}"], function(r) {
      if (r.code !== 0 || String(r.stdout).indexOf("ok") === -1)
        page.app.toast("Add the Tailscale widget to the bar first: omarchy plugin enable omarchy.tailscale", true)
    })
  }

  function copy(value) {
    if (!sys || !value) return
    sys.run(["wl-copy", "--", value], function(r) {
      if (r.code === 0) page.app.toast("Copied " + value)
      else page.app.toast(Net.cleanError(r.stderr, "Could not copy"), true)
    })
  }

  // ---- processes ----------------------------------------------------------------

  // Runs a connect script with one secret on stdin. Sys.run has no stdin, and
  // the secret must never be an argument.
  Process {
    id: secretProc

    property string secret: ""
    property var callback: null
    property int _pending: 0
    property int _code: -1

    function start(argv, secretValue, cb) {
      if (running) return
      secret = String(secretValue || "")
      callback = cb
      _pending = 3
      _code = -1
      command = argv
      running = true
    }

    function _settle() {
      _pending -= 1
      if (_pending > 0) return
      var cb = callback
      callback = null
      if (typeof cb === "function") cb({ code: _code, stdout: String(secretOut.text || ""), stderr: String(secretErr.text || "") })
    }

    stdinEnabled: true
    stdout: StdioCollector { id: secretOut; waitForEnd: true; onStreamFinished: secretProc._settle() }
    stderr: StdioCollector { id: secretErr; waitForEnd: true; onStreamFinished: secretProc._settle() }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode, exitStatus) {
      _code = exitCode
      _settle()
    }
  }

  // Streams NetworkManager events while the page is visible.
  Process {
    id: monitorProc
    command: ["nmcli", "monitor"]
    running: page.live
    stdout: SplitParser {
      onRead: function(line) { debounce.restart() }
    }
    onRunningChanged: if (!running && page.live) monitorRestart.restart()
  }

  Timer {
    id: monitorRestart
    interval: 3000
    onTriggered: if (page.live && !monitorProc.running) monitorProc.running = true
  }

  Timer {
    id: debounce
    interval: 500
    onTriggered: page.refresh()
  }

  // Signal strength, scan results and Tailscale don't emit monitor events.
  Timer {
    interval: 10000
    repeat: true
    running: page.live
    onTriggered: page.refresh()
  }

  // ---- Wi-Fi ----------------------------------------------------------------------
  SettingsSection {
    title: "Wi-Fi"
    visible: page.wifiDevice !== null

    SettingsRow {
      label: "Wi-Fi"
      description: {
        if (!page.radio.hardware) return "Blocked by airplane mode or a hardware switch."
        if (!page.radio.software) return "Off"
        return page.wifiDevice ? "Adapter " + page.wifiDevice.device : ""
      }
      ToggleSwitch {
        checked: page.wifiOn
        busy: page.actionKind === "radio"
        interactive: page.radio.hardware && (!page.busy || page.actionKind === "radio")
        onToggled: page.setWifiEnabled(!page.radio.software)
      }
    }

    SettingsRow {
      visible: page.rfkill.available
      label: "Airplane mode"
      description: page.rfkill.anyHard
        ? "A hardware switch is blocking a radio."
        : "Turns off Wi-Fi and Bluetooth radios."
      ToggleSwitch {
        checked: page.rfkill.allBlocked
        busy: page.actionKind === "airplane"
        interactive: !page.busy || page.actionKind === "airplane"
        onToggled: page.setAirplane(!page.rfkill.allBlocked)
      }
    }

    PanelSeparator { visible: page.wifiOn; Layout.fillWidth: true }

    // Fallback when the active access point isn't in the scan list.
    SettingsRow {
      id: fallbackRow
      readonly property bool linked: page.wifiDevice !== null && Net.isConnectedState(page.wifiDevice.state)
      visible: page.wifiOn && page.connectedWifi === null
      label: linked ? page.wifiDevice.connection : "Not connected"
      description: !page.loaded ? "Loading…"
        : linked ? ["Connected", page.firstIp4(page.wifiDetails)].filter(function(x) { return x !== "" }).join(" · ")
        : "Pick a network below."
      Button {
        visible: fallbackRow.linked
        bordered: true
        text: "Disconnect"
        enabled: !page.busy
        opacity: enabled ? 1 : 0.5
        onClicked: page.disconnectRow(null)
      }
    }

    Repeater {
      model: page.wifiOn && page.connectedWifi ? [page.connectedWifi] : []
      delegate: WifiRow {
        required property var modelData
        net: modelData
        extraInfo: page.firstIp4(page.wifiDetails)
        busyText: page.actionSsid === modelData.ssid && page.actionKind === "disconnect" ? "Disconnecting…"
          : page.actionSsid === modelData.ssid && page.actionKind === "forget" ? "Forgetting…" : ""
        failureText: page.failureSsid === modelData.ssid ? page.failureText : ""
        actionsEnabled: !page.busy
        onDisconnectClicked: page.disconnectRow(modelData)
        onForgetClicked: page.forgetRow(modelData)
        onShareClicked: page.shareWifi(modelData)
      }
    }
  }

  SettingsSection {
    title: "Networks"
    visible: page.wifiDevice !== null && page.wifiOn

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        text: page.actionKind === "scan" ? "Scanning…"
          : page.otherWifi.length === 0 ? "No other networks found."
          : page.otherWifi.length + (page.otherWifi.length === 1 ? " network" : " networks")
        color: Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
      }

      Button {
        bordered: true
        text: "Hidden network"
        iconText: Net.glyph.plus
        enabled: !page.busy
        opacity: enabled ? 1 : 0.5
        selected: page.hiddenOpen
        onClicked: page.hiddenOpen = !page.hiddenOpen
      }

      Button {
        bordered: true
        text: "Rescan"
        iconText: Net.glyph.refresh
        iconSpinning: page.actionKind === "scan"
        enabled: !page.busy
        opacity: enabled || page.actionKind === "scan" ? 1 : 0.5
        onClicked: page.rescan()
      }
    }

    // Hidden network form.
    ColumnLayout {
      visible: page.hiddenOpen
      Layout.fillWidth: true
      spacing: Style.spacing.md

      SettingsRow {
        label: "Network name"
        stacked: true
        TextField {
          width: parent.width
          placeholderText: "SSID"
          text: page.hiddenSsid
          enabled: !page.busy
          onTextChanged: if (text !== page.hiddenSsid) page.hiddenSsid = text
        }
      }

      SettingsRow {
        label: "Security"
        ButtonGroup {
          options: [
            { value: "open", label: "None" },
            { value: "psk", label: "WPA/WPA2" },
            { value: "sae", label: "WPA3" }
          ]
          value: page.hiddenKind
          onChanged: function(v) { page.hiddenKind = v }
        }
      }

      SettingsRow {
        visible: page.hiddenKind !== "open"
        label: "Password"
        description: page.hiddenPassword.length > 0 ? Net.passwordProblem(page.hiddenKind, page.hiddenPassword) : ""
        stacked: true
        TextField {
          width: parent.width
          password: true
          placeholderText: "Password"
          text: page.hiddenPassword
          enabled: !page.busy
          onTextChanged: if (text !== page.hiddenPassword) page.hiddenPassword = text
          onAccepted: connectHiddenButton.clicked()
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md
        Item { Layout.fillWidth: true }
        Button {
          text: "Cancel"
          enabled: !page.busy
          onClicked: { page.hiddenOpen = false; page.hiddenPassword = "" }
        }
        Button {
          id: connectHiddenButton
          bordered: true
          text: page.actionKind === "hidden" ? "Connecting…" : "Connect"
          enabled: !page.busy && page.hiddenSsid.trim() !== ""
            && (page.hiddenKind === "open" || Net.passwordProblem(page.hiddenKind, page.hiddenPassword) === "")
          opacity: enabled ? 1 : 0.5
          onClicked: if (enabled) page.connectHidden()
        }
      }

      PanelSeparator { Layout.fillWidth: true }
    }

    Repeater {
      model: page.otherWifi
      delegate: WifiRow {
        required property var modelData
        net: modelData
        busyText: {
          if (page.actionSsid !== modelData.ssid) return ""
          if (page.actionKind === "connect") return "Connecting…"
          if (page.actionKind === "forget") return "Forgetting…"
          return ""
        }
        failureText: page.failureSsid === modelData.ssid ? page.failureText : ""
        actionsEnabled: !page.busy
        passwordOpen: page.passwordSsid !== "" && page.passwordSsid === modelData.ssid
        passwordText: passwordOpen ? page.passwordText : ""
        identityText: passwordOpen ? page.identityText : ""
        onConnectClicked: page.connectRow(modelData)
        onForgetClicked: page.forgetRow(modelData)
        onPasswordEdited: function(t) { page.passwordText = t }
        onIdentityEdited: function(t) { page.identityText = t }
        onCredentialsSubmitted: page.submitCredentials(modelData)
        onPasswordCanceled: page.cancelPasswordPrompt()
      }
    }
  }

  // ---- Ethernet -------------------------------------------------------------------
  SettingsSection {
    title: "Ethernet"
    visible: page.ethernetDevices.length > 0

    Repeater {
      model: page.ethernetDevices
      delegate: ColumnLayout {
        required property var modelData
        required property int index
        readonly property var info: page.details[modelData.device] || null
        readonly property bool up: Net.isConnectedState(modelData.state)
        Layout.fillWidth: true
        spacing: Style.spacing.lg

        PanelSeparator { visible: index > 0; Layout.fillWidth: true }

        SettingsRow {
          label: (modelData.connection && up ? modelData.connection : "Wired") + " (" + modelData.device + ")"
          description: {
            var parts = [Net.stateLabel(modelData.state)]
            var speed = Net.formatSpeed(page.speeds[modelData.device])
            if (up && speed) parts.push(speed)
            return parts.join(" · ")
          }
          Text {
            textFormat: Text.PlainText
            text: Net.glyph.ethernet
            color: up ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
          }
        }

        SettingsRow {
          visible: up && info !== null && info.ip4.length > 0
          label: "IP address"
          ValueText { text: info ? info.ip4.join("\n") : ""; onCopyRequested: function(v) { page.copy(v.replace(/\/\d+$/, "")) } }
        }

        SettingsRow {
          visible: up && info !== null && info.gateway4 !== ""
          label: "Gateway"
          ValueText { text: info ? info.gateway4 : ""; onCopyRequested: function(v) { page.copy(v) } }
        }
      }
    }
  }

  // ---- Details ----------------------------------------------------------------------
  SettingsSection {
    title: "Connection details"
    description: page.primary ? "The connection that carries your internet traffic." : ""

    SettingsRow {
      visible: page.primary === null
      label: page.loaded ? "No active connection" : "Loading…"
    }

    SettingsRow {
      visible: page.primary !== null
      label: "Interface"
      ValueText {
        text: page.primary ? page.primary.device + (page.primary.connection ? " · " + page.primary.connection : "") : ""
        copyable: false
      }
    }

    SettingsRow {
      visible: page.primary !== null && page.primary.hwaddr !== ""
      label: "Hardware address"
      ValueText { text: page.primary ? page.primary.hwaddr : ""; onCopyRequested: function(v) { page.copy(v) } }
    }

    SettingsRow {
      visible: page.primary !== null
      label: "IPv4 address"
      ValueText {
        text: page.primary && page.primary.ip4.length > 0 ? page.primary.ip4.join("\n") : "—"
        onCopyRequested: function(v) { page.copy(v.split("\n")[0].replace(/\/\d+$/, "")) }
      }
    }

    SettingsRow {
      visible: page.primary !== null && page.primary.gateway4 !== ""
      label: "IPv4 gateway"
      ValueText { text: page.primary ? page.primary.gateway4 : ""; onCopyRequested: function(v) { page.copy(v) } }
    }

    SettingsRow {
      visible: page.primary !== null && page.primary.ip6.length > 0
      label: "IPv6 address"
      ValueText {
        text: page.primary ? Net.sortIp6(page.primary.ip6).join("\n") : ""
        onCopyRequested: function(v) { page.copy(v.split("\n")[0].replace(/\/\d+$/, "")) }
      }
    }

    SettingsRow {
      visible: page.primary !== null && page.primary.gateway6 !== ""
      label: "IPv6 gateway"
      ValueText { text: page.primary ? page.primary.gateway6 : ""; onCopyRequested: function(v) { page.copy(v) } }
    }

    SettingsRow {
      visible: page.primary !== null
      label: "DNS servers"
      ValueText {
        text: page.primary && (page.primary.dns4.length + page.primary.dns6.length) > 0
          ? page.primary.dns4.concat(page.primary.dns6).join("\n") : "—"
        onCopyRequested: function(v) { page.copy(v.split("\n")[0]) }
      }
    }
  }

  // ---- DNS ----------------------------------------------------------------------------
  SettingsSection {
    title: "DNS"

    SettingsRow {
      label: "Provider"
      description: "Applies to every connection and may ask for your password. Custom opens a terminal to enter servers."
      ButtonGroup {
        options: [
          { value: "DHCP", label: "Automatic", tooltip: "Use DNS from your router (DHCP)" },
          { value: "Cloudflare", label: "Cloudflare", tooltip: "1.1.1.1 with DNS over TLS" },
          { value: "Google", label: "Google", tooltip: "8.8.8.8 with DNS over TLS" },
          { value: "Custom", label: "Custom", tooltip: "Enter your own servers in a terminal" }
        ]
        value: page.pendingDns !== "" ? page.pendingDns : page.dnsProvider
        enabled: !page.busy
        opacity: enabled || page.actionKind === "dns" ? 1 : 0.5
        onChanged: function(v) { page.setDns(v) }
      }
    }
  }

  // ---- VPN ------------------------------------------------------------------------------
  SettingsSection {
    title: "VPN"

    SettingsRow {
      label: "Tailscale"
      description: {
        var ts = page.tailscale
        if (!page.loaded) return "Loading…"
        if (!ts.installed) return "Not installed. Install opens a terminal and asks for your password."
        var parts = [Net.tailscaleSummary(ts)]
        if (ts.state === "Running" && ts.ips.length > 0) parts.push(ts.ips[0])
        if (ts.tailnet) parts.push(ts.tailnet)
        return parts.join(" · ")
      }

      RowLayout {
        spacing: Style.spacing.md

        Button {
          visible: page.loaded && !page.tailscale.installed
          bordered: true
          text: "Install…"
          onClicked: page.sys.terminal("omarchy-install-service-tailscale")
        }
        Button {
          visible: page.tailscale.installed === true
          text: "Admin console"
          onClicked: page.sys.detached(["omarchy-launch-webapp", "https://login.tailscale.com/admin/machines"])
        }
        Button {
          visible: page.tailscale.installed === true
          bordered: true
          text: "Open panel"
          onClicked: page.openTailscalePanel()
        }
      }
    }
  }
}
