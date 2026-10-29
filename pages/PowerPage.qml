import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "power/PowerModel.js" as Model

// Power & Lock: power profile, battery, idle timeouts (shell.json idle.*),
// Omarchy idle/suspend/screensaver toggles, hibernation and session actions.
//
// State is read the same way Omarchy reads it:
//   profiles     omarchy-powerprofiles-list --active-state
//   battery      omarchy-battery-status --shell  +  upower -i (health)
//   stay awake   omarchy-toggle-idle status
//   suspend      omarchy-toggle-enabled suspend-off      (system menu `when:`)
//   screensaver  omarchy-toggle-enabled screensaver-off  (omarchy-launch-screensaver)
//   hibernation  omarchy-hibernation-available           (system menu `when:`)
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // shell.json to edit. Empty = the real one (sys.shellConfigPath). Tests
  // point this at /tmp/omatings-power/shell.json.
  property string configPath: ""

  spacing: Style.spacing.huge

  // ---- state ---------------------------------------------------------------
  property bool loaded: false

  property var profiles: []
  property string activeProfile: ""
  property bool profileBusy: false

  property bool batteryPresent: false
  property var battery: ({})
  property var upower: ({})

  property int screensaverSeconds: Model.SERVICE_DEFAULTS.screensaver
  property int lockSeconds: Model.SERVICE_DEFAULTS.lock
  property int defaultScreensaverSeconds: Model.SERVICE_DEFAULTS.screensaver
  property int defaultLockSeconds: Model.SERVICE_DEFAULTS.lock

  property bool stayAwake: false
  property bool suspendOff: false
  property bool screensaverOff: false
  property string toggleBusy: ""

  property bool hibernationSupported: false
  property bool hibernationAvailable: false
  property bool hibernationConfigured: false

  readonly property color fg: Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent

  function shellConfigFile() { return configPath !== "" ? configPath : sys.shellConfigPath }

  // ---- loading -------------------------------------------------------------
  function activated() {
    if (!sys) return
    loadStatus()
    loadProfiles()
    loadIdle()
  }

  function loadStatus() {
    sys.sh("s=$(omarchy-toggle-idle status 2>/dev/null)\n"
      + "[[ $s == *'\"enabled\":true'* ]] && echo \"stayAwake\t1\" || echo \"stayAwake\t0\"\n"
      + "omarchy-toggle-enabled suspend-off && echo \"suspendOff\t1\" || echo \"suspendOff\t0\"\n"
      + "omarchy-toggle-enabled screensaver-off && echo \"screensaverOff\t1\" || echo \"screensaverOff\t0\"\n"
      + "[[ -f /sys/power/image_size ]] && echo \"hibSupported\t1\" || echo \"hibSupported\t0\"\n"
      + "omarchy-hibernation-available && echo \"hibAvailable\t1\" || echo \"hibAvailable\t0\"\n"
      + "grep -qs '^HOOKS+=(resume)$' /etc/mkinitcpio.conf.d/omarchy_resume.conf && echo \"hibConfigured\t1\" || echo \"hibConfigured\t0\"\n"
      + "omarchy-battery-present && echo \"battery\t1\" || echo \"battery\t0\"\n",
      [], function(r) {
        var kv = Model.parseKeyValue(r.stdout)
        page.stayAwake = kv.stayAwake === "1"
        page.suspendOff = kv.suspendOff === "1"
        page.screensaverOff = kv.screensaverOff === "1"
        page.hibernationSupported = kv.hibSupported === "1"
        page.hibernationAvailable = kv.hibAvailable === "1"
        page.hibernationConfigured = kv.hibConfigured === "1"
        page.batteryPresent = kv.battery === "1"
        page.loaded = true
        if (page.batteryPresent) loadBattery()
      })
  }

  function loadProfiles() {
    sys.run(["omarchy-powerprofiles-list", "--active-state"], function(r) {
      var parsed = Model.parseProfiles(r.stdout)
      page.profiles = parsed.profiles
      page.activeProfile = parsed.active
    })
  }

  function loadBattery() {
    sys.run(["omarchy-battery-status", "--shell"], function(r) {
      page.battery = Model.parseKeyValue(r.stdout)
    })
    sys.sh("b=$(upower -e 2>/dev/null | grep BAT | head -n 1); [[ -n $b ]] && upower -i \"$b\"", [], function(r) {
      page.upower = Model.parseUpower(r.stdout)
    })
  }

  function loadIdle() {
    sys.readJson(sys.omarchyPath + "/config/omarchy/shell.json", function(defaults) {
      var d = defaults && defaults.idle ? defaults.idle : ({})
      page.defaultScreensaverSeconds = Model.secondsFromConfig(d.screensaver, Model.SERVICE_DEFAULTS.screensaver)
      page.defaultLockSeconds = Model.secondsFromConfig(d.lock, Model.SERVICE_DEFAULTS.lock)
      sys.readJson(page.shellConfigFile(), function(config) {
        var idle = config && config.idle ? config.idle : ({})
        page.screensaverSeconds = Model.secondsFromConfig(idle.screensaver, page.defaultScreensaverSeconds)
        page.lockSeconds = Model.secondsFromConfig(idle.lock, page.defaultLockSeconds)
        page.syncIdleControls()
      })
    })
  }

  function syncIdleControls() {
    screensaverDropdown.value = String(page.screensaverSeconds)
    lockDropdown.value = String(page.lockSeconds)
  }

  // ---- actions -------------------------------------------------------------
  function setProfile(profile) {
    if (profileBusy || profile === activeProfile) return
    profileBusy = true
    var previous = activeProfile
    activeProfile = profile
    // autodetect = remember it for the current power source (AC or battery),
    // exactly like the Omarchy power panel does.
    sys.run(["omarchy-powerprofiles-set", "autodetect", profile], function(r) {
      page.profileBusy = false
      if (r.code !== 0) {
        page.activeProfile = previous
        app.toast("Could not set power profile: " + (r.stderr || r.stdout || ("exit " + r.code)), true)
      } else {
        app.toast(Model.profileOptions([profile])[0].label + " power profile")
      }
      page.loadProfiles()
    })
  }

  function updateShellConfig(mutate, callback) {
    if (configPath === "" || configPath === sys.shellConfigPath) {
      sys.updateShellConfig(mutate, callback)
      return
    }
    sys.readJson(configPath, function(config) {
      if (!config || typeof config !== "object") config = { version: 1 }
      mutate(config)
      sys.writeFile(configPath, JSON.stringify(config, null, 2) + "\n", callback)
    })
  }

  function setIdle(key, seconds) {
    var n = Number(seconds)
    if (!isFinite(n) || n < 0) return
    updateShellConfig(function(config) {
      if (!config.idle || typeof config.idle !== "object") config.idle = {}
      config.idle[key] = n
    }, function(ok, r) {
      if (!ok) {
        page.syncIdleControls()
        app.toast("Could not save shell.json: " + (r && r.stderr ? r.stderr : "write failed"), true)
        return
      }
      if (key === "screensaver") page.screensaverSeconds = n
      else page.lockSeconds = n
      page.syncIdleControls()
      var what = key === "screensaver" ? "Screensaver" : "Lock"
      app.toast(n === 0 ? what + " will no longer start when idle"
                        : what + " after " + Model.durationLabel(n))
    })
  }

  // name: "idle" | "suspend" | "screensaver"
  function runToggle(name, argv, successText) {
    if (toggleBusy !== "") return
    toggleBusy = name
    sys.run(argv, function(r) {
      page.toggleBusy = ""
      if (r.code !== 0) app.toast("Could not change setting: " + (r.stderr || r.stdout || ("exit " + r.code)), true)
      else if (successText) app.toast(successText())
      page.loadStatus()
    })
  }

  function toggleStayAwake() {
    var next = !stayAwake
    runToggle("idle", ["omarchy-toggle-idle", next ? "stay-awake" : "allow-idle"], function() {
      return next ? "Staying awake: no screensaver or lock when idle" : "Idle screensaver and lock enabled"
    })
  }

  function toggleSuspend() {
    // omarchy-toggle-suspend flips the suspend-off flag and notifies itself.
    runToggle("suspend", ["omarchy-toggle-suspend"], null)
  }

  function toggleScreensaver() {
    runToggle("screensaver", ["omarchy-toggle-screensaver"], null)
  }

  function sessionAction(kind) {
    if (kind === "lock") {
      sys.detached(["omarchy-system-lock"])
    } else if (kind === "suspend") {
      sys.detached(["systemctl", "suspend"])
    } else if (kind === "hibernate") {
      app.confirm("Hibernate now? Open work is saved to disk and the computer turns off.", "Hibernate", function() {
        sys.detached(["systemctl", "hibernate"])
      })
    } else if (kind === "logout") {
      app.confirm("Log out? Open windows will be closed.", "Log out", function() {
        sys.detached(["omarchy-system-logout"])
      })
    } else if (kind === "reboot") {
      app.confirm("Restart now? Open windows will be closed.", "Restart", function() {
        sys.detached(["omarchy-system-reboot"])
      })
    } else if (kind === "shutdown") {
      app.confirm("Shut down now? Open windows will be closed.", "Shut down", function() {
        sys.detached(["omarchy-system-shutdown"])
      })
    }
  }

  function setupHibernation() {
    sys.terminal("omarchy-hibernation-setup")
    app.toast("Hibernation setup opened in a terminal")
  }

  function removeHibernation() {
    app.confirm("Remove hibernation? This deletes the swap file and rebuilds the boot image.", "Remove", function() {
      sys.terminal("omarchy-hibernation-remove")
    })
  }

  // ---- live battery --------------------------------------------------------
  Timer {
    interval: 10000
    repeat: true
    running: page.visible && page.loaded
    onTriggered: {
      page.loadProfiles()
      if (page.batteryPresent) page.loadBattery()
    }
  }

  // ---- view helpers --------------------------------------------------------
  component ValueText: Text {
    textFormat: Text.PlainText
    color: Util.alpha(page.fg, 0.8)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    width: Math.min(implicitWidth, page.width * 0.55)
  }

  component ActionButton: Button {
    property string kind: ""
    bordered: true
    onClicked: page.sessionAction(kind)
  }

  readonly property real batteryFraction: {
    var p = parseInt(String(battery.percentage || upower.percentage || "0"), 10)
    return isFinite(p) ? Math.max(0, Math.min(1, p / 100)) : 0
  }
  readonly property string batteryState: String(battery.state || upower.state || "")
  readonly property real energyFull: parseFloat(upower["energy-full"] || "")
  readonly property real energyDesign: parseFloat(upower["energy-full-design"] || "")
  readonly property string healthText: {
    var cap = String(upower.capacity || "")
    if (cap === "" && energyFull > 0 && energyDesign > 0) cap = Math.min(100, Math.round(energyFull / energyDesign * 100)) + "%"
    return cap
  }

  // ---- power profile -------------------------------------------------------
  SettingsSection {
    title: "Power mode"

    SettingsRow {
      label: "Power profile"
      description: page.profiles.length === 0
        ? "power-profiles-daemon is not available."
        : (page.batteryPresent ? "Remembered separately for battery and AC power." : "")

      ButtonGroup {
        visible: page.profiles.length > 0
        enabled: !page.profileBusy
        options: Model.profileOptions(page.profiles)
        value: page.activeProfile
        onChanged: function(value) { page.setProfile(value) }
      }
    }
  }

  // ---- battery -------------------------------------------------------------
  SettingsSection {
    title: "Battery"
    visible: page.batteryPresent

    SettingsRow {
      label: (page.battery.percentage || page.upower.percentage || "—")
      description: Model.stateLabel(page.batteryState)
        + (Model.timeLabel(page.batteryState, page.battery.time) !== "" ? "  ·  " + Model.timeLabel(page.batteryState, page.battery.time) : "")

      Rectangle {
        width: Style.space(220)
        height: Style.space(10)
        radius: Style.cornerRadius > 0 ? height / 2 : 0
        color: Util.alpha(page.fg, 0.12)

        Rectangle {
          width: Math.max(parent.height, parent.width * page.batteryFraction)
          height: parent.height
          radius: parent.radius
          color: page.batteryFraction <= 0.15 && page.batteryState === "discharging" ? page.urgent : page.accent
        }
      }
    }

    SettingsRow {
      visible: !!page.battery.rate
      label: page.batteryState === "discharging" ? "Power draw" : "Charge rate"
      ValueText { text: page.battery.rate || "" }
    }

    SettingsRow {
      visible: page.healthText !== ""
      label: "Health"
      description: page.energyFull > 0 && page.energyDesign > 0
        ? "Holds " + page.energyFull.toFixed(1) + " Wh of its " + page.energyDesign.toFixed(1) + " Wh design capacity."
        : "Remaining capacity compared to when the battery was new."
      ValueText { text: page.healthText }
    }

    SettingsRow {
      visible: !!page.battery.cycles
      label: "Charge cycles"
      ValueText { text: page.battery.cycles || "" }
    }

    SettingsRow {
      visible: !!page.battery.threshold
      label: "Charge limit"
      description: "Set by the firmware to extend battery life."
      ValueText { text: page.battery.threshold || "" }
    }

    SettingsRow {
      visible: !!page.battery.size
      label: "Capacity"
      ValueText {
        text: (page.battery.size || "")
          + (page.upower.vendor || page.upower.model ? "  ·  " + [page.upower.vendor, page.upower.model].filter(function(x) { return !!x }).join(" ") : "")
      }
    }
  }

  // ---- idle ----------------------------------------------------------------
  SettingsSection {
    title: "Screensaver & lock"
    description: page.stayAwake ? "Stay awake is on, so neither starts until you turn it off." : ""

    SettingsRow {
      label: "Stay awake"
      description: "Never start the screensaver or lock the screen when idle."
      ToggleSwitch {
        checked: page.stayAwake
        busy: page.toggleBusy === "idle"
        onToggled: page.toggleStayAwake()
      }
    }

    SettingsRow {
      label: "Screensaver after"
      description: "Default: " + Model.durationLabel(page.defaultScreensaverSeconds).toLowerCase()
        + (page.screensaverOff ? ". The screensaver is turned off below." : ".")
      Dropdown {
        id: screensaverDropdown
        showLabel: false
        options: Model.idleOptions(page.screensaverSeconds)
        value: String(page.screensaverSeconds)
        onChanged: function(value) { page.setIdle("screensaver", value) }
      }
    }

    SettingsRow {
      label: "Lock after"
      description: "Default: " + Model.durationLabel(page.defaultLockSeconds).toLowerCase()
        + (page.lockSeconds > 0 && page.screensaverSeconds > 0 && page.lockSeconds < page.screensaverSeconds
           ? ". Locks before the screensaver starts." : ".")
      Dropdown {
        id: lockDropdown
        showLabel: false
        options: Model.idleOptions(page.lockSeconds)
        value: String(page.lockSeconds)
        onChanged: function(value) { page.setIdle("lock", value) }
      }
    }

    SettingsRow {
      label: "Screensaver"
      description: "Show the animated Omarchy screensaver when idle."
      ToggleSwitch {
        checked: !page.screensaverOff
        busy: page.toggleBusy === "screensaver"
        onToggled: page.toggleScreensaver()
      }
    }
  }

  // ---- suspend & hibernate -------------------------------------------------
  SettingsSection {
    title: "Suspend & hibernate"

    SettingsRow {
      label: "Suspend"
      description: "Offer Suspend in the system menu."
      ToggleSwitch {
        checked: !page.suspendOff
        busy: page.toggleBusy === "suspend"
        onToggled: page.toggleSuspend()
      }
    }

    SettingsRow {
      label: "Hibernation"
      description: !page.hibernationSupported
        ? "Not supported on this computer."
        : page.hibernationAvailable
          ? "Set up. Hibernate saves your session to disk and powers off."
          : page.hibernationConfigured
            ? "Set up, but the swap file is not active yet. Restart to finish."
            : "Uses disk space equal to your memory for a swap file. Needs your password."

      RowLayout {
        spacing: Style.spacing.md
        Button {
          visible: page.hibernationSupported && !page.hibernationConfigured
          text: "Set up…"
          bordered: true
          onClicked: page.setupHibernation()
        }
        Button {
          visible: page.hibernationConfigured
          text: "Remove…"
          bordered: true
          foreground: page.urgent
          onClicked: page.removeHibernation()
        }
      }
    }
  }

  // ---- session -------------------------------------------------------------
  SettingsSection {
    title: "Session"

    Flow {
      Layout.fillWidth: true
      spacing: Style.spacing.md

      ActionButton { kind: "lock"; text: "Lock"; iconText: String.fromCodePoint(0xF033E) }
      ActionButton { kind: "suspend"; visible: !page.suspendOff; text: "Suspend"; iconText: String.fromCodePoint(0xF04B2) }
      ActionButton { kind: "hibernate"; visible: page.hibernationAvailable; text: "Hibernate"; iconText: String.fromCodePoint(0xF0901) }
      ActionButton { kind: "logout"; text: "Log out"; iconText: String.fromCodePoint(0xF0343) }
      ActionButton { kind: "reboot"; text: "Restart"; iconText: String.fromCodePoint(0xF0709) }
      ActionButton { kind: "shutdown"; text: "Shut down"; iconText: String.fromCodePoint(0xF0425); foreground: page.urgent }
    }
  }
}
