.pragma library

// Pure helpers for the Keyboard & Mouse page. No QML, no I/O — tested by
// tools/tests/InputLogicTest.qml.

// ---- options --------------------------------------------------------------
// Every setting the page manages. `lua` is the path inside hl.config({ input
// = ... }), `opt` the `hyprctl getoption input:<opt>` name (they differ for
// hyphenated legacy names), `type` drives parsing.
var OPTIONS = [
  { lua: "kb_layout", opt: "kb_layout", type: "string" },
  { lua: "kb_variant", opt: "kb_variant", type: "string" },
  { lua: "kb_options", opt: "kb_options", type: "string" },
  { lua: "repeat_rate", opt: "repeat_rate", type: "int" },
  { lua: "repeat_delay", opt: "repeat_delay", type: "int" },
  { lua: "numlock_by_default", opt: "numlock_by_default", type: "bool" },
  { lua: "sensitivity", opt: "sensitivity", type: "float" },
  { lua: "accel_profile", opt: "accel_profile", type: "string" },
  { lua: "natural_scroll", opt: "natural_scroll", type: "bool" },
  { lua: "scroll_factor", opt: "scroll_factor", type: "float" },
  { lua: "left_handed", opt: "left_handed", type: "bool" },
  { lua: "touchpad.natural_scroll", opt: "touchpad:natural_scroll", type: "bool" },
  { lua: "touchpad.tap_to_click", opt: "touchpad:tap-to-click", type: "bool" },
  { lua: "touchpad.disable_while_typing", opt: "touchpad:disable_while_typing", type: "bool" },
  { lua: "touchpad.scroll_factor", opt: "touchpad:scroll_factor", type: "float" },
  { lua: "touchpad.clickfinger_behavior", opt: "touchpad:clickfinger_behavior", type: "bool" },
  { lua: "touchpad.drag_3fg", opt: "touchpad:drag_3fg", type: "int" }
]

function optionNames() {
  return OPTIONS.map(function(o) { return o.opt })
}

function luaKeyForOpt(opt) {
  for (var i = 0; i < OPTIONS.length; i++) if (OPTIONS[i].opt === opt) return OPTIONS[i].lua
  return opt.replace(/:/g, ".").replace(/-/g, "_")
}

// One `hyprctl getoption input:x -j` object -> JS value.
function optionValue(obj) {
  if (!obj || typeof obj !== "object") return undefined
  if ("str" in obj) return obj.str === "[[EMPTY]]" ? "" : String(obj.str)
  if ("bool" in obj) return obj.bool === true
  if ("int" in obj) return Number(obj.int)
  if ("float" in obj) return Math.round(Number(obj.float) * 1000) / 1000
  return undefined
}

// Output of one JSON object per line -> { "<lua path>": value }.
function parseLiveOptions(text) {
  var out = ({})
  String(text || "").split("\n").forEach(function(line) {
    line = line.trim()
    if (!line) return
    var obj = null
    try { obj = JSON.parse(line) } catch (e) { return }
    if (!obj || !obj.option) return
    var opt = String(obj.option).replace(/^input:/, "")
    var v = optionValue(obj)
    if (v !== undefined) out[luaKeyForOpt(opt)] = v
  })
  return out
}

// ---- nested paths ---------------------------------------------------------
function getPath(obj, path) {
  var parts = path.split(".")
  var cur = obj
  for (var i = 0; i < parts.length; i++) {
    if (!cur || typeof cur !== "object" || !(parts[i] in cur)) return undefined
    cur = cur[parts[i]]
  }
  return cur
}

// Returns a deep copy of `obj` with `path` set (value === undefined removes it).
function setPath(obj, path, value) {
  var copy = JSON.parse(JSON.stringify(obj || {}))
  var parts = path.split(".")
  var cur = copy
  for (var i = 0; i < parts.length - 1; i++) {
    if (!cur[parts[i]] || typeof cur[parts[i]] !== "object") cur[parts[i]] = {}
    cur = cur[parts[i]]
  }
  if (value === undefined) delete cur[parts[parts.length - 1]]
  else cur[parts[parts.length - 1]] = value
  // prune empty tables
  for (var j = parts.length - 2; j >= 0; j--) {
    var parent = copy
    for (var k = 0; k < j; k++) parent = parent[parts[k]]
    if (parent[parts[j]] && Object.keys(parent[parts[j]]).length === 0) delete parent[parts[j]]
  }
  return copy
}

// ---- Lua rendering --------------------------------------------------------
function luaString(s) {
  return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
}

function luaKey(k) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "[" + luaString(k) + "]"
}

function luaScalar(v) {
  if (typeof v === "boolean") return v ? "true" : "false"
  if (typeof v === "number") return String(Math.round(v * 1000) / 1000)
  return luaString(v)
}

function _order(keys) {
  var rank = ({})
  OPTIONS.forEach(function(o, i) { rank[o.lua.split(".").pop()] = i })
  return keys.slice().sort(function(a, b) {
    var ra = a in rank ? rank[a] : 999, rb = b in rank ? rank[b] : 999
    return ra !== rb ? ra - rb : (a < b ? -1 : a > b ? 1 : 0)
  })
}

function _renderTable(obj, indent) {
  var pad = new Array(indent + 1).join("  ")
  var lines = []
  _order(Object.keys(obj)).forEach(function(k) {
    var v = obj[k]
    if (v === undefined || v === null) return
    if (typeof v === "object") {
      lines.push(pad + luaKey(k) + " = {")
      lines = lines.concat(_renderTable(v, indent + 1))
      lines.push(pad + "},")
    } else {
      lines.push(pad + luaKey(k) + " = " + luaScalar(v) + ",")
    }
  })
  return lines
}

// { input: {...} } -> multi-line `hl.config({ ... })`, or "" when empty.
function renderConfig(cfg) {
  if (!cfg || Object.keys(cfg).length === 0) return ""
  return ["hl.config({"].concat(_renderTable(cfg, 1)).concat(["})"]).join("\n")
}

// One-line Lua for a live `hyprctl eval`.
function liveLua(path, value) {
  var map = ({})
  map[path] = value
  return liveLuaMany(map)
}

// { "touchpad.natural_scroll": true, sensitivity: 0.2 } -> one hl.config call.
function liveLuaMany(map) {
  var cfg = ({})
  for (var p in map) cfg = setPath(cfg, "input." + p, map[p])
  if (!cfg.input) return ""
  return "hl.config(" + _inline(cfg) + ")"
}

function _inline(obj) {
  var parts = []
  _order(Object.keys(obj)).forEach(function(k) {
    var v = obj[k]
    parts.push(luaKey(k) + " = " + (typeof v === "object" ? _inline(v) : luaScalar(v)))
  })
  return "{ " + parts.join(", ") + " }"
}

// ---- Lua parsing (the subset renderConfig writes) ------------------------
// Parses the first `hl.config({...})` table in `text`. Returns {} if there is
// none or it can't be parsed — the block is ours, so we only need to read
// back what we wrote, but hand edits with comments/odd spacing still work.
function parseConfig(text) {
  var src = String(text || "").replace(/--[^\n]*/g, "")
  var start = src.indexOf("hl.config(")
  if (start < 0) return {}
  var pos = src.indexOf("{", start)
  if (pos < 0) return {}
  var i = pos

  function ws() { while (i < src.length && /\s/.test(src[i])) i++ }
  function str() {
    var q = src[i]; i++
    var out = ""
    while (i < src.length && src[i] !== q) {
      if (src[i] === "\\") {
        i++
        var c = src[i]
        out += c === "n" ? "\n" : c === "t" ? "\t" : c
      } else out += src[i]
      i++
    }
    i++
    return out
  }
  function value() {
    ws()
    var c = src[i]
    if (c === "{") return table()
    if (c === "\"" || c === "'") return str()
    var m = /^(true|false|nil|-?[0-9]*\.?[0-9]+(?:e-?[0-9]+)?)/.exec(src.slice(i))
    if (!m) throw new Error("bad value at " + i)
    i += m[0].length
    if (m[0] === "true") return true
    if (m[0] === "false") return false
    if (m[0] === "nil") return null
    return Number(m[0])
  }
  function table() {
    i++ // {
    var obj = ({})
    for (;;) {
      ws()
      if (src[i] === "}") { i++; return obj }
      var key
      if (src[i] === "[") {
        i++; ws(); key = str(); ws()
        if (src[i] !== "]") throw new Error("expected ]")
        i++
      } else {
        var m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(src.slice(i))
        if (!m) throw new Error("expected key at " + i)
        key = m[0]; i += key.length
      }
      ws()
      if (src[i] !== "=") throw new Error("expected = at " + i)
      i++
      var v = value()
      if (v !== null) obj[key] = v
      ws()
      if (src[i] === "," || src[i] === ";") i++
      if (i >= src.length) throw new Error("unterminated table")
    }
  }
  try { return table() } catch (e) { return {} }
}

// ---- layouts --------------------------------------------------------------
// "de,us" + ",intl" -> [{layout:"de",variant:""},{layout:"us",variant:"intl"}]
function parseLayouts(layoutStr, variantStr) {
  var ls = String(layoutStr || "").split(",")
  var vs = String(variantStr || "").split(",")
  var out = []
  for (var i = 0; i < ls.length; i++) {
    var l = ls[i].trim()
    if (!l) continue
    out.push({ layout: l, variant: (vs[i] || "").trim() })
  }
  return out
}

function joinLayouts(list) {
  var hasVariant = list.some(function(x) { return x.variant })
  return {
    kb_layout: list.map(function(x) { return x.layout }).join(","),
    kb_variant: hasVariant ? list.map(function(x) { return x.variant || "" }).join(",") : ""
  }
}

function moveItem(list, from, to) {
  var copy = list.slice()
  if (from < 0 || from >= copy.length || to < 0 || to >= copy.length) return copy
  var item = copy.splice(from, 1)[0]
  copy.splice(to, 0, item)
  return copy
}

// Same list Omarchy keeps in default/hypr/input.lua: these can't type Latin
// letters, so Latin keysym bindings break when they come first.
var NON_LATIN = " af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua "
function isNonLatin(layout) {
  return NON_LATIN.indexOf(" " + layout + " ") !== -1
}

// /usr/share/X11/xkb/rules/base.lst -> { layouts: [{value,label,description}],
// variants: { de: [{value,label}] } }
function parseXkbRules(text) {
  var layouts = []
  var variants = ({})
  var section = ""
  String(text || "").split("\n").forEach(function(line) {
    var h = /^!\s+(\w+)/.exec(line)
    if (h) { section = h[1]; return }
    var m = /^\s+(\S+)\s+(.*)$/.exec(line)
    if (!m) return
    if (section === "layout") {
      layouts.push({ value: m[1], label: m[2].trim(), description: m[1] })
    } else if (section === "variant") {
      var v = /^([^:]+):\s*(.*)$/.exec(m[2])
      if (!v) return
      var lay = v[1].trim()
      if (!variants[lay]) variants[lay] = []
      variants[lay].push({ value: m[1], label: v[2].trim() })
    }
  })
  layouts.sort(function(a, b) { return a.label.localeCompare(b.label) })
  return { layouts: layouts, variants: variants }
}

function layoutLabel(rules, layout, variant) {
  var name = layout
  if (rules && rules.layouts) {
    for (var i = 0; i < rules.layouts.length; i++) {
      if (rules.layouts[i].value === layout) { name = rules.layouts[i].label; break }
    }
  }
  if (variant && rules && rules.variants && rules.variants[layout]) {
    var vs = rules.variants[layout]
    for (var j = 0; j < vs.length; j++) if (vs[j].value === variant) return vs[j].label
  }
  return variant ? name + " (" + variant + ")" : name
}

// ---- kb_options -----------------------------------------------------------
var CAPS_OPTIONS = [
  { value: "", label: "Caps Lock" },
  { value: "ctrl:nocaps", label: "Ctrl" },
  { value: "caps:escape", label: "Escape" },
  { value: "caps:escape_shifted_capslock", label: "Escape (Shift for Caps Lock)" },
  { value: "caps:swapescape", label: "Swap with Escape" },
  { value: "ctrl:swapcaps", label: "Swap with Ctrl" },
  { value: "caps:backspace", label: "Backspace" },
  { value: "caps:none", label: "Disabled" }
]

var COMPOSE_OPTIONS = [
  { value: "", label: "None" },
  { value: "compose:caps", label: "Caps Lock" },
  { value: "compose:ralt", label: "Right Alt" },
  { value: "compose:rwin", label: "Right Super" },
  { value: "compose:rctrl", label: "Right Ctrl" },
  { value: "compose:menu", label: "Menu" },
  { value: "compose:prsc", label: "Print Screen" }
]

var SWITCH_OPTIONS = [
  { value: "", label: "None" },
  { value: "grp:alts_toggle", label: "Both Alts together" },
  { value: "grp:alt_shift_toggle", label: "Alt + Shift" },
  { value: "grp:ctrl_shift_toggle", label: "Ctrl + Shift" },
  { value: "grp:win_space_toggle", label: "Super + Space" },
  { value: "grp:ctrl_alt_toggle", label: "Ctrl + Alt" },
  { value: "grp:shifts_toggle", label: "Both Shifts together" },
  { value: "grp:caps_toggle", label: "Caps Lock" }
]

var BOTH_SHIFTS = "shift:both_capslock_cancel"

function _values(list) { return list.map(function(o) { return o.value }) }

// "compose:caps,shift:both_capslock_cancel,grp:alts_toggle,foo:bar" ->
// { caps, compose, layoutSwitch, bothShifts, other: [...] }
function parseKbOptions(str) {
  var model = { caps: "", compose: "", layoutSwitch: "", bothShifts: false, other: [] }
  var caps = _values(CAPS_OPTIONS), compose = _values(COMPOSE_OPTIONS)
  String(str || "").split(",").forEach(function(o) {
    o = o.trim()
    if (!o) return
    if (o === BOTH_SHIFTS) model.bothShifts = true
    else if (/^compose:/.test(o) && !model.compose && compose.indexOf(o) !== -1) model.compose = o
    else if (/^grp:/.test(o) && !model.layoutSwitch) model.layoutSwitch = o
    else if (!model.caps && caps.indexOf(o) !== -1 && o) model.caps = o
    else model.other.push(o)
  })
  return model
}

function buildKbOptions(model) {
  var out = []
  if (model.compose) out.push(model.compose)
  // Caps Lock can only do one thing; compose wins.
  if (model.caps && model.compose !== "compose:caps") out.push(model.caps)
  if (model.bothShifts) out.push(BOTH_SHIFTS)
  if (model.layoutSwitch) out.push(model.layoutSwitch)
  ;(model.other || []).forEach(function(o) { if (out.indexOf(o) === -1) out.push(o) })
  return out.join(",")
}

function withKbOption(str, field, value) {
  var m = parseKbOptions(str)
  m[field] = value
  return buildKbOptions(m)
}

// ---- devices --------------------------------------------------------------
// Same detection as `omarchy-hw-touchpad`.
function findTouchpad(devices) {
  var mice = (devices && devices.mice) || []
  for (var i = 0; i < mice.length; i++) {
    if (/touchpad|trackpad/i.test(mice[i].name || "")) return mice[i].name
  }
  return ""
}

function mice(devices) {
  return ((devices && devices.mice) || []).filter(function(m) {
    return !/touchpad|trackpad/i.test(m.name || "")
  }).map(function(m) { return m.name })
}

function round(v, step) {
  var s = step || 0.05
  return Math.round(Math.round(v / s) * s * 1000) / 1000
}
