.pragma library

// Pure helpers for the Bluetooth page. Adapted from Omarchy's built-in
// bluetooth panel (/usr/share/omarchy/shell/plugins/panels/bluetooth/Model.js).

function glyph(cp) { return String.fromCodePoint(cp) }

var G = {
  bluetooth: 0xF00AF,
  connected: 0xF00B1,
  off: 0xF00B2,
  headphones: 0xF02CB,
  headset: 0xF02CE,
  speaker: 0xF04C3,
  keyboard: 0xF030C,
  mouse: 0xF037D,
  gamepad: 0xF0297,
  phone: 0xF011C,
  laptop: 0xF0322,
  tablet: 0xF04F6,
  watch: 0xF0897,
  printer: 0xF042A,
  monitor: 0xF0379,
  camera: 0xF0100,
  remove: 0xF0159
}

function deviceLabel(device) {
  if (!device) return ""
  return String(device.deviceName || device.name || "").trim()
}

function toArray(values) {
  if (!values) return []
  if (Array.isArray(values)) return values.slice()
  var length = Number(values.length || 0)
  if (!isFinite(length) || length <= 0) return []
  var list = []
  for (var i = 0; i < length; i++) list.push(values[i])
  return list
}

function isUuidLike(value) {
  var text = String(value || "").trim()
  if (text === "") return false
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)
    || /^[0-9a-f]{32}$/i.test(text)
    || /^0x[0-9a-f]{4,32}$/i.test(text)
}

function isAddressLike(value) {
  return /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(String(value || "").trim())
}

function normalizedAddress(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

function hasHumanName(device) {
  var label = deviceLabel(device)
  return label !== "" && !isUuidLike(label) && !isAddressLike(label)
}

function isKnown(d) {
  return !!(d && (d.paired || d.bonded || d.trusted))
}

// Primitives-only projection of a BlueZ device for delegates. Holding the
// Device QObject in model data can dangle when BlueZ drops the device while
// a delegate incubates (see the built-in panel); actions look it up by address.
function deviceRow(d) {
  if (!d) return null
  return {
    address: String(d.address || ""),
    label: deviceLabel(d) || String(d.address || "Device"),
    icon: String(d.icon || ""),
    connected: !!d.connected,
    known: isKnown(d),
    state: d.state !== undefined ? Number(d.state) : -1,
    pairing: !!d.pairing,
    batteryAvailable: !!d.batteryAvailable,
    battery: d.battery !== undefined ? Number(d.battery) : 0
  }
}

function byConnectedThenName(a, b) {
  if (a.connected !== b.connected) return a.connected ? -1 : 1
  return a.label.localeCompare(b.label)
}

// { known: [row], nearby: [row] }
function deviceLists(devices) {
  var values = toArray(devices)
  var known = []
  var nearby = []
  for (var i = 0; i < values.length; i++) {
    var d = values[i]
    if (!d) continue
    if (isKnown(d)) known.push(deviceRow(d))
    else if (hasHumanName(d)) nearby.push(deviceRow(d))
  }
  known.sort(byConnectedThenName)
  nearby.sort(byConnectedThenName)
  return { known: known, nearby: nearby }
}

// BlueZ exposes a freedesktop icon name per device class.
function deviceGlyph(icon, connected) {
  var name = String(icon || "")
  if (name === "audio-headset") return glyph(G.headset)
  if (name === "audio-headphones") return glyph(G.headphones)
  if (name.indexOf("audio") === 0 || name === "multimedia-player") return glyph(G.speaker)
  if (name === "input-keyboard") return glyph(G.keyboard)
  if (name === "input-mouse") return glyph(G.mouse)
  if (name === "input-gaming") return glyph(G.gamepad)
  if (name === "input-tablet") return glyph(G.tablet)
  if (name.indexOf("phone") === 0) return glyph(G.phone)
  if (name === "computer") return glyph(G.laptop)
  if (name === "video-display") return glyph(G.monitor)
  if (name.indexOf("camera") === 0) return glyph(G.camera)
  if (name === "printer" || name === "scanner") return glyph(G.printer)
  if (name.indexOf("watch") !== -1) return glyph(G.watch)
  return glyph(connected ? G.connected : G.bluetooth)
}

function typeName(icon) {
  var name = String(icon || "")
  var map = {
    "audio-headset": "Headset", "audio-headphones": "Headphones", "audio-card": "Speaker",
    "input-keyboard": "Keyboard", "input-mouse": "Mouse", "input-gaming": "Game controller",
    "input-tablet": "Tablet", "phone": "Phone", "computer": "Computer",
    "video-display": "Display", "printer": "Printer", "camera-video": "Camera", "camera-photo": "Camera"
  }
  return map[name] || ""
}

// Device state enum: 0 Disconnected, 1 Connected, 2 Disconnecting, 3 Connecting.
function statusText(row, pending) {
  if (!row) return ""
  if (pending === "pairing" || row.pairing) return "Pairing…"
  if (pending === "forgetting") return "Removing…"
  if (pending === "disconnecting" || row.state === 2) return "Disconnecting…"
  if (pending === "connecting" || row.state === 3) return "Connecting…"
  var parts = []
  if (row.connected) parts.push("Connected")
  else if (row.known) parts.push("Not connected")
  else {
    var t = typeName(row.icon)
    if (t) parts.push(t)
  }
  if (row.connected && row.batteryAvailable) parts.push("Battery " + Math.round(row.battery * 100) + "%")
  return parts.join(" · ")
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

// A PipeWire sink that belongs to `address` (bluez_output.AA_BB_…).
function bluetoothSinkMatches(node, address) {
  if (!node || !node.isSink || node.isStream) return false
  var want = normalizedAddress(address)
  if (want === "") return false
  var p = nodeProps(node)
  var text = [node.name, node.description, p["api.bluez5.address"], p["device.string"]].join(" ")
  return normalizedAddress(text).indexOf(want) !== -1
}

function cloneMap(map) {
  var next = ({})
  for (var key in map || {}) next[key] = map[key]
  return next
}
