import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "system/SystemModel.js" as Model

// System: about this computer, Omarchy updates and release channel, date &
// time, hostname and snapper snapshots.
//
// Everything privileged (updates, channel switch, timezone, hostname,
// snapshots) runs in a floating terminal via sys.terminal, the way the
// Omarchy menu does it. Reads are all unprivileged:
//   omarchy-version, omarchy-channel-current, omarchy-version-channel,
//   omarchy-version-branch, fastfetch --format json, timedatectl show,
//   snapper list-configs; `omarchy-update-available` + `checkupdates` only
//   when the user presses "Check now".
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // shell.json to edit (clock format). Empty = the real one.
  property string configPath: ""

  spacing: Style.spacing.huge

  // ---- state ---------------------------------------------------------------
  property string logo: ""
  property string version: ""
  property string channel: ""
  property string mirrorChannel: ""
  property string branch: ""
  property string hostname: ""
  property var hw: ({})

  property bool checking: false
  property bool checked: false
  property string omarchyUpdate: ""     // new version, "" = up to date
  property int packageUpdates: -1       // -1 = unknown
  property string checkError: ""

  property string timezone: ""
  property var timezones: []
  property bool ntp: false
  property bool ntpSynced: false
  property string clockFormat: ""
  property bool clockConfigurable: false

  property bool snapperPresent: false
  property var snapperConfigs: []

  property date now: new Date()

  readonly property color fg: Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent

  function shellConfigFile() { return configPath !== "" ? configPath : sys.shellConfigPath }

  // ---- loading -------------------------------------------------------------
  function activated() {
    if (!sys) return
    now = new Date()
    if (logo === "") {
      sys.readFile(sys.omarchyPath + "/logo.txt", function(text) {
        page.logo = String(text || "").replace(/\s+$/, "")
      })
    }
    loadVersion()
    loadHardware()
    loadTime()
    loadClockFormat()
    loadSnapper()
    if (timezones.length === 0) {
      sys.run(["timedatectl", "list-timezones"], function(r) {
        if (r.code === 0) page.timezones = r.stdout.split("\n").filter(function(x) { return x !== "" })
      })
    }
  }

  function loadVersion() {
    sys.sh("printf 'version\\t%s\\n' \"$(omarchy-version 2>/dev/null)\"\n"
      + "printf 'channel\\t%s\\n' \"$(omarchy-channel-current 2>/dev/null)\"\n"
      + "printf 'mirror\\t%s\\n' \"$(omarchy-version-channel 2>/dev/null)\"\n"
      + "printf 'branch\\t%s\\n' \"$(omarchy-version-branch 2>/dev/null)\"\n"
      + "printf 'hostname\\t%s\\n' \"$(cat /proc/sys/kernel/hostname 2>/dev/null)\"\n",
      [], function(r) {
        var kv = page.parseKv(r.stdout)
        page.version = kv.version || ""
        page.channel = kv.channel || ""
        page.mirrorChannel = kv.mirror || ""
        page.branch = kv.branch || ""
        page.hostname = kv.hostname || ""
        hostnameField.text = page.hostname
      })
  }

  function loadHardware() {
    sys.json(["fastfetch", "--format", "json", "-s", "os:host:kernel:uptime:cpu:gpu:memory:disk"], function(data) {
      page.hw = Model.parseFastfetch(data)
    })
  }

  function loadTime() {
    sys.run(["timedatectl", "show"], function(r) {
      var kv = {}
      var lines = String(r.stdout || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var eq = lines[i].indexOf("=")
        if (eq > 0) kv[lines[i].substring(0, eq)] = lines[i].substring(eq + 1)
      }
      page.timezone = kv.Timezone || ""
      page.ntp = kv.NTP === "yes"
      page.ntpSynced = kv.NTPSynchronized === "yes"
      timezoneDropdown.value = page.timezone
    })
  }

  function loadClockFormat() {
    sys.readJson(shellConfigFile(), function(config) {
      var at = Model.findClockEntry(config)
      page.clockConfigurable = at !== null
      page.clockFormat = at ? String(config.bar.layout[at.section][at.index].format || "dddd HH:mm") : ""
      clockDropdown.value = page.clockFormat
    })
  }

  function loadSnapper() {
    sys.sh("command -v snapper >/dev/null || exit 3; snapper --csvout list-configs 2>/dev/null | awk -F, 'NR>1 {print $1}'", [], function(r) {
      page.snapperPresent = r.code !== 3
      page.snapperConfigs = String(r.stdout || "").split("\n").filter(function(x) { return x.trim() !== "" })
    })
  }

  function parseKv(text) {
    var out = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab > 0) out[lines[i].substring(0, tab)] = lines[i].substring(tab + 1).trim()
    }
    return out
  }

  // ---- actions -------------------------------------------------------------
  function checkUpdates() {
    if (checking) return
    checking = true
    checkError = ""
    // Both are read-only: omarchy-update-available only queries, and
    // checkupdates syncs a private copy of the package databases.
    sys.run(["omarchy-update-available"], function(r) {
      page.omarchyUpdate = Model.parseOmarchyUpdate(r.code, r.stdout)
      sys.sh("command -v checkupdates >/dev/null || exit 3; out=$(checkupdates --nocolor 2>/dev/null); rc=$?\n"
        + "(( rc == 2 )) && { echo 0; exit 0; }\n"
        + "(( rc != 0 )) && exit 1\n"
        + "grep -c . <<<\"$out\"", [], function(c) {
          page.checking = false
          page.checked = true
          if (c.code === 0) page.packageUpdates = parseInt(c.stdout.trim(), 10) || 0
          else {
            page.packageUpdates = -1
            if (c.code !== 3) page.checkError = "Could not reach the package mirrors."
          }
          if (page.checkError !== "") app.toast(page.checkError, true)
          else if (page.omarchyUpdate !== "" || page.packageUpdates > 0) app.toast("Updates are available")
          else app.toast("Everything is up to date")
        })
    })
  }

  function runUpdate() {
    sys.terminal("omarchy-update")
  }

  function setChannel(value) {
    if (value === channel) return
    var ok = Model.CHANNELS.some(function(c) { return c.value === value })
    if (!ok) return
    var label = Model.CHANNELS.filter(function(c) { return c.value === value })[0].label
    app.confirm("Switch to the " + label + " channel? Packages are reinstalled from that channel in a terminal.", "Switch", function() {
      sys.terminal("omarchy-channel-set " + value)
    })
  }

  function setTimezone(tz) {
    if (tz === timezone) return
    if (!Model.validTimezone(tz) || timezones.indexOf(tz) === -1) {
      timezoneDropdown.value = timezone
      app.toast("Unknown timezone: " + tz, true)
      return
    }
    // Same steps as omarchy-menu-timezone, in a terminal because of sudo.
    sys.terminal("sudo timedatectl set-timezone " + tz
      + " && omarchy-shell -q omarchy.clock refresh; echo \"Timezone: $(timedatectl show -p Timezone --value)\"")
    timezoneDropdown.value = timezone
    app.toast("Changing timezone in a terminal")
  }

  function setClockFormat(format) {
    if (format === clockFormat) return
    var mutate = function(config) {
      var at = Model.findClockEntry(config)
      if (at) config.bar.layout[at.section][at.index].format = format
    }
    var done = function(ok, r) {
      if (!ok) {
        clockDropdown.value = page.clockFormat
        app.toast("Could not save shell.json: " + (r && r.stderr ? r.stderr : "write failed"), true)
        return
      }
      page.clockFormat = format
      app.toast("Clock shows " + Qt.formatDateTime(new Date(), page.previewFormat(format)))
    }
    if (configPath === "" || configPath === sys.shellConfigPath) {
      sys.updateShellConfig(mutate, done)
    } else {
      sys.readJson(configPath, function(config) {
        if (!config || typeof config !== "object") config = { version: 1 }
        mutate(config)
        sys.writeFile(configPath, JSON.stringify(config, null, 2) + "\n", done)
      })
    }
  }

  // Qt has no ISO week token; the clock widget substitutes 'ww' itself.
  function previewFormat(format) {
    var d = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    var day = d.getDay() || 7
    d.setDate(d.getDate() + 4 - day)
    var yearStart = new Date(d.getFullYear(), 0, 1)
    var week = Math.ceil(((d - yearStart) / 86400000 + 1) / 7)
    return format.replace(/ww/g, (week < 10 ? "0" : "") + week)
  }

  function renameHost() {
    var name = hostnameField.text.trim()
    if (!Model.validHostname(name) || name === hostname) return
    app.confirm("Rename this computer to “" + name + "”? Some apps only notice after a restart.", "Rename", function() {
      sys.terminal("sudo hostnamectl set-hostname " + name + " && echo \"Hostname: $(hostnamectl hostname)\"")
    })
  }

  function showSnapshots() {
    sys.terminal("for c in $(sudo snapper --csvout list-configs | awk -F, 'NR>1 {print $1}'); do echo; echo \"== $c\"; sudo snapper -c \"$c\" list; done")
  }

  function createSnapshot() {
    sys.terminal("omarchy-snapshot create")
  }

  function restoreSnapshot() {
    app.confirm("Restore a snapshot? Pick one in the terminal; the system is rolled back to it.", "Continue", function() {
      sys.terminal("omarchy-snapshot restore")
    })
  }

  // ---- view helpers --------------------------------------------------------
  component ValueText: Text {
    textFormat: Text.PlainText
    color: Util.alpha(page.fg, 0.8)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    width: Math.min(implicitWidth, page.width * 0.6)
  }

  FontMetrics {
    id: logoMetrics
    font.family: Style.font.family
    font.pixelSize: 100
  }

  // ---- hero ----------------------------------------------------------------
  ColumnLayout {
    Layout.fillWidth: true
    Layout.topMargin: Style.spacing.lg
    spacing: Style.spacing.xl

    Text {
      id: logoText
      visible: page.logo !== ""
      Layout.alignment: Qt.AlignHCenter
      readonly property int columns: {
        var lines = page.logo.split("\n")
        var max = 1
        for (var i = 0; i < lines.length; i++) max = Math.max(max, lines[i].length)
        return max
      }
      readonly property real glyphWidth: Math.max(1, logoMetrics.advanceWidth("█")) / 100
      text: page.logo
      textFormat: Text.PlainText
      wrapMode: Text.NoWrap
      color: page.accent
      font.family: Style.font.family
      font.pixelSize: Math.max(4, Math.min(Style.font.body, Math.floor(page.width * 0.9 / (columns * glyphWidth))))
      lineHeight: 1.0
    }

    Text {
      Layout.alignment: Qt.AlignHCenter
      text: page.version !== ""
        ? "Omarchy " + page.version + (page.channel !== "" && page.channel !== "unknown" ? "  ·  " + page.channel : "")
        : "Omarchy"
      textFormat: Text.PlainText
      color: page.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }
  }

  // ---- about ---------------------------------------------------------------
  SettingsSection {
    title: "About"

    SettingsRow {
      visible: page.hw.device !== undefined && page.hw.device !== ""
      label: "Device"
      ValueText { text: page.hw.device || "" }
    }
    SettingsRow {
      visible: !!page.hw.cpu
      label: "Processor"
      ValueText { text: page.hw.cpu || "" }
    }
    SettingsRow {
      visible: !!page.hw.gpu
      label: "Graphics"
      ValueText { text: page.hw.gpu || "" }
    }
    SettingsRow {
      visible: !!page.hw.memory
      label: "Memory"
      ValueText { text: page.hw.memory || "" }
    }
    SettingsRow {
      visible: !!page.hw.disk
      label: "Disk"
      description: "System drive"
      ValueText { text: page.hw.disk || "" }
    }
    SettingsRow {
      visible: page.version !== ""
      label: "Omarchy version"
      ValueText { text: page.version }
    }
    SettingsRow {
      visible: page.branch !== ""
      label: "Branch"
      description: "Linked source checkout"
      ValueText { text: page.branch }
    }
    SettingsRow {
      visible: !!page.hw.kernel
      label: "Kernel"
      ValueText { text: page.hw.kernel || "" }
    }
    SettingsRow {
      visible: !!page.hw.uptime
      label: "Uptime"
      ValueText { text: page.hw.uptime || "" }
    }
  }

  // ---- updates -------------------------------------------------------------
  SettingsSection {
    title: "Updates"

    SettingsRow {
      label: "Software updates"
      description: page.checking ? "Checking…"
        : !page.checked ? "Omarchy and system packages are updated together."
        : page.checkError !== "" ? page.checkError
        : (page.omarchyUpdate !== "" ? "Omarchy " + page.omarchyUpdate + " is available. " : "Omarchy is up to date. ")
          + (page.packageUpdates > 0 ? page.packageUpdates + (page.packageUpdates === 1 ? " package update." : " package updates.")
             : page.packageUpdates === 0 ? "No package updates." : "")

      RowLayout {
        spacing: Style.spacing.md
        Button {
          text: page.checking ? "Checking…" : "Check now"
          iconText: String.fromCodePoint(0xF0450)
          iconSpinning: page.checking
          bordered: true
          enabled: !page.checking
          onClicked: page.checkUpdates()
        }
        Button {
          text: "Update…"
          iconText: String.fromCodePoint(0xF01DA)
          bordered: true
          selected: page.omarchyUpdate !== "" || page.packageUpdates > 0
          onClicked: page.runUpdate()
        }
      }
    }

    SettingsRow {
      label: "Release channel"
      description: (Model.CHANNEL_DESCRIPTIONS[page.channel] || "")
        + (page.mirrorChannel.indexOf("/") !== -1 ? " Mirror and packages differ: " + page.mirrorChannel + "." : "")
      stacked: true

      ButtonGroup {
        options: Model.CHANNELS
        value: page.channel
        onChanged: function(value) { page.setChannel(value) }
      }
    }

    SettingsRow {
      label: "Firmware"
      description: "Updates device firmware with fwupd."
      Button {
        text: "Update firmware…"
        bordered: true
        onClicked: page.sys.terminal("omarchy-update-firmware")
      }
    }
  }

  // ---- date & time ---------------------------------------------------------
  SettingsSection {
    title: "Date & time"

    SettingsRow {
      label: "Timezone"
      description: "Changing it asks for your password in a terminal."
      SearchableDropdown {
        id: timezoneDropdown
        showLabel: false
        options: page.timezones
        value: page.timezone
        placeholderText: "Search timezones…"
        onChanged: function(value) { page.setTimezone(value) }
      }
    }

    SettingsRow {
      label: "Time sync"
      description: !page.ntp ? "Automatic time sync is off."
        : page.ntpSynced ? "Synchronized with network time." : "Not synchronized yet."
      Button {
        text: "Sync now…"
        bordered: true
        onClicked: page.sys.terminal("omarchy-update-time")
      }
    }

    SettingsRow {
      visible: page.clockConfigurable
      label: "Clock format"
      description: "How the clock in the bar shows the time. Right-click the clock to cycle formats."
      Dropdown {
        id: clockDropdown
        showLabel: false
        options: {
          var list = Model.CLOCK_FORMATS.slice()
          if (page.clockFormat !== "" && list.indexOf(page.clockFormat) === -1) list.push(page.clockFormat)
          return list.map(function(f) {
            return { value: f, label: Qt.formatDateTime(page.now, page.previewFormat(f)).replace(/\n/g, " ") }
          })
        }
        value: page.clockFormat
        onChanged: function(value) { page.setClockFormat(value) }
      }
    }
  }

  // ---- hostname ------------------------------------------------------------
  SettingsSection {
    title: "Computer name"

    SettingsRow {
      label: "Hostname"
      description: hostnameField.text.trim() !== "" && !Model.validHostname(hostnameField.text.trim())
        ? "Use letters, digits and hyphens only (up to 63 characters)."
        : "How this computer appears on the network. Renaming asks for your password in a terminal."

      RowLayout {
        spacing: Style.spacing.md
        TextField {
          id: hostnameField
          Layout.preferredWidth: Style.spacing.dropdownWidth
          placeholderText: "hostname"
          onAccepted: page.renameHost()
        }
        Button {
          text: "Rename…"
          bordered: true
          enabled: Model.validHostname(hostnameField.text.trim()) && hostnameField.text.trim() !== page.hostname
          opacity: enabled ? 1 : 0.5
          onClicked: page.renameHost()
        }
      }
    }
  }

  // ---- snapshots -----------------------------------------------------------
  SettingsSection {
    title: "Snapshots"
    description: page.snapperPresent
      ? "Snapper takes a snapshot before every update. Snapshots can also be booted from the boot menu."
      : "Snapper is not installed, so no snapshots are taken."

    SettingsRow {
      visible: page.snapperPresent
      label: "Snapper configs"
      description: page.snapperConfigs.length === 0 ? "No configs yet, so no snapshots are created." : ""
      ValueText { text: page.snapperConfigs.join(", ") || "None" }
    }

    Flow {
      visible: page.snapperPresent
      Layout.fillWidth: true
      spacing: Style.spacing.md

      Button {
        text: "Create snapshot…"
        iconText: String.fromCodePoint(0xF0100)
        bordered: true
        enabled: page.snapperConfigs.length > 0
        opacity: enabled ? 1 : 0.5
        onClicked: page.createSnapshot()
      }
      Button {
        text: "Show snapshots…"
        iconText: String.fromCodePoint(0xF0279)
        bordered: true
        onClicked: page.showSnapshots()
      }
      Button {
        text: "Restore…"
        iconText: String.fromCodePoint(0xF099B)
        bordered: true
        foreground: page.urgent
        onClicked: page.restoreSnapshot()
      }
    }
  }

  // Keeps the clock-format previews current while the page is open.
  Timer {
    interval: 30000
    repeat: true
    running: page.visible
    onTriggered: page.now = new Date()
  }
}
