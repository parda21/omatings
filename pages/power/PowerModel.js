.pragma library

// Pure helpers for the Power & Lock page. No Qt, no I/O.

// Idle timeouts in seconds. 0 disables the action — that is how the Omarchy
// idle service (shell/plugins/services/idle) reads it, not "fire at once".
var IDLE_PRESETS = [0, 60, 120, 300, 600, 900, 1800, 3600]

// Fallbacks the idle service itself uses when shell.json has no value.
var SERVICE_DEFAULTS = { screensaver: 150, lock: 300 }

function durationLabel(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s <= 0) return "Never"
  if (s % 3600 === 0) return s === 3600 ? "1 hour" : (s / 3600) + " hours"
  if (s % 60 === 0) return s === 60 ? "1 minute" : (s / 60) + " minutes"
  if (s > 60) return (Math.round(s / 6) / 10) + " minutes"
  return s + " seconds"
}

// Dropdown options for an idle timeout. A current value that is not one of
// the presets (e.g. the stock 150 s) is kept as its own entry so the
// dropdown can show what is really configured.
function idleOptions(current) {
  var list = IDLE_PRESETS.slice()
  var c = Number(current)
  if (isFinite(c) && c >= 0 && list.indexOf(c) === -1) {
    list.push(c)
    list.sort(function(a, b) {
      if (a === 0) return -1
      if (b === 0) return 1
      return a - b
    })
  }
  return list.map(function(s) { return { value: String(s), label: durationLabel(s) } })
}

// Same rule as IdleModel.secondsFromConfig.
function secondsFromConfig(value, fallback) {
  var n = Number(value)
  if (value === undefined || value === null || value === "" || !isFinite(n) || n < 0) return fallback
  return Math.floor(n)
}

// "key\tvalue" lines -> object (omarchy-battery-status --shell and our own
// status scripts print this shape).
function parseKeyValue(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    out[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return out
}

// `omarchy powerprofiles list --active-state` -> { profiles, active }
function parseProfiles(raw) {
  var lines = String(raw || "").split("\n")
  var profiles = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    profiles.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return { profiles: profiles, active: active }
}

function profileLabel(name) {
  if (name === "power-saver") return "Power saver"
  if (name === "balanced") return "Balanced"
  if (name === "performance") return "Performance"
  return name.charAt(0).toUpperCase() + name.slice(1)
}

// Same glyphs as the Omarchy power panel.
function profileIcon(name) {
  if (name === "power-saver") return String.fromCodePoint(0xF032A)
  if (name === "balanced") return String.fromCodePoint(0xF029A)
  if (name === "performance") return String.fromCodePoint(0xF04C5)
  return String.fromCodePoint(0xF0084)
}

function profileOptions(profiles) {
  return (profiles || []).map(function(p) {
    return { value: p, label: profileLabel(p), icon: profileIcon(p) }
  })
}

// Selected fields of `upower -i <battery>`.
function parseUpower(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*([a-z][a-z -]*):\s+(.+)$/.exec(lines[i])
    if (m) out[m[1].trim()] = m[2].trim()
  }
  return out
}

function stateLabel(state) {
  switch (state) {
  case "charging": return "Charging"
  case "discharging": return "On battery"
  case "fully-charged": return "Fully charged"
  case "pending-charge": return "Plugged in, not charging"
  case "pending-discharge": return "Plugged in, discharging"
  case "holding": return "Holding at charge limit"
  case "empty": return "Empty"
  default: return state ? state : "Unknown"
  }
}

function timeLabel(state, time) {
  if (!time) return ""
  if (state === "charging") return time + " until full"
  if (state === "discharging") return time + " left"
  return ""
}

if (typeof module !== "undefined") {
  module.exports = {
    IDLE_PRESETS: IDLE_PRESETS,
    durationLabel: durationLabel,
    idleOptions: idleOptions,
    secondsFromConfig: secondsFromConfig,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileOptions: profileOptions,
    parseUpower: parseUpower,
    stateLabel: stateLabel,
    timeLabel: timeLabel
  }
}
