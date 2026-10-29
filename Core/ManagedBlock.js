.pragma library

// Managed blocks let the settings app own a clearly marked region inside a
// user config file while leaving everything else (hand-written lines,
// comments) untouched:
//
//   -- >>> omatings:monitors
//   -- Managed by Omarchy Settings. Edits inside this block are overwritten.
//   hl.monitor({ ... })
//   -- <<< omatings:monitors
//
// The block is appended at the end of the file the first time, so for
// "last call wins" configs (Hyprland Lua) it overrides earlier lines.
//
// `comment` is the line-comment prefix of the file format: "--" for Lua,
// "#" for conf/ini/toml.

var NOTICE = "Managed by Omarchy Settings. Edits inside this block are overwritten."

function _escape(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function _pattern(name, comment) {
  var c = _escape(comment || "--")
  var n = _escape(name)
  return new RegExp("(^|\\n)[ \\t]*" + c + " >>> omatings:" + n + "[^\\n]*\\n[\\s\\S]*?[ \\t]*" + c + " <<< omatings:" + n + "[^\\n]*(\\n|$)")
}

// Body lines inside the block (without markers/notice), or null if absent.
function read(text, name, comment) {
  var m = String(text || "").match(_pattern(name, comment))
  if (!m) return null
  var lines = m[0].replace(/^\n/, "").split("\n")
  // drop start marker, notice line, end marker
  var body = lines.slice(1, lines.length - 1)
  if (body.length && body[0].indexOf(NOTICE) !== -1) body = body.slice(1)
  if (body.length && body[body.length - 1].indexOf("<<< omatings:") !== -1) body = body.slice(0, -1)
  return body.join("\n").replace(/\n+$/, "")
}

function render(name, body, comment) {
  var c = comment || "--"
  var inner = String(body || "").replace(/\n+$/, "")
  return c + " >>> omatings:" + name + "\n"
    + c + " " + NOTICE + "\n"
    + (inner ? inner + "\n" : "")
    + c + " <<< omatings:" + name + "\n"
}

// Return `text` with block `name` replaced by `body` (or appended).
function replace(text, name, body, comment) {
  var src = String(text || "")
  var block = render(name, body, comment)
  var re = _pattern(name, comment)
  var m = src.match(re)
  if (m) {
    var lead = m[1] || ""
    return src.replace(re, lead + block)
  }
  if (src.length && !/\n$/.test(src)) src += "\n"
  if (src.length) src += "\n"
  return src + block
}

// Return `text` with block `name` removed entirely.
function remove(text, name, comment) {
  return String(text || "").replace(_pattern(name, comment), "$1").replace(/\n{2,}$/, "\n")
}

// Lua literal helpers for writing hl.* calls.
function luaString(s) {
  return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
}

function luaValue(v) {
  if (v === null || v === undefined) return "nil"
  if (typeof v === "boolean") return v ? "true" : "false"
  if (typeof v === "number") return String(v)
  if (Array.isArray(v)) return "{ " + v.map(luaValue).join(", ") + " }"
  if (typeof v === "object") {
    var parts = []
    for (var k in v) {
      if (v[k] === undefined) continue
      var key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "[" + luaString(k) + "]"
      parts.push(key + " = " + luaValue(v[k]))
    }
    return "{ " + parts.join(", ") + " }"
  }
  return luaString(v)
}
