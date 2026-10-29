.pragma library

// Pure helpers for the Network page. No QML, no I/O — everything here takes
// command output and returns plain objects, so it stays easy to reason about.
//
// Several helpers are adapted from Omarchy's own network panel
// (/usr/share/omarchy/shell/plugins/panels/network/Model.js).

// ---- glyphs ---------------------------------------------------------------

var glyph = {
  wifiOff: String.fromCodePoint(0xF092E),
  lock: String.fromCodePoint(0xF033E),
  ethernet: String.fromCodePoint(0xF0200),
  qr: String.fromCodePoint(0xF0432),
  refresh: String.fromCodePoint(0xF0450),
  forget: String.fromCodePoint(0xF01B4),
  check: String.fromCodePoint(0xF012C),
  plus: String.fromCodePoint(0xF0415),
  close: String.fromCodePoint(0xF0156),
  copy: String.fromCodePoint(0xF018F),
  open: String.fromCodePoint(0xF0CB1)
}

var wifiLevels = [0xF092F, 0xF091F, 0xF0922, 0xF0925, 0xF0928]

function wifiIconFor(strength) {
  if (strength < 0) return glyph.wifiOff
  var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
  return String.fromCodePoint(wifiLevels[index])
}

// ---- nmcli terse parsing ---------------------------------------------------

// `nmcli -t` separates fields with ':' and escapes literal ':' and '\' with a
// backslash.
function splitTerse(line) {
  var out = []
  var cur = ""
  var s = String(line || "")
  for (var i = 0; i < s.length; i++) {
    var c = s[i]
    if (c === "\\" && i + 1 < s.length) { cur += s[i + 1]; i++; continue }
    if (c === ":") { out.push(cur); cur = ""; continue }
    cur += c
  }
  out.push(cur)
  return out
}

// The snapshot script prints "@name" headers; collect the lines under each.
function parseSections(text) {
  var sections = {}
  var current = null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length > 1 && line[0] === "@" && /^@[a-z]+$/.test(line)) {
      current = line.substring(1)
      sections[current] = []
    } else if (current !== null) {
      sections[current].push(line)
    }
  }
  return sections
}

function nonEmpty(lines) {
  return (lines || []).filter(function(l) { return l !== "" })
}

function parseRadio(lines) {
  var f = splitTerse(nonEmpty(lines)[0] || "")
  return { hardware: f[0] === "enabled", software: f[1] === "enabled", known: f.length >= 2 }
}

function parseDevices(lines) {
  return nonEmpty(lines).map(function(l) {
    var f = splitTerse(l)
    return { device: f[0] || "", type: f[1] || "", state: f[2] || "", connection: f[3] || "", uuid: f[4] || "" }
  })
}

function isConnectedState(state) {
  return /^connected/.test(String(state || ""))
}

function stateLabel(state) {
  var s = String(state || "")
  if (/^connected/.test(s)) return "Connected"
  if (/^connecting/.test(s)) return "Connecting…"
  if (/^deactivating/.test(s)) return "Disconnecting…"
  if (s === "unavailable") return "Cable unplugged"
  if (s === "unmanaged") return "Not managed by NetworkManager"
  return "Disconnected"
}

// Security class from nmcli's SECURITY column ("", "WPA2", "WPA2 WPA3",
// "WPA3", "OWE", "WPA2 802.1X", "WEP", ...).
function securityKind(security) {
  var s = String(security || "").trim()
  if (s === "" || s === "--") return "open"
  if (/802\.1X/i.test(s)) return "eap"
  if (/OWE/i.test(s) && !/WPA|WEP/i.test(s)) return "owe"
  if (/WEP/i.test(s)) return "wep"
  if (/WPA3/i.test(s) && !/WPA1|WPA2/i.test(s)) return "sae"
  return "psk"
}

function requiresCredentials(kind) {
  return kind !== "open" && kind !== "owe"
}

// Key management of a saved profile ("wpa-psk", "sae", "none", "wpa-eap"...).
function kindFromKeyMgmt(km) {
  var k = String(km || "")
  if (k === "" ) return "open"
  if (k === "wpa-psk") return "psk"
  if (k === "sae") return "sae"
  if (k === "owe") return "owe"
  if (k === "none") return "wep"
  if (k.indexOf("eap") !== -1 || k === "ieee8021x") return "eap"
  return "psk"
}

function securityLabel(security) {
  var s = String(security || "").trim()
  if (s === "" || s === "--") return "Open"
  return s.replace(/\s+/g, " / ")
}

function bandForFreq(mhz) {
  var v = parseFloat(mhz)
  if (!v) return ""
  if (v >= 2400 && v < 2500) return "2.4 GHz"
  if (v >= 4900 && v < 5925) return "5 GHz"
  if (v >= 5925 && v < 7125) return "6 GHz"
  if (v >= 57000 && v < 71000) return "60 GHz"
  return (v / 1000).toFixed(1) + " GHz"
}

// "uuid<TAB>key-mgmt<TAB>ssid" lines → { ssid: { uuids: [...], keyMgmt } }
function parseSaved(lines) {
  var saved = {}
  var list = nonEmpty(lines)
  for (var i = 0; i < list.length; i++) {
    var a = list[i].indexOf("\t")
    var b = a < 0 ? -1 : list[i].indexOf("\t", a + 1)
    if (a < 0 || b < 0) continue
    var uuid = list[i].substring(0, a)
    var km = list[i].substring(a + 1, b)
    var ssid = list[i].substring(b + 1)
    if (!uuid || !ssid) continue
    if (!saved[ssid]) saved[ssid] = { uuids: [], keyMgmt: km }
    saved[ssid].uuids.push(uuid)
  }
  return saved
}

// `nmcli -t -f IN-USE,SIGNAL,FREQ,DEVICE,SECURITY,SSID dev wifi list` →
// one row per SSID (strongest BSSID wins), merged with saved profiles.
// Rows are primitives only so they are safe as Repeater model data.
function buildWifiRows(lines, saved, activeSsid) {
  var bySsid = {}
  var order = []
  var list = nonEmpty(lines)
  for (var i = 0; i < list.length; i++) {
    var f = splitTerse(list[i])
    if (f.length < 6) continue
    var ssid = f.slice(5).join(":")
    if (ssid === "") continue  // hidden network beacons
    var signal = parseInt(f[1], 10) || 0
    var freq = parseInt(f[2], 10) || 0
    var inUse = f[0] === "*"
    var row = bySsid[ssid]
    if (!row) {
      row = { ssid: ssid, signal: -1, freq: 0, device: f[3] || "", security: f[4] || "", bands: [], inUse: false }
      bySsid[ssid] = row
      order.push(ssid)
    }
    var band = bandForFreq(freq)
    if (band && row.bands.indexOf(band) === -1) row.bands.push(band)
    if (inUse) { row.inUse = true; row.freq = freq; row.device = f[3] || row.device }
    if (signal > row.signal) {
      row.signal = signal
      if (!row.inUse) row.freq = freq
      row.security = f[4] || row.security
    }
  }

  var rows = []
  for (var j = 0; j < order.length; j++) {
    var r = bySsid[order[j]]
    var s = saved[r.ssid]
    var kind = securityKind(r.security)
    rows.push({
      ssid: r.ssid,
      signal: r.signal,
      band: bandForFreq(r.freq),
      bands: r.bands.slice().sort().join(", "),
      device: r.device,
      security: securityLabel(r.security),
      kind: kind,
      secured: requiresCredentials(kind),
      connected: r.inUse || (activeSsid !== "" && r.ssid === activeSsid),
      known: !!s,
      uuids: s ? s.uuids.slice() : [],
      inRange: true
    })
  }

  // Saved networks that are out of range, so they can still be forgotten.
  for (var name in saved) {
    if (bySsid[name]) continue
    var k = kindFromKeyMgmt(saved[name].keyMgmt)
    rows.push({
      ssid: name, signal: -1, band: "", bands: "", device: "",
      security: k === "open" ? "Open" : "", kind: k, secured: requiresCredentials(k),
      connected: false, known: true, uuids: saved[name].uuids.slice(), inRange: false
    })
  }

  rows.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.inRange !== b.inRange) return a.inRange ? -1 : 1
    if (a.signal !== b.signal) return b.signal - a.signal
    return a.ssid.localeCompare(b.ssid)
  })
  return rows
}

// `nmcli -t -f GENERAL.*,IP4.*,IP6.* device show` (multiline: KEY:value,
// blank line between devices) → { devName: {...} }
function parseDeviceDetails(lines) {
  var out = {}
  var cur = null
  function flush() { if (cur && cur.device) out[cur.device] = cur; cur = null }
  var list = lines || []
  for (var i = 0; i < list.length; i++) {
    var line = list[i]
    if (line === "") { flush(); continue }
    var idx = line.indexOf(":")
    if (idx < 0) continue
    var key = line.substring(0, idx).replace(/\[\d+\]$/, "")
    var value = line.substring(idx + 1).trim()
    if (key === "GENERAL.DEVICE") {
      flush()
      cur = { device: value, type: "", hwaddr: "", state: "", connection: "", uuid: "",
              ip4: [], gateway4: "", dns4: [], ip6: [], gateway6: "", dns6: [], carrier: "" }
      continue
    }
    if (!cur) continue
    if (key === "GENERAL.TYPE") cur.type = value
    else if (key === "GENERAL.HWADDR") cur.hwaddr = value
    else if (key === "GENERAL.STATE") cur.state = value.replace(/^\d+\s*\((.*)\)$/, "$1")
    else if (key === "GENERAL.CONNECTION") cur.connection = value
    else if (key === "GENERAL.CON-UUID") cur.uuid = value
    else if (key === "IP4.ADDRESS" && value) cur.ip4.push(value)
    else if (key === "IP4.GATEWAY") cur.gateway4 = value
    else if (key === "IP4.DNS" && value) cur.dns4.push(value)
    else if (key === "IP6.ADDRESS" && value) cur.ip6.push(value)
    else if (key === "IP6.GATEWAY") cur.gateway6 = value
    else if (key === "IP6.DNS" && value) cur.dns6.push(value)
    else if (key === "WIRED-PROPERTIES.CARRIER") cur.carrier = value
  }
  flush()
  return out
}

// Global and unique-local IPv6 first; link-local last.
function sortIp6(list) {
  return (list || []).slice().sort(function(a, b) {
    var la = /^fe80:/i.test(a) ? 1 : 0
    var lb = /^fe80:/i.test(b) ? 1 : 0
    return la - lb
  })
}

function parseRouteDevice(lines) {
  var text = nonEmpty(lines).join("\n")
  try {
    var data = JSON.parse(text)
    return data && data[0] && data[0].dev ? String(data[0].dev) : ""
  } catch (e) {
    return ""
  }
}

function parseSpeeds(lines) {
  var out = {}
  var list = nonEmpty(lines)
  for (var i = 0; i < list.length; i++) {
    var parts = list[i].split("\t")
    var v = parseInt(parts[1], 10)
    if (parts[0] && v > 0) out[parts[0]] = v
  }
  return out
}

function formatSpeed(mbps) {
  var v = parseInt(mbps, 10)
  if (!v || v < 0) return ""
  if (v >= 1000) return (v / 1000).toFixed(v % 1000 === 0 ? 0 : 1) + " Gbit/s"
  return v + " Mbit/s"
}

// `rfkill -J` → { devices, allBlocked, anyHard, wifiSoft, wifiHard }
function parseRfkill(lines) {
  var result = { available: false, devices: 0, allBlocked: false, anyHard: false, wifiSoft: false, wifiHard: false }
  var text = nonEmpty(lines).join("\n")
  if (!text) return result
  var data = null
  try { data = JSON.parse(text) } catch (e) { return result }
  var list = []
  for (var k in data) if (Array.isArray(data[k])) list = list.concat(data[k])
  result.available = list.length > 0
  result.devices = list.length
  var blocked = 0
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    var soft = d.soft === "blocked"
    var hard = d.hard === "blocked"
    if (soft || hard) blocked++
    if (hard) result.anyHard = true
    if (d.type === "wlan") {
      if (soft) result.wifiSoft = true
      if (hard) result.wifiHard = true
    }
  }
  result.allBlocked = list.length > 0 && blocked === list.length
  return result
}

function parseTailscale(lines) {
  var list = nonEmpty(lines)
  if (list.length === 0 || list[0] !== "installed") return { installed: false }
  var info = { installed: true, state: "", host: "", ips: [], tailnet: "" }
  if (list.length > 1) {
    try {
      var d = JSON.parse(list.slice(1).join("\n"))
      info.state = String(d.state || "")
      info.host = String(d.host || "")
      info.ips = Array.isArray(d.ips) ? d.ips : []
      info.tailnet = String(d.tailnet || "")
    } catch (e) {}
  }
  return info
}

function tailscaleSummary(ts) {
  if (!ts || !ts.installed) return "Not installed"
  switch (ts.state) {
  case "Running": return "Connected" + (ts.host ? " as " + ts.host : "")
  case "Stopped": return "Turned off"
  case "NeedsLogin": return "Signed out"
  case "NeedsMachineAuth": return "Waiting for admin approval"
  case "Starting": return "Connecting…"
  case "": return "Service not running"
  default: return ts.state
  }
}

// ---- passwords -------------------------------------------------------------

// Returns "" when the secret is acceptable for the security kind, otherwise
// a short hint.
function passwordProblem(kind, pw) {
  var s = String(pw || "")
  if (kind === "psk") {
    if (s.length === 64 && /^[0-9a-f]+$/i.test(s)) return ""
    if (s.length < 8) return "At least 8 characters"
    if (s.length > 63) return "At most 63 characters"
    return ""
  }
  if (kind === "sae") return s.length > 0 ? "" : "Enter the password"
  if (kind === "wep") {
    if (s.length === 5 || s.length === 13) return ""
    if ((s.length === 10 || s.length === 26) && /^[0-9a-f]+$/i.test(s)) return ""
    return "WEP keys are 5/13 characters or 10/26 hex digits"
  }
  if (kind === "eap") return s.length > 0 ? "" : "Enter the password"
  return ""
}

function looksLikeAuthFailure(stderr) {
  return /secrets were required|no secrets|802-1x supplicant|password|psk|authentication/i.test(String(stderr || ""))
}

function cleanError(stderr, fallback) {
  var s = String(stderr || "").trim()
  s = s.replace(/^Error:\s*/i, "")
  return s !== "" ? s : (fallback || "Command failed")
}

// ---- scripts ----------------------------------------------------------------

// Read-only snapshot of everything the page shows. Sections are "@name".
var snapshotScript = [
  "export LC_ALL=C",
  "echo @radio; nmcli -t -f WIFI-HW,WIFI radio 2>/dev/null",
  "echo @devices; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION,CON-UUID device status 2>/dev/null",
  "echo @wifi; nmcli -t -f IN-USE,SIGNAL,FREQ,DEVICE,SECURITY,SSID device wifi list --rescan no 2>/dev/null",
  "echo @saved",
  "nmcli -t -f UUID,TYPE connection show 2>/dev/null | while IFS=: read -r u t; do",
  "  [ \"$t\" = 802-11-wireless ] || continue",
  "  mapfile -t f < <(nmcli --escape no -g 802-11-wireless.ssid,802-11-wireless-security.key-mgmt connection show uuid \"$u\" 2>/dev/null)",
  "  printf '%s\\t%s\\t%s\\n' \"$u\" \"${f[1]:-}\" \"${f[0]:-}\"",
  "done",
  "echo @details; nmcli -t -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.HWADDR,GENERAL.STATE,GENERAL.CONNECTION,GENERAL.CON-UUID,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS,WIRED-PROPERTIES.CARRIER device show 2>/dev/null",
  "echo @route; ip -j route get 1.1.1.1 2>/dev/null; echo",
  "echo @speed",
  "for d in /sys/class/net/*; do [ -d \"$d/wireless\" ] && continue; s=$(cat \"$d/speed\" 2>/dev/null) && printf '%s\\t%s\\n' \"${d##*/}\" \"$s\"; done",
  "echo @rfkill; command -v rfkill >/dev/null && rfkill -J 2>/dev/null",
  "echo @dns; omarchy-dns 2>/dev/null",
  "echo @tailscale",
  "if command -v tailscale >/dev/null; then echo installed;",
  "  timeout 3 tailscale status --json 2>/dev/null | jq -c '{state: .BackendState, host: (.Self.HostName // \"\"), ips: (.Self.TailscaleIPs // []), tailnet: (.CurrentTailnet.Name // \"\")}' 2>/dev/null",
  "fi",
  "exit 0"
].join("\n")

// Connect with a secret read from stdin (never argv: argv is world-readable
// in /proc; printf is a builtin, so no process is spawned with it either).
// Same technique as Omarchy's enterprise connect script.
//   $1 ssid  $2 kind (open|owe|psk|sae|wep|eap)  $3 hidden (yes|no)  $4 existing uuid or ""
// (eap only with an existing uuid: it replaces the saved 802.1X password.)
// A profile created here is deleted again if activation fails.
var secretConnectScript = [
  "IFS= read -r pw || true",
  "ssid=$1; kind=$2; hidden=$3; u=$4; created=0",
  "fail() { [ \"$created\" = 1 ] && nmcli connection delete uuid \"$u\" >/dev/null 2>&1; exit 1; }",
  "if [ -z \"$u\" ]; then",
  "  u=$(cat /proc/sys/kernel/random/uuid)",
  "  args=(type wifi con-name \"$ssid\" ssid \"$ssid\" connection.uuid \"$u\")",
  "  [ \"$hidden\" = yes ] && args+=(802-11-wireless.hidden yes)",
  "  case \"$kind\" in",
  "    psk) args+=(802-11-wireless-security.key-mgmt wpa-psk) ;;",
  "    sae) args+=(802-11-wireless-security.key-mgmt sae) ;;",
  "    owe) args+=(802-11-wireless-security.key-mgmt owe) ;;",
  "    wep) args+=(802-11-wireless-security.key-mgmt none 802-11-wireless-security.wep-key-type key) ;;",
  "  esac",
  "  nmcli connection add \"${args[@]}\" </dev/null >/dev/null || exit 1",
  "  created=1",
  "fi",
  "case \"$kind\" in",
  "  psk|sae) key=802-11-wireless-security.psk ;;",
  "  wep) key=802-11-wireless-security.wep-key0 ;;",
  "  eap) key=802-1x.password ;;",
  "  *) key= ;;",
  "esac",
  "if [ -n \"$key\" ]; then",
  "  printf 'set %s %s\\nsave\\nquit\\n' \"$key\" \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null 2>&1 || fail",
  "fi",
  "nmcli --wait 45 connection up uuid \"$u\" </dev/null >/dev/null || fail"
].join("\n")

// PEAP/MSCHAPv2, copied from Omarchy's network panel.
//   $1 ssid  $2 identity ; password on stdin
var enterpriseConnectScript =
  "u=$(cat /proc/sys/kernel/random/uuid); IFS= read -r pw;" +
  " nmcli connection add type wifi con-name \"$1\" ssid \"$1\" connection.uuid \"$u\"" +
  " wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2" +
  " 802-1x.identity \"$2\" 802-1x.auth-timeout 8 </dev/null >/dev/null" +
  " && printf 'set 802-1x.password %s\\nsave\\nquit\\n' \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null" +
  " && nmcli --wait 45 connection up uuid \"$u\" </dev/null >/dev/null" +
  " || { nmcli connection delete uuid \"$u\" >/dev/null 2>&1; false; }"

// Delete every saved profile passed as "$@".
var forgetScript = "rc=0; for u in \"$@\"; do nmcli connection delete uuid \"$u\" >/dev/null || rc=1; done; exit $rc"
