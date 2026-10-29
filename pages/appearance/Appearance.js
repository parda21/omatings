.pragma library
.import "../../Core/ManagedBlock.js" as MB

// Pure helpers for the Appearance page: shell scripts that list themes and
// backgrounds (read-only), their parsers, and the Lua generation for the
// "looknfeel" managed block in ~/.config/hypr/looknfeel.lua.

// ---- window look (Hyprland) ----------------------------------------------

var BLOCK = "looknfeel"
var COMMENT = "--"

// Every option the page controls. `path` is the hl.config() table path,
// `hypr` the `hyprctl getoption` name. `fallback` mirrors Omarchy's
// default/hypr/looknfeel.lua (or Hyprland's own default when Omarchy does
// not set it) and is only used when hyprctl is unavailable.
var OPTIONS = [
  { key: "gaps_in",      path: ["general", "gaps_in"],               hypr: "general:gaps_in",          type: "int",   min: 0, max: 30, fallback: 5,     label: "Inner gaps" },
  { key: "gaps_out",     path: ["general", "gaps_out"],              hypr: "general:gaps_out",         type: "int",   min: 0, max: 60, fallback: 10,    label: "Outer gaps" },
  { key: "border_size",  path: ["general", "border_size"],           hypr: "general:border_size",      type: "int",   min: 0, max: 10, fallback: 2,     label: "Border size" },
  { key: "rounding",     path: ["decoration", "rounding"],           hypr: "decoration:rounding",      type: "int",   min: 0, max: 30, fallback: 0,     label: "Rounding" },
  { key: "blur",         path: ["decoration", "blur", "enabled"],    hypr: "decoration:blur:enabled",  type: "bool",                    fallback: false, label: "Blur" },
  { key: "shadow",       path: ["decoration", "shadow", "enabled"],  hypr: "decoration:shadow:enabled",type: "bool",                    fallback: false, label: "Shadows" },
  { key: "dim_inactive", path: ["decoration", "dim_inactive"],       hypr: "decoration:dim_inactive",  type: "bool",                    fallback: false, label: "Dim inactive" },
  { key: "dim_strength", path: ["decoration", "dim_strength"],       hypr: "decoration:dim_strength",  type: "float", min: 0, max: 1,  fallback: 0.5,   label: "Dim strength" },
  { key: "animations",   path: ["animations", "enabled"],            hypr: "animations:enabled",       type: "bool",                    fallback: true,  label: "Animations" }
]

function option(key) {
  for (var i = 0; i < OPTIONS.length; i++) if (OPTIONS[i].key === key) return OPTIONS[i]
  return null
}

function defaults() {
  var out = {}
  for (var i = 0; i < OPTIONS.length; i++) out[OPTIONS[i].key] = OPTIONS[i].fallback
  return out
}

// Clamp/round a value to what the option accepts.
function normalize(key, v) {
  var o = option(key)
  if (!o) return v
  if (o.type === "bool") return v === true || v === "true" || v === 1
  var n = Number(v)
  if (!isFinite(n)) n = o.fallback
  n = Math.max(o.min, Math.min(o.max, n))
  return o.type === "int" ? Math.round(n) : Math.round(n * 100) / 100
}

// Parse `hyprctl getoption <name> -j` output (object or JSON text).
// Returns null when it cannot be read.
function parseGetOption(key, data) {
  var o = option(key)
  if (!o) return null
  var j = data
  if (typeof j === "string") {
    try { j = JSON.parse(j) } catch (e) { return null }
  }
  if (!j || typeof j !== "object") return null
  if (o.type === "bool") {
    if ("bool" in j) return j.bool === true
    if ("int" in j) return Number(j.int) !== 0
    return null
  }
  var n = NaN
  if ("int" in j) n = Number(j.int)
  else if ("float" in j) n = Number(j.float)
  else if ("css" in j) {
    // gaps are "top right bottom left"; the page edits them uniformly
    var m = String(j.css).match(/-?\d+(?:\.\d+)?/)
    if (m) n = Number(m[0])
  }
  return isFinite(n) ? normalize(key, n) : null
}

function _nest(path, value) {
  var obj = value
  for (var i = path.length - 1; i >= 0; i--) {
    var wrap = {}
    wrap[path[i]] = obj
    obj = wrap
  }
  return obj
}

function _merge(into, obj) {
  for (var k in obj) {
    if (obj[k] && typeof obj[k] === "object" && !Array.isArray(obj[k])) {
      if (!into[k] || typeof into[k] !== "object") into[k] = {}
      _merge(into[k], obj[k])
    } else {
      into[k] = obj[k]
    }
  }
  return into
}

// One hl.config() line for one option, e.g.
//   hl.config({ decoration = { blur = { enabled = true } } })
function optionLine(key, value) {
  var o = option(key)
  return "hl.config(" + MB.luaValue(_nest(o.path, value)) + ")"
}

// Lua for a live preview of several options at once (hyprctl eval).
function evalLua(values) {
  var merged = {}
  for (var i = 0; i < OPTIONS.length; i++) {
    var k = OPTIONS[i].key
    if (values && k in values) _merge(merged, _nest(OPTIONS[i].path, normalize(k, values[k])))
  }
  return "hl.config(" + MB.luaValue(merged) + ")"
}

// Block body for the given overrides (only keys present are written), in a
// stable order, one option per line so the block stays diff-friendly and
// can be parsed back.
function renderBody(overrides) {
  var lines = []
  for (var i = 0; i < OPTIONS.length; i++) {
    var k = OPTIONS[i].key
    if (overrides && k in overrides) lines.push(optionLine(k, normalize(k, overrides[k])))
  }
  return lines.join("\n")
}

function _escape(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// Parse a block body written by renderBody() back into { key: value }.
// Lines that are not ours are ignored.
function parseBody(body) {
  var out = {}
  var lines = String(body || "").split("\n")
  var marker = "\"@@VALUE@@\""
  for (var i = 0; i < OPTIONS.length; i++) {
    var o = OPTIONS[i]
    var tpl = optionLine(o.key, "@@VALUE@@").split(marker)
    var re = new RegExp("^\\s*" + _escape(tpl[0]) + "\\s*(true|false|-?\\d+(?:\\.\\d+)?)\\s*" + _escape(tpl[1]) + "\\s*$")
    for (var j = 0; j < lines.length; j++) {
      var m = lines[j].match(re)
      if (m) {
        var raw = m[1]
        out[o.key] = normalize(o.key, raw === "true" ? true : raw === "false" ? false : Number(raw))
      }
    }
  }
  return out
}

// { key: value } saved in the managed block of `fileText` ({} if none).
function readOverrides(fileText) {
  var body = MB.read(fileText, BLOCK, COMMENT)
  return body === null ? {} : parseBody(body)
}

function hasBlock(fileText) {
  return MB.read(fileText, BLOCK, COMMENT) !== null
}

// New file text with the block set to `overrides` (removed when empty).
function applyOverrides(fileText, overrides) {
  var body = renderBody(overrides)
  if (!body) return MB.remove(fileText, BLOCK, COMMENT)
  return MB.replace(fileText, BLOCK, body, COMMENT)
}

function removeBlock(fileText) {
  return MB.remove(fileText, BLOCK, COMMENT)
}

function overrideLabels(overrides) {
  var out = []
  for (var i = 0; i < OPTIONS.length; i++) if (overrides && OPTIONS[i].key in overrides) out.push(OPTIONS[i].label.toLowerCase())
  return out
}

// ---- themes ----------------------------------------------------------------

// bash script, $1 = OMARCHY_PATH. Prints
//   C<TAB>current-slug
//   T<TAB>slug<TAB>Display Name<TAB>source(stock|user|git)<TAB>preview-path
// Preview lookup mirrors omarchy-theme-switcher's find_preview.
var THEMES_SCRIPT = [
  'user="$HOME/.config/omarchy/themes"',
  'stock="${1:-/usr/share/omarchy}/themes"',
  'find_preview() {',
  '  local p n',
  '  for n in preview.png preview.jpg preview.jpeg preview.webp preview.gif preview.bmp; do',
  '    p=$(find -L "$1" -maxdepth 1 -type f -iname "$n" -print -quit 2>/dev/null)',
  '    [[ -n $p ]] && { printf "%s" "$p"; return; }',
  '  done',
  '  if [[ -d $1/backgrounds ]]; then',
  '    find -L "$1/backgrounds" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.webp" \\) -print 2>/dev/null | sort | head -n 1 | tr -d "\\n"',
  '  fi',
  '}',
  'printf "C\\t%s\\n" "$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)"',
  '{',
  '  find "$user/" -mindepth 1 -maxdepth 1 \\( -type d -o -type l \\) -printf "%f\\n" 2>/dev/null',
  '  find "$stock/" -mindepth 1 -maxdepth 1 -type d -printf "%f\\n" 2>/dev/null',
  '} | sort -u | while IFS= read -r slug; do',
  '  dir="$stock/$slug"; src=stock',
  '  if [[ -d $user/$slug ]]; then',
  '    dir="$user/$slug"; src=user',
  '    [[ ! -L $user/$slug && -d $user/$slug/.git ]] && src=git',
  '  fi',
  '  p=$(find_preview "$dir")',
  '  [[ -z $p && $src != stock ]] && p=$(find_preview "$stock/$slug")',
  '  name=$(printf "%s" "$slug" | sed -E "s/(^|-)([a-z])/\\1\\u\\2/g; s/-/ /g")',
  '  printf "T\\t%s\\t%s\\t%s\\t%s\\n" "$slug" "$name" "$src" "$p"',
  'done'
].join("\n")

// -> { current: slug, themes: [{ slug, name, source, preview }] }
function parseThemes(text) {
  var out = { current: "", themes: [] }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t")
    if (f[0] === "C") out.current = String(f[1] || "").trim()
    else if (f[0] === "T" && f[1]) out.themes.push({ slug: f[1], name: f[2] || f[1], source: f[3] || "stock", preview: f[4] || "" })
  }
  return out
}

// ---- backgrounds -----------------------------------------------------------

// bash script, no args. Prints
//   C<TAB>link-target<TAB>resolved-path
//   B<TAB>path<TAB>cached-thumbnail-or-empty<TAB>isUser(0|1)
// The file list and order mirror omarchy-theme-bg-next; thumbnails come
// from omarchy-menu-images' cache when it already has them.
var BACKGROUNDS_SCRIPT = [
  'theme=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)',
  'link="$HOME/.local/state/omarchy/current/background"',
  'userdir="$HOME/.config/omarchy/backgrounds/$theme/"',
  'cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/image-selector"',
  'printf "C\\t%s\\t%s\\n" "$(readlink "$link" 2>/dev/null)" "$(readlink -f "$link" 2>/dev/null)"',
  'find -L "$userdir" "$HOME/.local/state/omarchy/current/theme/backgrounds/" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.webp" \\) -print0 2>/dev/null | sort -z |',
  'while IFS= read -r -d "" f; do',
  '  sig=$(stat -Lc "%s:%Y" "$f" 2>/dev/null)',
  '  hash=$(awk -F "\\t" -v p="$f" -v s="$sig" \'$1 == p && $2 == s { print $3; exit }\' "$cache/index.tsv" 2>/dev/null)',
  '  [[ -z $hash ]] && hash=$(printf "%s\\t%s" "$f" "$sig" | md5sum | cut -d " " -f 1)',
  '  thumb=""; [[ -f $cache/$hash.jpg ]] && thumb="$cache/$hash.jpg"',
  '  u=0; [[ $f == "$userdir"* ]] && u=1',
  '  printf "B\\t%s\\t%s\\t%s\\n" "$f" "$thumb" "$u"',
  'done'
].join("\n")

// "3-sunset-lake.png" -> "Sunset Lake" (same as omarchy-theme-bg-current)
function backgroundName(path) {
  var base = String(path || "").split("/").pop().replace(/\.[^.]+$/, "").replace(/^\d+-/, "").replace(/-/g, " ")
  return base.replace(/\b(\w)/g, function(m) { return m.toUpperCase() })
}

// -> { current, currentResolved, items: [{ path, thumb, user, name }] }
function parseBackgrounds(text) {
  var out = { current: "", currentResolved: "", items: [] }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t")
    if (f[0] === "C") { out.current = f[1] || ""; out.currentResolved = f[2] || "" }
    else if (f[0] === "B" && f[1]) out.items.push({ path: f[1], thumb: f[2] || "", user: f[3] === "1", name: backgroundName(f[1]) })
  }
  return out
}

function isCurrentBackground(bg, item) {
  if (!bg || !item) return false
  return item.path === bg.current || item.path === bg.currentResolved
}

// ---- text size -------------------------------------------------------------

var TEXT_MIN = 9
var TEXT_MAX = 20
var TEXT_DEFAULT = 12

// Parse `omarchy display text size` output:
//   text size: 12 (default) px
// -> { size, isDefault } or null
function parseTextSize(text) {
  var m = String(text || "").match(/text size:\s*(\d+)\s*(\(default\))?/)
  if (!m) return null
  return { size: Number(m[1]), isDefault: !!m[2] }
}

// ---- misc ------------------------------------------------------------------

// Local path -> file:// URL (escapes #, ?, spaces, ...).
function fileUrl(path) {
  if (!path) return ""
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}
