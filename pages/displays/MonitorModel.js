.pragma library
.import "../../Core/ManagedBlock.js" as MB

// Pure helpers for the Displays page: hyprctl JSON -> monitor state,
// arrangement math (logical sizes, snapping, overlap resolution) and
// monitor state -> Hyprland Lua. No QML, no I/O, so tools/tests can
// exercise everything here headlessly.
//
// A monitor state object (what the page edits) looks like:
//   { name: "DP-1", description, make, model, serial, internal,
//     enabled, width, height, refresh,          // pixel mode
//     scale: 1.5 | "auto", transform: 0..7,
//     x, y,                                      // logical position
//     vrr: -1 (follow global) | 0 off | 1 on | 2 fullscreen | 3 fullscreen games/video,
//     mirror: "" | "<port name of the mirrored monitor>",
//     modes: [{ width, height, refresh }], physicalWidth, physicalHeight }
//
// Hyprland facts this relies on (verified against v0.56.2 source):
// - hl.monitor() with an output string that already has a rule starts from
//   that rule and overwrites only the given fields; the older rule is
//   dropped (MonitorRuleManager::add erases same-name rules).
// - Lookup walks rules newest-first and takes the first one whose selector
//   matches (`desc:` = description prefix, else exact port name). So a rule
//   added later always wins, even if it uses a different selector.
// - A scale is valid when width and height divide into whole logical
//   pixels in 1/120 steps (wl fractional-scale); Hyprland otherwise picks a
//   nearby value and shows a red notification.

var BLOCK = "monitors"
var COMMENT = "--"
var DISABLED_PREFIX = "-- [omatings] "
var COMMON_SCALES = [1, 1.25, 4 / 3, 1.5, 1.6, 5 / 3, 2, 2.5, 3]
var INTERNAL_RE = /^(eDP|LVDS|DSI)-/

// ---- small utils -----------------------------------------------------------

function clone(v) {
  return JSON.parse(JSON.stringify(v))
}

function isInternal(name) {
  return INTERNAL_RE.test(String(name || ""))
}

// Fixed decimals with trailing zeros removed: 120.00 -> "120", 1.5 -> "1.5".
function formatNumber(n, digits) {
  var s = Number(n).toFixed(digits === undefined ? 2 : digits)
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "")
  return s
}

function round2(n) {
  return Math.round(Number(n) * 100) / 100
}

function gcd(a, b) {
  a = Math.abs(a); b = Math.abs(b)
  while (b) { var t = a % b; a = b; b = t }
  return a
}

// ---- modes -----------------------------------------------------------------

function parseMode(str) {
  var m = String(str || "").match(/^\s*(\d+)x(\d+)(?:@([\d.]+))?/)
  if (!m) return null
  return { width: Number(m[1]), height: Number(m[2]), refresh: m[3] ? round2(parseFloat(m[3])) : 60 }
}

// availableModes strings -> unique modes, biggest resolution first, then
// highest refresh rate first.
function parseModes(list) {
  var seen = {}
  var out = []
  for (var i = 0; i < (list || []).length; i++) {
    var m = parseMode(list[i])
    if (!m) continue
    var key = m.width + "x" + m.height + "@" + m.refresh
    if (seen[key]) continue
    seen[key] = true
    out.push(m)
  }
  out.sort(function(a, b) {
    if (a.width * a.height !== b.width * b.height) return b.width * b.height - a.width * a.height
    if (a.width !== b.width) return b.width - a.width
    return b.refresh - a.refresh
  })
  return out
}

var ASPECTS = [[16 / 9, "16:9"], [16 / 10, "16:10"], [4 / 3, "4:3"], [5 / 4, "5:4"], [3 / 2, "3:2"],
               [32 / 9, "32:9"], [64 / 27, "21:9"], [43 / 18, "21:9"], [12 / 5, "21:9"], [3 / 1, "3:1"]]

function aspectLabel(w, h) {
  if (!(w > 0 && h > 0)) return ""
  var r = w / h
  for (var i = 0; i < ASPECTS.length; i++) {
    if (Math.abs(r - ASPECTS[i][0]) < 0.02) return ASPECTS[i][1]
  }
  var g = gcd(w, h)
  return (w / g) + ":" + (h / g)
}

function resolutionKey(w, h) {
  return w + "x" + h
}

// Dropdown options for the resolution picker. The monitor's preferred
// (first listed by the kernel = first in availableModes) resolution is not
// knowable from hyprctl, so the biggest one is marked as the native size.
function resolutionOptions(modes, current) {
  var seen = {}
  var out = []
  for (var i = 0; i < (modes || []).length; i++) {
    var key = resolutionKey(modes[i].width, modes[i].height)
    if (seen[key]) continue
    seen[key] = true
    out.push({ value: key, label: modes[i].width + " × " + modes[i].height + "  (" + aspectLabel(modes[i].width, modes[i].height) + ")" })
  }
  if (current && current.width > 0 && !seen[resolutionKey(current.width, current.height)]) {
    out.unshift({ value: resolutionKey(current.width, current.height), label: current.width + " × " + current.height + "  (custom)" })
  }
  return out
}

function refreshValue(r) {
  return formatNumber(r, 2)
}

function refreshOptions(modes, w, h, currentRefresh) {
  var out = []
  var seen = {}
  for (var i = 0; i < (modes || []).length; i++) {
    var m = modes[i]
    if (m.width !== w || m.height !== h) continue
    var v = refreshValue(m.refresh)
    if (seen[v]) continue
    seen[v] = true
    out.push({ value: v, label: v + " Hz" })
  }
  if (currentRefresh > 0 && !seen[refreshValue(currentRefresh)]) {
    out.unshift({ value: refreshValue(currentRefresh), label: refreshValue(currentRefresh) + " Hz" })
  }
  return out
}

// Highest refresh rate available at w x h (0 when unknown).
function bestRefresh(modes, w, h) {
  var best = 0
  for (var i = 0; i < (modes || []).length; i++) {
    if (modes[i].width === w && modes[i].height === h) best = Math.max(best, modes[i].refresh)
  }
  return best
}

// Closest available refresh at w x h to `wanted`.
function closestRefresh(modes, w, h, wanted) {
  var best = 0
  var dist = Infinity
  for (var i = 0; i < (modes || []).length; i++) {
    var m = modes[i]
    if (m.width !== w || m.height !== h) continue
    var d = Math.abs(m.refresh - wanted)
    if (d < dist || (d === dist && m.refresh > best)) { dist = d; best = m.refresh }
  }
  return best
}

function modeString(mon) {
  return mon.width + "x" + mon.height + "@" + refreshValue(mon.refresh)
}

// ---- scale -----------------------------------------------------------------

function scaleUnits(scale) {
  return Math.round(Number(scale) * 120)
}

// Hyprland stores scale in 1/120 steps.
function cleanScale(scale) {
  return scaleUnits(scale) / 120
}

function isValidScale(scale, w, h) {
  var k = scaleUnits(scale)
  if (!(k > 0) || !(w > 0) || !(h > 0)) return false
  return (w * 120) % k === 0 && (h * 120) % k === 0
}

// Same search Hyprland does for an invalid scale (CMonitor::applyMonitorRule).
function nearestValidScale(scale, w, h) {
  var k = scaleUnits(scale)
  if (isValidScale(k / 120, w, h)) return k / 120
  for (var i = 1; i < 90; i++) {
    if (k + i > 0 && isValidScale((k + i) / 120, w, h)) return (k + i) / 120
    if (k - i > 0 && isValidScale((k - i) / 120, w, h)) return (k - i) / 120
  }
  return Math.max(1, Math.round(scale))
}

// Hyprland's "auto" scale (CMonitor::getDefaultScale): based on PPI.
function autoScale(mon) {
  var pw = Number(mon.physicalWidth) || 0
  var ph = Number(mon.physicalHeight) || 0
  var s = 1
  if (pw > 0 && ph > 0 && mon.width > 0 && mon.height > 0) {
    var diagPx = Math.sqrt(mon.width * mon.width + mon.height * mon.height)
    var diagIn = Math.sqrt(Math.pow(pw / 25.4, 2) + Math.pow(ph / 25.4, 2))
    var ppi = diagPx / diagIn
    s = ppi > 200 ? 2 : (ppi > 140 ? 1.5 : 1)
  }
  return isValidScale(s, mon.width, mon.height) ? s : Math.round(s)
}

function effectiveScale(mon) {
  if (mon.scale === "auto") return autoScale(mon)
  var s = Number(mon.scale)
  if (!(s > 0)) return 1
  return nearestValidScale(s, mon.width, mon.height)
}

// Dropdown value for a scale: "auto" or the clean number as a string.
function scaleValue(scale) {
  if (scale === "auto") return "auto"
  return formatNumber(cleanScale(scale), 6)
}

function scaleLabel(scale) {
  return Math.round(Number(scale) * 100) + "%"
}

// Common scales that are valid for w x h, plus "auto" and the current one.
function scaleOptions(mon) {
  var out = [{ value: "auto", label: "Auto (" + scaleLabel(autoScale(mon)) + ")" }]
  var seen = {}
  var values = []
  for (var i = 0; i < COMMON_SCALES.length; i++) {
    if (isValidScale(COMMON_SCALES[i], mon.width, mon.height)) values.push(cleanScale(COMMON_SCALES[i]))
  }
  if (mon.scale !== "auto" && Number(mon.scale) > 0) values.push(cleanScale(mon.scale))
  values.sort(function(a, b) { return a - b })
  for (var j = 0; j < values.length; j++) {
    var v = scaleValue(values[j])
    if (seen[v]) continue
    seen[v] = true
    out.push({ value: v, label: scaleLabel(values[j]) })
  }
  return out
}

function parseScaleValue(v) {
  if (v === "auto") return "auto"
  var n = Number(v)
  return n > 0 ? cleanScale(n) : 1
}

// ---- rotation --------------------------------------------------------------

// transform 0..3 = 0/90/180/270 degrees; 4..7 = the same, flipped.
function rotationOf(transform) {
  return (Number(transform) || 0) % 4
}

function withRotation(transform, rotation) {
  var flipped = (Number(transform) || 0) >= 4
  return (flipped ? 4 : 0) + (Number(rotation) % 4)
}

// ---- geometry --------------------------------------------------------------

function logicalSize(mon) {
  var s = effectiveScale(mon)
  var w = mon.width > 0 ? mon.width : 1920
  var h = mon.height > 0 ? mon.height : 1080
  if ((Number(mon.transform) || 0) % 2 === 1) { var t = w; w = h; h = t }
  return { width: Math.round(w / s), height: Math.round(h / s) }
}

function rectOf(mon) {
  var s = logicalSize(mon)
  return { name: mon.name, x: Math.round(mon.x), y: Math.round(mon.y), width: s.width, height: s.height }
}

// Monitors that take part in the arrangement (enabled, not mirroring).
function inLayout(mon) {
  return mon.enabled && !mon.mirror
}

function layoutRects(mons, exceptName) {
  var out = []
  for (var i = 0; i < mons.length; i++) {
    if (!inLayout(mons[i]) || mons[i].name === exceptName) continue
    out.push(rectOf(mons[i]))
  }
  return out
}

function overlaps(a, b) {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

function overlapsAny(r, others) {
  for (var i = 0; i < others.length; i++) if (overlaps(r, others[i])) return true
  return false
}

// Two rects share an edge segment of positive length.
function touches(a, b) {
  var vOverlap = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y)
  var hOverlap = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x)
  if ((a.x + a.width === b.x || b.x + b.width === a.x) && vOverlap > 0) return true
  if ((a.y + a.height === b.y || b.y + b.height === a.y) && hOverlap > 0) return true
  return false
}

function touchesAny(r, others) {
  for (var i = 0; i < others.length; i++) if (touches(r, others[i])) return true
  return false
}

function bounds(rects) {
  if (!rects.length) return { x: 0, y: 0, width: 0, height: 0 }
  var x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity
  for (var i = 0; i < rects.length; i++) {
    x1 = Math.min(x1, rects[i].x); y1 = Math.min(y1, rects[i].y)
    x2 = Math.max(x2, rects[i].x + rects[i].width); y2 = Math.max(y2, rects[i].y + rects[i].height)
  }
  return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 }
}

// Snap one axis: flush against an edge, or aligned start/end/center.
function _snapAxis(pos, size, others, horizontal, threshold) {
  var best = pos
  var bestDist = threshold + 1
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    var start = horizontal ? o.x : o.y
    var len = horizontal ? o.width : o.height
    var candidates = [start - size, start + len, start, start + len - size, Math.round(start + (len - size) / 2)]
    for (var c = 0; c < candidates.length; c++) {
      var d = Math.abs(candidates[c] - pos)
      if (d < bestDist) { bestDist = d; best = candidates[c] }
    }
  }
  return best
}

function snapRect(rect, others, threshold) {
  var r = clone(rect)
  r.x = _snapAxis(Math.round(rect.x), rect.width, others, true, threshold)
  r.y = _snapAxis(Math.round(rect.y), rect.height, others, false, threshold)
  return r
}

// Push `rect` out of any overlap with the smallest move that is free.
function resolveOverlaps(rect, others) {
  var r = clone(rect)
  for (var iter = 0; iter < 12; iter++) {
    var hit = null
    for (var i = 0; i < others.length; i++) if (overlaps(r, others[i])) { hit = others[i]; break }
    if (!hit) return r
    var cands = [
      { x: hit.x - r.width, y: r.y },
      { x: hit.x + hit.width, y: r.y },
      { x: r.x, y: hit.y - r.height },
      { x: r.x, y: hit.y + hit.height }
    ]
    var best = null, bestD = Infinity, fallback = null, fallbackD = Infinity
    for (var c = 0; c < cands.length; c++) {
      var t = { name: r.name, x: cands[c].x, y: cands[c].y, width: r.width, height: r.height }
      var d = Math.abs(t.x - r.x) + Math.abs(t.y - r.y)
      if (d < fallbackD) { fallbackD = d; fallback = t }
      if (!overlapsAny(t, others) && d < bestD) { bestD = d; best = t }
    }
    r = best || fallback
  }
  return r
}

function _clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v))
}

// Make sure `rect` shares an edge with at least one of `others` (no
// floating islands). Moves it to the nearest free touching spot.
function attach(rect, others) {
  if (!others.length || touchesAny(rect, others)) return clone(rect)
  var r = rect
  var best = null, bestD = Infinity
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    var yIn = _clamp(r.y, o.y - r.height + 1, o.y + o.height - 1)
    var xIn = _clamp(r.x, o.x - r.width + 1, o.x + o.width - 1)
    var cands = [
      { x: o.x + o.width, y: yIn }, { x: o.x - r.width, y: yIn },
      { x: xIn, y: o.y + o.height }, { x: xIn, y: o.y - r.height }
    ]
    for (var c = 0; c < cands.length; c++) {
      var t = { name: r.name, x: cands[c].x, y: cands[c].y, width: r.width, height: r.height }
      if (overlapsAny(t, others)) continue
      var d = Math.hypot(t.x - r.x, t.y - r.y)
      if (d < bestD) { bestD = d; best = t }
    }
  }
  return best || clone(rect)
}

// While dragging: snap, never overlap.
function dragRect(rect, others, threshold) {
  return resolveOverlaps(snapRect(rect, others, threshold), others)
}

// On drop: snap, never overlap, always attached.
function dropRect(rect, others, threshold) {
  return attach(dragRect(rect, others, threshold), others)
}

// Shift the arrangement so its top-left corner is 0,0.
function normalize(mons) {
  var out = clone(mons)
  var b = bounds(layoutRects(out))
  if (b.width === 0 && b.height === 0) return out
  for (var i = 0; i < out.length; i++) {
    if (!inLayout(out[i])) continue
    out[i].x = Math.round(out[i].x - b.x)
    out[i].y = Math.round(out[i].y - b.y)
  }
  return out
}

// After a size change (mode/scale/rotation/enable): keep `anchorName`
// where it is and move the others just enough to remove overlaps and
// reconnect them, nearest monitors first. Then normalize.
function settle(mons, anchorName) {
  var out = clone(mons)
  var layout = []
  for (var i = 0; i < out.length; i++) if (inLayout(out[i])) layout.push(out[i])
  if (layout.length < 2) return normalize(out)

  var anchor = null
  for (var a = 0; a < layout.length; a++) if (layout[a].name === anchorName) anchor = layout[a]
  if (!anchor) anchor = layout[0]
  var ar = rectOf(anchor)
  var acx = ar.x + ar.width / 2, acy = ar.y + ar.height / 2
  var rest = layout.filter(function(m) { return m !== anchor })
  rest.sort(function(p, q) {
    var pr = rectOf(p), qr = rectOf(q)
    return Math.hypot(pr.x + pr.width / 2 - acx, pr.y + pr.height / 2 - acy)
         - Math.hypot(qr.x + qr.width / 2 - acx, qr.y + qr.height / 2 - acy)
  })
  var placed = [ar]
  for (var r = 0; r < rest.length; r++) {
    var rect = attach(resolveOverlaps(rectOf(rest[r]), placed), placed)
    rest[r].x = rect.x
    rest[r].y = rect.y
    placed.push(rect)
  }
  return normalize(out)
}

// Hyprland has no "primary display". What apps (and XWayland games) treat
// as the main screen is the one at 0x0, so "make primary" puts the chosen
// monitor at the top-left and lines the others up to its right, in their
// current left-to-right order.
function makePrimary(mons, name) {
  var out = clone(mons)
  var layout = out.filter(inLayout)
  var sel = null
  for (var i = 0; i < layout.length; i++) if (layout[i].name === name) sel = layout[i]
  if (!sel) return out
  var rest = layout.filter(function(m) { return m !== sel })
  rest.sort(function(p, q) { return p.x !== q.x ? p.x - q.x : p.y - q.y })
  var order = [sel].concat(rest)
  var cursor = 0
  for (var j = 0; j < order.length; j++) {
    order[j].x = cursor
    order[j].y = 0
    cursor += rectOf(order[j]).width
  }
  return out
}

function primaryName(mons) {
  for (var i = 0; i < mons.length; i++) {
    if (inLayout(mons[i]) && Math.round(mons[i].x) === 0 && Math.round(mons[i].y) === 0) return mons[i].name
  }
  return ""
}

// ---- config parsing --------------------------------------------------------

var RULE_LINE_RE = /^\s*hl\.monitor\(\s*\{(.*)\}\s*\)\s*;?\s*(--.*)?$/

function _field(body, key) {
  var re = new RegExp("(?:^|[,{;\\s])" + key + "\\s*=\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|[^,;}\\s]+)")
  var m = String(body).match(re)
  if (!m) return undefined
  var v = m[1]
  if (v.charAt(0) === "\"") return v.slice(1, -1).replace(/\\"/g, "\"").replace(/\\\\/g, "\\")
  if (v === "true") return true
  if (v === "false") return false
  var n = Number(v)
  return isFinite(n) ? n : { expr: v }
}

// Single-line, uncommented hl.monitor({...}) call -> fields, or null.
function parseRuleLine(line) {
  var m = String(line).match(RULE_LINE_RE)
  if (!m) return null
  var out = _field(m[1], "output")
  if (typeof out !== "string") return null
  return {
    output: out,
    mode: _field(m[1], "mode"),
    position: _field(m[1], "position"),
    scale: _field(m[1], "scale"),
    transform: _field(m[1], "transform"),
    vrr: _field(m[1], "vrr"),
    mirror: _field(m[1], "mirror"),
    disabled: _field(m[1], "disabled")
  }
}

// All effective rules in file order (later ones win in Hyprland).
function parseRules(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var r = parseRuleLine(lines[i])
    if (r) { r.line = i; out.push(r) }
  }
  return out
}

// Does a Hyprland output selector match this monitor?
function selectorMatches(selector, mon) {
  var s = String(selector || "")
  if (s === "") return false
  if (s.indexOf("desc:") === 0) {
    var d = s.slice(5).trim()
    return d !== "" && String(mon.description || "").indexOf(d) === 0
  }
  return s === mon.name
}

// The rule Hyprland would use for `mon` (last specific match), or null.
function configuredRule(rules, mon) {
  for (var i = rules.length - 1; i >= 0; i--) {
    if (selectorMatches(rules[i].output, mon)) return rules[i]
  }
  return null
}

// ---- hyprctl -> state ------------------------------------------------------

function fromHyprctl(list, configText) {
  list = list || []
  var nameById = {}
  for (var i = 0; i < list.length; i++) nameById[String(list[i].id)] = list[i].name
  var rules = parseRules(configText)
  var out = []
  for (var j = 0; j < list.length; j++) {
    var m = list[j]
    var modes = parseModes(m.availableModes)
    var width = Number(m.width) || 0
    var height = Number(m.height) || 0
    var refresh = round2(m.refreshRate || 0)
    if (!(width > 0 && height > 0) && modes.length) {
      width = modes[0].width; height = modes[0].height; refresh = modes[0].refresh
    } else if (modes.length) {
      var snapped = closestRefresh(modes, width, height, refresh)
      if (snapped > 0 && Math.abs(snapped - refresh) < 0.05) refresh = snapped
    }
    var mon = {
      name: String(m.name || ""),
      description: String(m.description || "").trim(),
      make: String(m.make || "").trim(),
      model: String(m.model || "").trim(),
      serial: String(m.serial || "").trim(),
      internal: isInternal(m.name),
      enabled: m.disabled !== true,
      width: width,
      height: height,
      refresh: refresh,
      scale: Number(m.scale) > 0 ? cleanScale(m.scale) : 1,
      transform: Number(m.transform) || 0,
      x: Number(m.x) || 0,
      y: Number(m.y) || 0,
      vrr: -1,
      vrrActive: m.vrr === true,
      mirror: (m.mirrorOf !== undefined && m.mirrorOf !== null && String(m.mirrorOf) !== "none") ? (nameById[String(m.mirrorOf)] || "") : "",
      modes: modes,
      physicalWidth: Number(m.physicalWidth) || 0,
      physicalHeight: Number(m.physicalHeight) || 0,
      focused: m.focused === true
    }
    var rule = configuredRule(rules, mon)
    if (rule) {
      if (typeof rule.vrr === "number" && rule.vrr >= -1 && rule.vrr <= 3) mon.vrr = rule.vrr
      if (rule.scale === "auto") mon.scale = "auto"
    }
    out.push(mon)
  }
  out.sort(function(a, b) {
    if (a.internal !== b.internal) return a.internal ? -1 : 1
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  })
  return out
}

// ---- state -> Lua ----------------------------------------------------------

// Stable selector: port name for the built-in panel, `desc:` for externals
// (survives moving the cable to another port). Duplicate descriptions (two
// identical monitors without serials) fall back to port names.
function identifierFor(mon, mons) {
  if (mon.internal || !mon.description) return mon.name
  for (var i = 0; i < (mons || []).length; i++) {
    if (mons[i].name !== mon.name && mons[i].description === mon.description) return mon.name
  }
  return "desc:" + mon.description
}

function findMonitor(mons, name) {
  for (var i = 0; i < (mons || []).length; i++) if (mons[i].name === name) return mons[i]
  return null
}

// Lua table for hl.monitor(). `live` = for hyprctl eval: spell out every
// field so values left over from an earlier rule with the same output
// (hl.monitor merges) cannot leak through.
function ruleFor(mon, mons, live) {
  var o = { output: identifierFor(mon, mons) }
  if (!mon.enabled) {
    o.disabled = true
    return o
  }
  o.mode = modeString(mon)
  o.position = mon.mirror ? "auto" : (Math.round(mon.x) + "x" + Math.round(mon.y))
  o.scale = mon.scale === "auto" ? "auto" : Number(scaleValue(mon.scale))
  o.transform = Number(mon.transform) || 0
  if (live || mon.vrr >= 0) o.vrr = mon.vrr
  var target = mon.mirror ? findMonitor(mons, mon.mirror) : null
  if (target) o.mirror = identifierFor(target, mons)
  else if (live) o.mirror = ""
  if (live) o.disabled = false
  return o
}

function ruleLine(mon, mons, live) {
  return "hl.monitor(" + MB.luaValue(ruleFor(mon, mons, live)) + ")"
}

// Order for generated config: arrangement left-to-right, then mirrors,
// then disabled ones.
function sortedForConfig(mons) {
  var out = mons.slice()
  function rank(m) { return !m.enabled ? 2 : (m.mirror ? 1 : 0) }
  out.sort(function(a, b) {
    if (rank(a) !== rank(b)) return rank(a) - rank(b)
    if (a.x !== b.x) return a.x - b.x
    if (a.y !== b.y) return a.y - b.y
    return a.name < b.name ? -1 : 1
  })
  return out
}

// One hyprctl eval chunk applying `mons` live.
function liveLua(mons) {
  var lines = []
  var list = sortedForConfig(mons)
  for (var i = 0; i < list.length; i++) lines.push(ruleLine(list[i], mons, true))
  return lines.join("\n")
}

function displayName(mon) {
  if (mon.internal) return "Built-in display"
  var make = String(mon.make || "")
  var model = String(mon.model || "")
  // "Samsung Electric Company" -> "Samsung"
  var shortMake = make.split(/\s+/)[0] || ""
  if (model && shortMake && model.toLowerCase().indexOf(shortMake.toLowerCase()) !== 0) return shortMake + " " + model
  return model || make || mon.name
}

function _commentFor(mon) {
  var label = mon.internal ? "Built-in display" : displayName(mon)
  return COMMENT + " " + label + " (" + mon.name + ")"
}

// Rewrite the managed "monitors" block in `text` for the connected `mons`:
// - every connected monitor gets one full hl.monitor line;
// - block lines for monitors that are not connected right now are kept
//   (so the office monitor's settings survive working on the couch);
// - the user's own single-line hl.monitor rules for the same outputs are
//   commented out with DISABLED_PREFIX (Hyprland would already let the
//   block win, but Omarchy's clamshell helper reads the *first* rule for
//   the internal panel, and stale lines above are confusing to hand-edit).
//   The generic fallback rule (output = "") is never touched.
// Returns { text, commented: [original lines], kept: n }.
function buildConfig(text, mons) {
  var src = String(text || "")
  var lines = src.split("\n")
  var start = COMMENT + " >>> omatings:" + BLOCK
  var end = COMMENT + " <<< omatings:" + BLOCK
  var inBlock = false
  var commented = []
  for (var i = 0; i < lines.length; i++) {
    var trimmed = lines[i].trim()
    if (trimmed.indexOf(start) === 0) { inBlock = true; continue }
    if (trimmed.indexOf(end) === 0) { inBlock = false; continue }
    if (inBlock) continue
    var rule = parseRuleLine(lines[i])
    if (!rule || rule.output === "") continue
    var hit = false
    for (var k = 0; k < mons.length; k++) if (selectorMatches(rule.output, mons[k])) hit = true
    if (!hit) continue
    commented.push(trimmed)
    lines[i] = DISABLED_PREFIX + lines[i]
  }

  // Keep rules (with the comment right above them) for absent monitors.
  var kept = []
  var old = MB.read(src, BLOCK, COMMENT)
  if (old) {
    var bl = old.split("\n")
    var pendingComment = []
    for (var b = 0; b < bl.length; b++) {
      var line = bl[b]
      if (/^\s*--/.test(line)) { pendingComment.push(line); continue }
      var r = parseRuleLine(line)
      if (r && r.output !== "") {
        var connected = false
        for (var c = 0; c < mons.length; c++) if (selectorMatches(r.output, mons[c])) connected = true
        if (!connected) kept = kept.concat(pendingComment, [line])
      }
      pendingComment = []
    }
  }

  var body = []
  var list = sortedForConfig(mons)
  for (var j = 0; j < list.length; j++) {
    body.push(_commentFor(list[j]))
    body.push(ruleLine(list[j], mons, false))
  }
  if (kept.length) {
    body.push(COMMENT + " Displays that are not connected right now")
    body = body.concat(kept.filter(function(l) { return l.indexOf("not connected right now") === -1 }))
  }

  return {
    text: MB.replace(lines.join("\n"), BLOCK, body.join("\n"), COMMENT),
    commented: commented,
    kept: kept.filter(function(l) { return !/^\s*--/.test(l) }).length
  }
}

// What to write for `mons`. The built-in panel is never persisted as
// disabled: a config that turns it off leaves a laptop with a black screen
// once the external monitor is unplugged. Turning it off goes through
// Omarchy's own toggle instead (`omarchy hyprland monitor internal off`,
// which recovers automatically), so here it is written with its last
// settings, attached to the right of the arrangement.
function persistState(mons) {
  var out = clone(mons)
  var anchor = ""
  for (var i = 0; i < out.length; i++) if (inLayout(out[i]) && !out[i].internal) { anchor = out[i].name; break }
  var changed = false
  for (var j = 0; j < out.length; j++) {
    var m = out[j]
    if (!m.internal || m.enabled) continue
    var b = bounds(layoutRects(out, m.name))
    m.enabled = true
    m.mirror = ""
    m.x = b.x + b.width
    m.y = b.y
    changed = true
  }
  return changed && anchor ? settle(out, anchor) : out
}

// "on" / "off" / "" — the Omarchy laptop-display toggle to run after saving.
function internalToggleAction(mons, toggleActive) {
  for (var i = 0; i < mons.length; i++) {
    if (!mons[i].internal) continue
    if (!mons[i].enabled && !toggleActive) return "off"
    if (mons[i].enabled && toggleActive) return "on"
    return ""
  }
  return ""
}

// ---- diffing ---------------------------------------------------------------

function _sig(mon, mons) {
  return JSON.stringify(ruleFor(mon, mons, true))
}

function isDirty(a, b) {
  if (!a || !b) return false
  if (a.length !== b.length) return true
  for (var i = 0; i < a.length; i++) {
    var other = findMonitor(b, a[i].name)
    if (!other || _sig(a[i], a) !== _sig(other, b)) return true
  }
  return false
}

// Short human description of what changed for one monitor (for the UI).
function changeSummary(before, after, mons) {
  if (!before || !after) return ""
  var parts = []
  if (before.enabled !== after.enabled) parts.push(after.enabled ? "turn on" : "turn off")
  if (!after.enabled) return parts.join(", ")
  if (before.width !== after.width || before.height !== after.height || before.refresh !== after.refresh) parts.push(modeString(after))
  if (scaleValue(before.scale) !== scaleValue(after.scale)) parts.push("scale " + (after.scale === "auto" ? "auto" : scaleLabel(after.scale)))
  if (before.transform !== after.transform) parts.push("rotation " + rotationOf(after.transform) * 90 + "°")
  if (before.vrr !== after.vrr) parts.push("VRR")
  if (before.mirror !== after.mirror) parts.push(after.mirror ? "mirror " + after.mirror : "stop mirroring")
  if (inLayout(after) && (before.x !== after.x || before.y !== after.y)) parts.push("position")
  return parts.join(", ")
}
