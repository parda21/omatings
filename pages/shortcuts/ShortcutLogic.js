.pragma library

// Pure helpers for the Shortcuts page. No QML, no I/O — tested by
// tools/tests/ShortcutLogicTest.qml.

// ---- modifiers ------------------------------------------------------------
var MOD_BITS = { SHIFT: 1, CAPS: 2, CTRL: 4, CONTROL: 4, ALT: 8, MOD2: 16, MOD3: 32, SUPER: 64, WIN: 64, LOGO: 64, MOD4: 64, MOD5: 128 }
// Display/write order.
var MOD_ORDER = ["SUPER", "CTRL", "ALT", "SHIFT"]

function modmaskToNames(mask) {
  var out = []
  if (mask & 64) out.push("SUPER")
  if (mask & 4) out.push("CTRL")
  if (mask & 8) out.push("ALT")
  if (mask & 1) out.push("SHIFT")
  if (mask & 128) out.push("MOD5")
  return out
}

function namesToModmask(names) {
  var m = 0
  ;(names || []).forEach(function(n) { m |= (MOD_BITS[String(n).toUpperCase()] || 0) })
  return m
}

// "SUPER + SHIFT + code:10" -> { modmask: 65, key: "code:10" }
function splitCombo(str) {
  var parts = String(str || "").split("+").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
  var mask = 0, key = ""
  parts.forEach(function(p) {
    var bit = MOD_BITS[p.toUpperCase()]
    if (bit !== undefined) mask |= bit
    else key = p
  })
  return { modmask: mask, key: key }
}

function comboString(modmask, key) {
  return modmaskToNames(modmask).concat([key]).join(" + ")
}

// ---- key names ------------------------------------------------------------
// xkb keycodes Omarchy binds by code (digit row etc.). Used for display and to
// compare `code:N` with named keys.
var CODE_NAMES = {
  10: "1", 11: "2", 12: "3", 13: "4", 14: "5", 15: "6", 16: "7", 17: "8", 18: "9", 19: "0",
  20: "MINUS", 21: "EQUAL", 34: "BRACKETLEFT", 35: "BRACKETRIGHT", 47: "SEMICOLON",
  48: "APOSTROPHE", 49: "GRAVE", 51: "BACKSLASH", 59: "COMMA", 60: "PERIOD", 61: "SLASH", 94: "LESS"
}
var MOUSE_NAMES = { 272: "Left click", 273: "Right click", 274: "Middle click", 275: "Mouse back", 276: "Mouse forward" }

var KEY_ALIASES = { ENTER: "RETURN", ESC: "ESCAPE", DEL: "DELETE", PGUP: "PRIOR", PAGE_UP: "PRIOR", PGDN: "NEXT", PAGE_DOWN: "NEXT", PRINT: "PRINT", BACKSPACE: "BACKSPACE" }

// Canonical form for comparing keys from hyprctl, our captures and Lua source.
function normalizeKey(key) {
  var k = String(key || "").trim()
  var m = /^code:(\d+)$/i.exec(k)
  if (m) return CODE_NAMES[m[1]] || ("CODE:" + m[1])
  k = k.toUpperCase()
  return KEY_ALIASES[k] || k
}

function comboId(modmask, key) {
  return (modmask & ~2 & ~16) + "|" + normalizeKey(key)
}

function comboIdFromString(str) {
  var c = splitCombo(str)
  return comboId(c.modmask, c.key)
}

function keyLabel(key) {
  var k = String(key || "")
  var m = /^code:(\d+)$/i.exec(k)
  if (m) return CODE_NAMES[m[1]] || k
  m = /^mouse:(\d+)$/i.exec(k)
  if (m) return MOUSE_NAMES[m[1]] || k
  if (/^XF86/i.test(k)) return k.replace(/^XF86/i, "").replace(/([a-z])([A-Z])/g, "$1 $2")
  if (k.length === 1) return k.toUpperCase()
  var pretty = { RETURN: "Enter", PRIOR: "Page Up", NEXT: "Page Down", SPACE: "Space", ESCAPE: "Esc", TAB: "Tab",
                 BACKSPACE: "Backspace", DELETE: "Delete", PRINT: "Print", HOME: "Home", END: "End",
                 LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓", SLASH: "/", COMMA: ",", PERIOD: ".",
                 MINUS: "-", EQUAL: "=", MOUSE_DOWN: "Scroll down", MOUSE_UP: "Scroll up" }
  var u = k.toUpperCase()
  if (pretty[u]) return pretty[u]
  return k.charAt(0).toUpperCase() + k.slice(1).toLowerCase()
}

// ["SUPER","SHIFT","F"] style parts for keycap chips.
function comboParts(modmask, key) {
  var mods = modmaskToNames(modmask).map(function(n) {
    return { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift", MOD5: "AltGr" }[n] || n
  })
  return mods.concat([keyLabel(key)])
}

function comboLabel(modmask, key) {
  return comboParts(modmask, key).join(" + ")
}

// ---- hyprctl binds (plain text) ------------------------------------------
// Parsed from the text output instead of -j: Omarchy notes that Hyprland
// 0.56.0 emits invalid JSON for binds.
function parseBindsText(text) {
  var out = []
  var cur = null
  String(text || "").split("\n").forEach(function(line) {
    var head = /^bind([a-z]*)\s*$/.exec(line)
    if (head) {
      if (cur) out.push(cur)
      cur = { flags: head[1], modmask: 0, submap: "", key: "", keycode: 0, description: "", dispatcher: "", arg: "" }
      return
    }
    if (!cur) return
    var f = /^\t([a-z_]+): ?(.*)$/.exec(line)
    if (!f) return
    var v = f[2]
    if (f[1] === "modmask") cur.modmask = Number(v) || 0
    else if (f[1] === "keycode") cur.keycode = Number(v) || 0
    else cur[f[1]] = v
  })
  if (cur) out.push(cur)
  out.forEach(function(b) {
    // Lua binds report the full display key ("SUPER + code:10").
    var k = String(b.key || "")
    var idx = k.lastIndexOf(" + ")
    if (idx !== -1) k = k.slice(idx + 3)
    if (!k && b.keycode) k = "code:" + b.keycode
    b.key = k.trim()
    b.mouse = b.flags.indexOf("m") !== -1 || /^mouse/i.test(b.key)
    b.locked = b.flags.indexOf("l") !== -1
    b.id = comboId(b.modmask, b.key)
    b.combo = comboString(b.modmask, b.key)
  })
  return out
}

// Lines "modmask,description,key<US>kind<US>arg" from Omarchy's Lua source
// scan -> lookup { "<modmask>|<description>|<KEY>": {kind,arg} }.
function parseActionCache(text) {
  var map = ({})
  String(text || "").split("\n").forEach(function(line) {
    if (!line) return
    var parts = line.split("\x1f")
    if (parts.length < 3) return
    var k = parts[0]
    var first = k.indexOf(","), last = k.lastIndexOf(",")
    if (first < 0 || last <= first) return
    var modmask = Number(k.slice(0, first)) || 0
    var desc = k.slice(first + 1, last)
    var key = k.slice(last + 1)
    map[modmask + "|" + desc + "|" + normalizeKey(key)] = { kind: parts[1], arg: parts.slice(2).join("\x1f") }
  })
  return map
}

function lookupAction(cache, bind) {
  if (!cache) return null
  return cache[bind.modmask + "|" + bind.description + "|" + normalizeKey(bind.key)] || null
}

// Human readable action ("chromium", "hl.dsp.window.close()").
function actionLabel(action) {
  if (!action) return ""
  var a = String(action.arg || "")
  if (action.kind === "exec") {
    a = a.replace(/^uwsm(-app| app) -- /, "")
    var m = /^omarchy-launch-or-focus(?:-webapp)? '[^']*' '(.*)'$/.exec(a)
    if (m) a = m[1].replace(/^uwsm(-app| app) -- /, "")
    m = /^omarchy-launch-webapp '(.*)'$/.exec(a)
    if (m) a = m[1]
    return a.replace(/^~\/\.local\/share\/omarchy\/bin\//, "")
  }
  return a
}

// ---- grouping -------------------------------------------------------------
var GROUP_ORDER = ["Custom", "Your bindings", "Apps", "Menus & panels", "Windows", "Workspaces", "Clipboard",
                   "Capture", "Notifications", "Media & hardware", "System"]

function category(bind, action) {
  if (bind.custom) return "Custom"
  if (bind.user) return "Your bindings"
  var d = String(bind.description || "")
  var a = action ? String(action.arg || "") : ""
  if (/^XF86/i.test(bind.key)) return "Media & hardware"
  if (/workspace/i.test(d)) return "Workspaces"
  if (/copy|paste|cut|clipboard/i.test(d)) return "Clipboard"
  if (/window|focus|group|full ?screen|full width|scratchpad|split|resize|swap|float|pseudo|pop /i.test(d) || bind.mouse) return "Windows"
  if (/notification|reminder/i.test(d)) return "Notifications"
  if (/screenshot|screenrecord|color picker|ocr|dictation|share|transcode|webcam/i.test(d)) return "Capture"
  if (/menu|panel|keybindings|switcher/i.test(d) || /omarchy-shell shell toggle|omarchy-menu|walker/.test(a)) return "Menus & panels"
  if (/omarchy-launch-|uwsm-app|uwsm app/.test(a)) return "Apps"
  return "System"
}

// binds: parsed hyprctl binds (with .action), query: search string.
// -> [{ title, items: [...] }] in GROUP_ORDER, items keep hyprctl order.
function groupBinds(binds, query) {
  var q = String(query || "").trim().toLowerCase()
  var groups = ({})
  binds.forEach(function(b) {
    if (!b.description) return
    if (q) {
      var hay = (b.description + " " + comboLabel(b.modmask, b.key) + " " + b.combo + " " + actionLabel(b.action)).toLowerCase()
      var terms = q.split(/\s+/)
      for (var i = 0; i < terms.length; i++) if (hay.indexOf(terms[i]) === -1) return
    }
    var c = category(b, b.action)
    if (!groups[c]) groups[c] = []
    groups[c].push(b)
  })
  return GROUP_ORDER.filter(function(t) { return groups[t] }).map(function(t) { return { title: t, items: groups[t] } })
}

function findConflicts(binds, modmask, key, ignoreIds) {
  var id = comboId(modmask, key)
  return binds.filter(function(b) {
    return b.id === id && !b.submap && (!ignoreIds || ignoreIds.indexOf(b.id) === -1)
  })
}

// ---- Lua strings ----------------------------------------------------------
function luaString(s) {
  return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
}

var LUA_STR = "\"(?:[^\"\\\\]|\\\\.)*\""

function unLua(lit) {
  return lit.slice(1, -1).replace(/\\(.)/g, function(_, c) { return c === "n" ? "\n" : c === "t" ? "\t" : c })
}

// ---- managed block --------------------------------------------------------
// Entries:
//   { kind: "disable", keys, was }                     hl.unbind
//   { kind: "bind", keys, description, action: "app"|"command", value,
//     replaces: bool, was }                            [hl.unbind +] o.bind
function renderEntries(entries) {
  var lines = []
  entries.forEach(function(e) {
    if (e.kind === "disable") {
      lines.push("-- Disabled: " + oneLine(e.was || e.keys))
      lines.push("hl.unbind(" + luaString(e.keys) + ")")
    } else if (e.kind === "bind") {
      if (e.replaces) {
        lines.push("-- Replaces: " + oneLine(e.was || "existing binding"))
        lines.push("hl.unbind(" + luaString(e.keys) + ")")
      }
      var target = e.action === "app"
        ? "{ launch = " + luaString(e.value) + " }"
        : luaString(e.value)
      lines.push("o.bind(" + luaString(e.keys) + ", " + luaString(e.description || "") + ", " + target + ")")
    }
  })
  return lines.join("\n")
}

function oneLine(s) {
  return String(s).replace(/\s+/g, " ").trim()
}

function parseEntries(body) {
  var entries = []
  var comment = null
  var pendingUnbind = null
  var reUnbind = new RegExp("^hl\\.unbind\\((" + LUA_STR + ")\\)\\s*$")
  var reBind = new RegExp("^o\\.bind\\((" + LUA_STR + "),\\s*(" + LUA_STR + "|nil),\\s*(?:\\{\\s*launch\\s*=\\s*(" + LUA_STR + ")\\s*\\}|(" + LUA_STR + "))\\s*\\)\\s*$")

  function flush() {
    if (pendingUnbind) entries.push(pendingUnbind)
    pendingUnbind = null
  }

  String(body || "").split("\n").forEach(function(raw) {
    var line = raw.trim()
    if (!line) return
    var c = /^--\s*(Disabled|Replaces):\s*(.*)$/.exec(line)
    if (c) { flush(); comment = { type: c[1], text: c[2] }; return }
    if (/^--/.test(line)) return
    var m = reUnbind.exec(line)
    if (m) {
      flush()
      pendingUnbind = { kind: "disable", keys: unLua(m[1]), was: comment ? comment.text : "" }
      comment = null
      return
    }
    m = reBind.exec(line)
    if (m) {
      var keys = unLua(m[1])
      var e = {
        kind: "bind", keys: keys,
        description: m[2] === "nil" ? "" : unLua(m[2]),
        action: m[3] ? "app" : "command",
        value: unLua(m[3] || m[4]),
        replaces: false, was: ""
      }
      if (pendingUnbind && comboIdFromString(pendingUnbind.keys) === comboIdFromString(keys)) {
        e.replaces = true
        e.was = pendingUnbind.was
        pendingUnbind = null
      }
      flush()
      entries.push(e)
      comment = null
      return
    }
    // Unknown line inside our block: ignore (it gets dropped on next write).
  })
  flush()
  return entries
}

// Combos bound/unbound in the user's own lines (outside our block).
function parseUserCombos(text) {
  var ids = ({})
  var re = new RegExp("^\\s*(?:o\\.bind|hl\\.bind|o\\.bind_toggle)\\(\\s*(" + LUA_STR + ")", "")
  String(text || "").split("\n").forEach(function(line) {
    if (/^\s*--/.test(line)) return
    var m = re.exec(line)
    if (m) ids[comboIdFromString(unLua(m[1]))] = true
  })
  return ids
}

// ---- key capture (Qt -> Hyprland) ----------------------------------------
var QT = {
  Shift: 0x01000020, Control: 0x01000021, Meta: 0x01000022, Alt: 0x01000023,
  CapsLock: 0x01000024, NumLock: 0x01000025, ScrollLock: 0x01000026,
  Super_L: 0x01000053, Super_R: 0x01000054, Hyper_L: 0x01000056, Hyper_R: 0x01000057,
  AltGr: 0x01001103, Escape: 0x01000000
}

var QT_NAMED = {}
QT_NAMED[0x01000001] = "TAB"
QT_NAMED[0x01000002] = "TAB"          // Backtab (Shift+Tab)
QT_NAMED[0x01000003] = "BACKSPACE"
QT_NAMED[0x01000004] = "RETURN"
QT_NAMED[0x01000005] = "RETURN"       // keypad Enter
QT_NAMED[0x01000006] = "INSERT"
QT_NAMED[0x01000007] = "DELETE"
QT_NAMED[0x01000008] = "PAUSE"
QT_NAMED[0x01000009] = "PRINT"
QT_NAMED[0x01000010] = "HOME"
QT_NAMED[0x01000011] = "END"
QT_NAMED[0x01000012] = "LEFT"
QT_NAMED[0x01000013] = "UP"
QT_NAMED[0x01000014] = "RIGHT"
QT_NAMED[0x01000015] = "DOWN"
QT_NAMED[0x01000016] = "PRIOR"
QT_NAMED[0x01000017] = "NEXT"
QT_NAMED[0x01000055] = "MENU"
QT_NAMED[0x20] = "SPACE"
QT_NAMED[0x01000000] = "ESCAPE"
QT_NAMED[0x01000070] = "XF86AudioLowerVolume"
QT_NAMED[0x01000071] = "XF86AudioMute"
QT_NAMED[0x01000072] = "XF86AudioRaiseVolume"
QT_NAMED[0x01000080] = "XF86AudioPlay"
QT_NAMED[0x01000081] = "XF86AudioStop"
QT_NAMED[0x01000082] = "XF86AudioPrev"
QT_NAMED[0x01000083] = "XF86AudioNext"
QT_NAMED[0x01000085] = "XF86AudioPause"
QT_NAMED[0x01000086] = "XF86AudioPlay"   // MediaTogglePlayPause
QT_NAMED[0x010000b2] = "XF86MonBrightnessUp"
QT_NAMED[0x010000b3] = "XF86MonBrightnessDown"
QT_NAMED[0x010000b4] = "XF86KbdLightOnOff"
QT_NAMED[0x010000b5] = "XF86KbdBrightnessUp"
QT_NAMED[0x010000b6] = "XF86KbdBrightnessDown"
QT_NAMED[0x010000cb] = "XF86Calculator"
QT_NAMED[0x01100008] = "XF86AudioMicMute"  // Qt::Key_MicMute
QT_NAMED[0x01000061] = "XF86Search"

// Fallback names when no scancode is available (US positions).
var QT_PUNCT = { 0x2c: "COMMA", 0x2e: "PERIOD", 0x2d: "MINUS", 0x3d: "EQUAL", 0x2f: "SLASH",
                 0x5c: "BACKSLASH", 0x3b: "SEMICOLON", 0x27: "APOSTROPHE", 0x60: "GRAVE",
                 0x5b: "BRACKETLEFT", 0x5d: "BRACKETRIGHT" }

function isModifierKey(qtKey) {
  return [QT.Shift, QT.Control, QT.Meta, QT.Alt, QT.CapsLock, QT.NumLock, QT.ScrollLock,
          QT.Super_L, QT.Super_R, QT.Hyper_L, QT.Hyper_R, QT.AltGr].indexOf(qtKey) !== -1
}

// Qt.KeyboardModifiers -> ["SUPER","CTRL","ALT","SHIFT"]
function qtModsToNames(mods) {
  var out = []
  if (mods & 0x10000000) out.push("SUPER")  // MetaModifier = Super on Wayland
  if (mods & 0x04000000) out.push("CTRL")
  if (mods & 0x08000000) out.push("ALT")
  if (mods & 0x02000000) out.push("SHIFT")
  return out
}

// Hyprland key name for a Qt key event, or "" for modifier-only presses.
// Letters/F-keys/named keys use keysym names; the digit row and punctuation
// use `code:N` (xkb keycode = Qt nativeScanCode on Wayland) like Omarchy's
// own workspace binds, so they keep working across layouts and with Shift.
function qtKeyToHypr(qtKey, nativeScanCode, text) {
  if (isModifierKey(qtKey)) return ""
  if (qtKey >= 0x41 && qtKey <= 0x5a) return String.fromCharCode(qtKey)
  if (qtKey >= 0x01000030 && qtKey <= 0x01000052) return "F" + (qtKey - 0x01000030 + 1)
  if (QT_NAMED[qtKey]) return QT_NAMED[qtKey]
  if (nativeScanCode > 8) return "code:" + nativeScanCode
  if (qtKey >= 0x30 && qtKey <= 0x39) return "code:" + (qtKey === 0x30 ? 19 : qtKey - 0x31 + 10)
  if (QT_PUNCT[qtKey]) return QT_PUNCT[qtKey]
  var t = String(text || "").trim()
  if (t.length === 1 && /[a-z]/i.test(t)) return t.toUpperCase()
  return ""
}

// Shortcut combos must have a modifier unless the key is a function/media key.
function needsModifier(key) {
  return !/^(F\d+|XF86\w+|PRINT|PAUSE|MENU)$/i.test(key)
}

// ---- desktop entries ------------------------------------------------------
// Lines "path<TAB>Name<TAB>NoDisplay" -> [{ value: "id.desktop", label, description }]
function parseDesktopEntries(text) {
  var seen = ({})
  var out = []
  String(text || "").split("\n").forEach(function(line) {
    var p = line.split("\t")
    if (p.length < 2) return
    var id = p[0].replace(/^.*\/applications\//, "").replace(/\//g, "-")
    // First directory wins (user entries override system ones, also to hide).
    if (seen[id]) return
    seen[id] = true
    if (!p[1] || p[2] === "true") return
    out.push({ value: id, label: p[1], description: id })
  })
  out.sort(function(a, b) { return a.label.localeCompare(b.label) })
  return out
}
