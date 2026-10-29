.pragma library

// Pure helpers for the System page. No Qt, no I/O.

var CHANNELS = [
  { value: "stable", label: "Stable" },
  { value: "rc", label: "RC" },
  { value: "edge", label: "Edge" },
  { value: "dev", label: "Dev" }
]

var CHANNEL_DESCRIPTIONS = {
  stable: "Tested releases. Recommended.",
  rc: "Release candidates, a few days ahead of stable.",
  edge: "Latest packages as they are built. Expect breakage.",
  dev: "Links a git checkout in ~/omarchy. For Omarchy developers only."
}

// Bar clock presets, same list and order as
// $OMARCHY_PATH/shell/plugins/panels/clock/Model.js CLOCK_FORMATS.
var CLOCK_FORMATS = [
  "dddd HH:mm",
  "dddd h:mm AP",
  "HH:mm",
  "h:mm AP",
  "ddd d MMM HH:mm",
  "ddd d MMM h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

function formatBytes(bytes) {
  var b = Number(bytes)
  if (!isFinite(b) || b <= 0) return ""
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var i = 0
  while (b >= 1024 && i < units.length - 1) { b /= 1024; i++ }
  return (b >= 100 || i === 0 ? Math.round(b) : Math.round(b * 10) / 10) + " " + units[i]
}

// fastfetch reports uptime in milliseconds.
function formatUptime(ms) {
  var total = Math.floor(Number(ms) / 1000)
  if (!isFinite(total) || total <= 0) return ""
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var parts = []
  if (days > 0) parts.push(days + (days === 1 ? " day" : " days"))
  if (hours > 0) parts.push(hours + (hours === 1 ? " hour" : " hours"))
  if (days === 0 && (minutes > 0 || parts.length === 0)) parts.push(minutes + (minutes === 1 ? " minute" : " minutes"))
  return parts.join(", ")
}

// `fastfetch --format json` array -> flat summary for the About section.
function parseFastfetch(list) {
  var out = {}
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || m.error) continue
    var r = m.result
    switch (m.type) {
    case "Host":
      if (r) out.device = [r.vendor, r.name || r.family].filter(function(x) { return !!x && !/^(To be filled|Default string|System Product Name)/i.test(x) }).join(" ")
      break
    case "Kernel":
      if (r) out.kernel = (r.release || "") + (r.architecture ? " (" + r.architecture + ")" : "")
      break
    case "Uptime":
      if (r) out.uptime = formatUptime(r.uptime)
      break
    case "CPU":
      if (r) {
        var cores = r.cores && r.cores.logical ? r.cores.logical : 0
        out.cpu = String(r.cpu || "").replace(/\((R|TM)\)/g, "").replace(/\s+/g, " ").trim()
          + (cores ? " · " + cores + " threads" : "")
      }
      break
    case "GPU":
      if (Array.isArray(r)) out.gpu = r.map(function(g) {
        var name = String(g.name || "")
        if (g.vendor && name.indexOf(g.vendor) !== 0) name = g.vendor + " " + name
        return name + (g.type ? " (" + String(g.type).toLowerCase() + ")" : "")
      }).join(", ")
      break
    case "Memory":
      if (r && r.total) out.memory = formatBytes(r.total) + (r.used ? " (" + formatBytes(r.used) + " in use)" : "")
      break
    case "Disk":
      if (Array.isArray(r)) {
        var root = null
        for (var d = 0; d < r.length; d++) if (r[d].mountpoint === "/") root = r[d]
        if (root && root.bytes && root.bytes.total) {
          var used = root.bytes.total - (root.bytes.free || 0)
          out.disk = formatBytes(root.bytes.total) + " (" + formatBytes(root.bytes.free) + " free"
            + (root.filesystem ? ", " + root.filesystem : "") + ")"
          out.diskFraction = used / root.bytes.total
        }
      }
      break
    case "OS":
      if (r) out.os = r.prettyName || r.name || ""
      break
    }
  }
  return out
}

// "Omarchy is up to date" (exit 1) vs one line per update (exit 0), e.g.
//   omarchy 4.0.6-1 -> 4.0.7-1
function parseOmarchyUpdate(code, stdout) {
  if (code !== 0) return ""
  var line = String(stdout || "").split("\n")[0].trim()
  var m = /^(\S+)\s+(\S+)\s+->\s+(\S+)/.exec(line)
  if (m) return m[3].replace(/-\d+$/, "")
  return line
}

// Hostname labels per RFC 1123 (what hostnamectl accepts as a static name).
function validHostname(name) {
  return /^(?=.{1,64}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(String(name || ""))
}

// Same shape the Omarchy sudoers rule allows for `timedatectl set-timezone`.
function validTimezone(tz) {
  return /^[A-Za-z0-9_+][A-Za-z0-9_+.-]*(\/[A-Za-z0-9_+][A-Za-z0-9_+.-]*)*$/.test(String(tz || ""))
}

// Locate the bar clock entry in a shell.json object -> { section, index } or null.
function findClockEntry(config) {
  var layout = config && config.bar && config.bar.layout
  if (!layout || typeof layout !== "object") return null
  for (var section in layout) {
    var list = layout[section]
    if (!Array.isArray(list)) continue
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (e && typeof e === "object" && e.id === "omarchy.clock") return { section: section, index: i }
    }
  }
  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    CHANNELS: CHANNELS, CLOCK_FORMATS: CLOCK_FORMATS,
    formatBytes: formatBytes, formatUptime: formatUptime, parseFastfetch: parseFastfetch,
    parseOmarchyUpdate: parseOmarchyUpdate, validHostname: validHostname, validTimezone: validTimezone,
    findClockEntry: findClockEntry
  }
}
