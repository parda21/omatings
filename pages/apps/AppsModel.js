.pragma library

// Pure helpers for the Default Apps page. No Qt, no I/O.

// Candidates mirror the `setup.default.*` entries of
// $OMARCHY_PATH/default/omarchy/omarchy-menu.jsonc: `value` is what
// `omarchy default <kind>` takes and prints, `command` is the menu's
// `when: omarchy-cmd-present <command>` check.
var BROWSERS = [
  { value: "chromium", label: "Chromium", command: "chromium" },
  { value: "chrome", label: "Chrome", command: "google-chrome-stable" },
  { value: "brave", label: "Brave", command: "brave" },
  { value: "brave-origin", label: "Brave Origin", command: "brave-origin" },
  { value: "edge", label: "Edge", command: "microsoft-edge-stable" },
  { value: "firefox", label: "Firefox", command: "firefox" },
  { value: "zen", label: "Zen", command: "zen-browser" }
]

// omarchy-default-editor stores "zeditor" for Zed (and accepts it back).
var EDITORS = [
  { value: "nvim", label: "Neovim", command: "nvim" },
  { value: "code", label: "VSCode", command: "code" },
  { value: "cursor", label: "Cursor", command: "cursor" },
  { value: "zeditor", label: "Zed", command: "zeditor" },
  { value: "sublime_text", label: "Sublime Text", command: "sublime_text" },
  { value: "helix", label: "Helix", command: "helix" },
  { value: "vim", label: "Vim", command: "vim" },
  { value: "emacs", label: "Emacs", command: "emacs" }
]

var TERMINALS = [
  { value: "alacritty", label: "Alacritty", command: "alacritty" },
  { value: "foot", label: "Foot", command: "foot" },
  { value: "ghostty", label: "Ghostty", command: "ghostty" },
  { value: "kitty", label: "Kitty", command: "kitty" }
]

// `package` is the mise tool omarchy-default-agent installs it as;
// `installer` agents (Hermes, OpenClaw) are not mise tools.
var AGENTS = [
  { value: "claude", label: "Claude Code", package: "claude" },
  { value: "codex", label: "Codex", package: "codex" },
  { value: "copilot", label: "GitHub Copilot", package: "copilot" },
  { value: "crush", label: "Crush", package: "crush" },
  { value: "cursor-agent", label: "Cursor CLI", package: "cursor-agent" },
  { value: "gemini", label: "Gemini", package: "gemini" },
  { value: "grok", label: "Grok", package: "npm:@xai-official/grok" },
  { value: "hermes", label: "Hermes", installer: true },
  { value: "muse", label: "Muse Code", package: "http:muse" },
  { value: "omp", label: "Oh My Pi", package: "github:can1357/oh-my-pi" },
  { value: "openclaw", label: "OpenClaw", installer: true },
  { value: "opencode", label: "OpenCode", package: "opencode" },
  { value: "pi", label: "Pi", package: "pi" }
]

// MIME groups for the "Files" section. The first type is the one whose
// current handler is shown and whose registered apps are the candidates;
// choosing an app sets every type of the group that app declares.
var MIME_GROUPS = [
  { id: "files", label: "File manager", description: "Opens folders.",
    types: ["inode/directory"] },
  { id: "images", label: "Image viewer", description: "PNG, JPEG, GIF, WebP and more.",
    types: ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/tiff", "image/avif", "image/heic"] },
  { id: "videos", label: "Video player", description: "MP4, MKV, WebM and more.",
    types: ["video/mp4", "video/x-matroska", "video/webm", "video/quicktime", "video/x-msvideo", "video/mpeg", "video/ogg"] },
  { id: "audio", label: "Music player", description: "MP3, FLAC, Ogg and more.",
    types: ["audio/mpeg", "audio/flac", "audio/ogg", "audio/x-wav", "audio/mp4", "audio/aac", "audio/opus"] },
  { id: "pdf", label: "PDF viewer", description: "Opens PDF documents.",
    types: ["application/pdf"] }
]

function labelFor(list, value) {
  for (var i = 0; i < list.length; i++) if (list[i].value === value) return list[i].label
  return value
}

// Dropdown options: installed candidates, plus the current value when it is
// something else (so the dropdown never lies about what is configured).
function options(list, installed, current) {
  var out = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    if (installed[list[i].value]) {
      out.push({ value: list[i].value, label: list[i].label })
      seen[list[i].value] = true
    }
  }
  if (current && !seen[current]) out.push({ value: current, label: labelFor(list, current) + " (not installed)" })
  return out
}

// ---- mimeapps.list -------------------------------------------------------

// Set `mime=desktopId` for each entry of `assignments` inside the
// [Default Applications] section of a mimeapps.list text, keeping every other
// line (and its order) as is. Missing section is appended.
function setDefaults(text, assignments) {
  var lines = String(text || "").split("\n")
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  var pending = {}
  var count = 0
  for (var k in assignments) { pending[k] = assignments[k]; count++ }
  if (count === 0) return lines.join("\n") + (lines.length ? "\n" : "")

  var start = -1
  var end = lines.length
  for (var i = 0; i < lines.length; i++) {
    var t = lines[i].trim()
    if (start < 0 && t === "[Default Applications]") { start = i; continue }
    if (start >= 0 && /^\[.*\]$/.test(t)) { end = i; break }
  }

  if (start < 0) {
    var tail = []
    if (lines.length && lines[lines.length - 1].trim() !== "") tail.push("")
    tail.push("[Default Applications]")
    for (var m in pending) tail.push(m + "=" + pending[m])
    return lines.concat(tail).join("\n") + "\n"
  }

  for (var j = start + 1; j < end; j++) {
    var eq = lines[j].indexOf("=")
    if (eq <= 0 || lines[j].trim().charAt(0) === "#") continue
    var key = lines[j].substring(0, eq).trim()
    if (pending.hasOwnProperty(key)) {
      lines[j] = key + "=" + pending[key]
      delete pending[key]
    }
  }

  // New keys go after the last non-blank line of the section.
  var insertAt = end
  while (insertAt - 1 > start && lines[insertAt - 1].trim() === "") insertAt--
  var added = []
  for (var n in pending) added.push(n + "=" + pending[n])
  Array.prototype.splice.apply(lines, [insertAt, 0].concat(added))
  return lines.join("\n") + "\n"
}

// Output of the page's mime scan script:
//   default<TAB>mime<TAB>desktop-id
//   app<TAB>mime<TAB>desktop-id<TAB>Name<TAB>NoDisplay<TAB>MimeType
// -> { defaults: {mime: id}, apps: {mime: [{id, name, hidden, mimeTypes}]} }
function parseMimeScan(raw) {
  var res = { defaults: {}, apps: {} }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var p = lines[i].split("\t")
    if (p[0] === "default" && p.length >= 3) {
      res.defaults[p[1]] = p[2]
    } else if (p[0] === "app" && p.length >= 6) {
      if (!res.apps[p[1]]) res.apps[p[1]] = []
      res.apps[p[1]].push({
        id: p[2],
        name: p[3] || p[2].replace(/\.desktop$/, ""),
        hidden: p[4] === "true",
        mimeTypes: p[5].split(";").filter(function(x) { return x !== "" })
      })
    }
  }
  return res
}

// Dropdown options for one group: visible registered apps (plus the current
// one even if hidden). Duplicate names get their desktop id appended.
function mimeOptions(apps, current) {
  var list = (apps || []).filter(function(a) { return !a.hidden || a.id === current })
  var counts = {}
  for (var i = 0; i < list.length; i++) counts[list[i].name] = (counts[list[i].name] || 0) + 1
  var out = list.map(function(a) {
    var label = counts[a.name] > 1 ? a.name + " (" + a.id.replace(/\.desktop$/, "") + ")" : a.name
    return { value: a.id, label: label }
  })
  if (current && !list.some(function(a) { return a.id === current }))
    out.push({ value: current, label: current.replace(/\.desktop$/, "") })
  return out
}

// Which of the group's types to assign to `app` (the ones it declares; the
// primary type always, since the app was offered for it).
function typesFor(group, app) {
  var declared = app && app.mimeTypes ? app.mimeTypes : []
  var out = []
  for (var i = 0; i < group.types.length; i++) {
    var t = group.types[i]
    if (i === 0 || declared.indexOf(t) !== -1) out.push(t)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    BROWSERS: BROWSERS, EDITORS: EDITORS, TERMINALS: TERMINALS, AGENTS: AGENTS, MIME_GROUPS: MIME_GROUPS,
    labelFor: labelFor, options: options, setDefaults: setDefaults,
    parseMimeScan: parseMimeScan, mimeOptions: mimeOptions, typesFor: typesFor
  }
}
