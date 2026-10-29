.pragma library

// Pure helpers for the Sound page. Adapted from Omarchy's built-in audio
// panel (/usr/share/omarchy/shell/plugins/panels/audio/Model.js) so labels,
// glyphs and stream detection match what the bar panel shows.

function glyph(cp) { return String.fromCodePoint(cp) }

var G = {
  speaker: 0xF04C3,
  headphones: 0xF02CB,
  bluetooth: 0xF00AF,
  monitor: 0xF0379,
  mic: 0xF036C,
  micOff: 0xF036D,
  camera: 0xF0100,
  volHigh: 0xF057E,
  volMed: 0xF0580,
  volLow: 0xF057F,
  volOff: 0xF075F,
  tune: 0xF062E
}

// Playback streams publish `isSink: true`; avoid reading node.properties to
// classify (it is invalid until the node is bound — see the built-in panel).
function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true
  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function isAudioSource(node) {
  if (!node) return false
  if (node.audio) return true
  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Audio/Source") !== -1
    || mediaClass.indexOf("AudioSource") !== -1
    || mediaClass.indexOf("Source") !== -1
}

function parseSinkAvailability(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
  }
  return next
}

function friendlyDeviceLabel(text) {
  var label = String(text || "").trim()
  label = label.replace(/^sof-soundwire\s+/i, "")
  label = label.replace(/^built-?in audio\s+/i, "")
  label = label.replace(/\s+Output$/i, "")
  label = label.replace(/\s+Input$/i, "")
  label = label.replace(/\bMicrophones\b/g, "Microphone")
  return label
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function nodeLabel(node) {
  if (!node) return "Unknown"
  var p = nodeProps(node)
  var nickname = friendlyDeviceLabel(node.nickname || p["node.nick"] || p["device.profile.description"] || "")
  if (nickname) return nickname
  return friendlyDeviceLabel(node.description || p["node.description"] || node.name || "Unknown")
}

// Secondary line: the full description when the nickname shortened it.
function nodeDetail(node) {
  if (!node) return ""
  var p = nodeProps(node)
  var desc = String(node.description || p["node.description"] || "").trim()
  var label = nodeLabel(node)
  if (!desc || desc === label) return ""
  return desc
}

function blobOf(node, extraKeys) {
  var p = nodeProps(node)
  var parts = [node.name, node.description, node.nickname]
  for (var i = 0; i < extraKeys.length; i++) parts.push(p[extraKeys[i]] || "")
  return String(parts.join(" ")).toLowerCase()
}

function isHeadphones(node) {
  if (!node) return false
  var blob = blobOf(node, ["device.icon-name", "device.product.name", "node.description", "node.nick"])
  return blob.indexOf("headphone") !== -1
    || blob.indexOf("headset") !== -1
    || blob.indexOf("earbud") !== -1
    || blob.indexOf("earphone") !== -1
    || blob.indexOf("airpod") !== -1
}

function sinkGlyph(node) {
  if (!node) return glyph(G.speaker)
  if (isHeadphones(node)) return glyph(G.headphones)
  var blob = blobOf(node, ["device.icon-name", "device.product.name"])
  if (blob.indexOf("bluetooth") !== -1 || blob.indexOf("bluez") !== -1) return glyph(G.bluetooth)
  if (blob.indexOf("hdmi") !== -1 || blob.indexOf("display") !== -1) return glyph(G.monitor)
  return glyph(G.speaker)
}

function sourceGlyph(node) {
  if (!node) return glyph(G.mic)
  var blob = blobOf(node, ["device.icon-name"])
  if (blob.indexOf("headset") !== -1) return glyph(G.headphones)
  if (blob.indexOf("bluetooth") !== -1 || blob.indexOf("bluez") !== -1) return glyph(G.bluetooth)
  if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return glyph(G.camera)
  return glyph(G.mic)
}

function volumeGlyph(volume, muted) {
  if (muted || volume <= 0) return glyph(G.volOff)
  if (volume >= 0.67) return glyph(G.volHigh)
  if (volume >= 0.34) return glyph(G.volMed)
  return glyph(G.volLow)
}

function micGlyph(muted) {
  return glyph(muted ? G.micOff : G.mic)
}

// ---- per-app stream labels (with MPRIS fallback for generic names) --------

function friendlyStreamLabel(label) {
  label = String(label || "").trim()
  if (!label) return ""
  var known = { "spotify": "Spotify" }
  return known[label.toLowerCase()] || label
}

function streamLabelKey(label) { return String(label || "").trim().toLowerCase() }
function streamLabelIsGeneric(label) { return streamLabelKey(label) === "audio-src" }

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"] || node.description || p["media.name"] || p["node.name"] || node.name
}

function streamMediaName(node) {
  var p = nodeProps(node)
  var media = String(p["media.name"] || "").trim()
  var label = String(rawStreamLabel(node) || "").trim()
  if (!media || media === label || streamLabelIsGeneric(media)) return ""
  return media
}

function mprisPlayerLabel(player) {
  if (!player) return ""
  return friendlyStreamLabel(player.identity || player.desktopEntry || "")
}

function mprisPlayerIsProxy(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
  var streamKey = streamLabelKey(friendlyStreamLabel(streamLabel))
  var playerKey = streamLabelKey(playerLabel)
  if (!streamKey || !playerKey) return false
  return streamKey === playerKey || streamKey.indexOf(playerKey) !== -1 || playerKey.indexOf(streamKey) !== -1
}

function mprisLabelsFor(players, predicate) {
  var values = Array.isArray(players) ? players : []
  var playing = [], all = [], playingProxy = [], proxy = []
  for (var i = 0; i < values.length; i++) {
    var player = values[i]
    if (!player) continue
    if (!player.isPlaying && !player.canPlay) continue
    var label = mprisPlayerLabel(player)
    if (!label || !predicate(label)) continue
    if (mprisPlayerIsProxy(player)) {
      if (player.isPlaying) playingProxy.push(label)
      proxy.push(label)
    } else {
      if (player.isPlaying) playing.push(label)
      all.push(label)
    }
  }
  if (playing.length === 1) return playing[0]
  if (playing.length === 0 && playingProxy.length === 1) return playingProxy[0]
  if (all.length === 1) return all[0]
  if (all.length === 0 && proxy.length === 1) return proxy[0]
  return ""
}

function streamLabel(node, players, streams) {
  if (!node) return "Stream"
  var label = rawStreamLabel(node)
  var match = ""
  if (!streamLabelIsGeneric(label)) {
    match = mprisLabelsFor(players, function(pl) { return streamRepresentsMprisPlayer(label, pl) })
  } else {
    match = mprisLabelsFor(players, function(pl) {
      var values = Array.isArray(streams) ? streams : []
      for (var i = 0; i < values.length; i++) {
        var other = rawStreamLabel(values[i])
        if (!streamLabelIsGeneric(other) && streamRepresentsMprisPlayer(other, pl)) return false
      }
      return true
    })
  }
  return friendlyStreamLabel(match || label) || "Stream"
}

// ---- balance ---------------------------------------------------------------
// `channels` holds PwAudioChannel enum values; the caller passes the enum
// values for FrontLeft/FrontRight so this file stays import-free.

function stereoIndexes(channels, frontLeft, frontRight) {
  var list = channels || []
  if (list.length !== 2) return null
  var l = -1, r = -1
  for (var i = 0; i < list.length; i++) {
    if (list[i] === frontLeft) l = i
    else if (list[i] === frontRight) r = i
  }
  return l >= 0 && r >= 0 ? { left: l, right: r } : null
}

// -1 = fully left, 0 = centered, 1 = fully right.
function balanceOf(volumes, idx) {
  if (!idx || !volumes || volumes.length !== 2) return 0
  var l = volumes[idx.left], r = volumes[idx.right]
  var m = Math.max(l, r)
  if (m <= 0.0001) return 0
  if (r >= l) return 1 - l / m
  return -(1 - r / m)
}

function volumesFor(volume, balance, idx) {
  var b = Math.max(-1, Math.min(1, balance))
  if (Math.abs(b) < 0.02) b = 0
  var v = Math.max(0, volume)
  var out = [v, v]
  out[idx.left] = b > 0 ? v * (1 - b) : v
  out[idx.right] = b < 0 ? v * (1 + b) : v
  return out
}

function maxOf(list) {
  var m = 0
  for (var i = 0; i < (list || []).length; i++) m = Math.max(m, list[i])
  return m
}

function percent(v) { return Math.round(Math.max(0, v) * 100) + "%" }
