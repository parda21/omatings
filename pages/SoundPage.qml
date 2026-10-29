import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "sound"
import "sound/Model.js" as Model

// Sound: output/input devices, volumes, balance, per-app streams.
//
// Everything is live-bound through Quickshell.Services.Pipewire, the same way
// Omarchy's audio panel works (plugins/panels/audio). Default switching goes
// through `omarchy-audio-{output,input}-set-default` so active streams move
// along; wpctl is the fallback for nodes whose audio interface is not bound.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  spacing: Style.spacing.huge

  // The window is actually showing this page (false in the headless check).
  readonly property bool onScreen: page.visible && !!app && !!app.window && app.window.visible === true

  // ---- live PipeWire model ------------------------------------------------
  readonly property bool pwReady: Pipewire.ready
  // Don't flash "not reachable" while the service connects.
  property bool pwGrace: true
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream || !Model.isAudioSource(n)) continue
      if ((n.name || "") === "quickshell") continue
      // Monitors of sinks are not microphones.
      if (String(n.name || "").indexOf(".monitor") !== -1) continue
      list.push(n)
    }
    return list
  }

  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !Model.isPlaybackStream(n)) continue
      if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
      if (n.audio) list.push(n)
    }
    return list
  }

  // Sink name -> available (from omarchy-audio-sink-availability). Hides
  // unplugged jacks and the physical sink a speaker tuning sits in front of.
  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false

  readonly property var audioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) {
      var n = candidateSinks[i]
      if (!sinkAvailabilityLoaded || !n.name || sinkAvailability[String(n.name)] !== false) list.push(n)
    }
    if (sink && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var audioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }

  // Repeaters read snapshots, refreshed shortly after PipeWire settles; the
  // built-in panel found rebuilding straight from removal signals unstable.
  property var displaySinks: []
  property var displaySources: []
  property var displayStreams: []

  onAudioSinksChanged: scheduleRefresh()
  onAudioSourcesChanged: scheduleRefresh()
  onCandidateStreamsChanged: scheduleRefresh()
  onVisibleChanged: if (visible) scheduleRefresh(); else clearDisplay()

  function scheduleRefresh() { if (page.visible) refreshTimer.restart() }
  function refreshDisplay() {
    if (!page.visible) return
    displaySinks = audioSinks.slice()
    displaySources = audioSources.slice()
    displayStreams = candidateStreams.slice()
  }
  function clearDisplay() {
    refreshTimer.stop()
    displaySinks = []
    displaySources = []
    displayStreams = []
  }

  // The sink whose volume is the real loudness: a speaker tuning or
  // EasyEffects sink resolves to the physical sink it feeds.
  property string volumeSinkName: ""
  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio) return n
    }
    return sink
  }
  onSinkChanged: resolveVolumeSink()

  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: !!(source && source.audio)
  readonly property bool outputMuted: hasOutput ? volumeSink.audio.muted : false
  readonly property bool inputMuted: hasInput ? source.audio.muted : false
  readonly property real inputVolume: hasInput ? source.audio.volume : 0

  // Balance (stereo sinks only).
  readonly property var stereoIdx: hasOutput
    ? Model.stereoIndexes(volumeSink.audio.channels, PwAudioChannel.FrontLeft, PwAudioChannel.FrontRight)
    : null
  readonly property var outputVolumes: hasOutput ? volumeSink.audio.volumes : []
  readonly property real outputBalance: stereoIdx ? Model.balanceOf(outputVolumes, stereoIdx) : 0
  // With balance applied the average understates the level; show the louder side.
  readonly property real outputVolume: !hasOutput ? 0
    : (stereoIdx ? Model.maxOf(outputVolumes) : volumeSink.audio.volume)

  property string switchingId: ""

  // ---- tools / helpers detected on activation (read-only) ----------------
  property string mixerCommand: ""
  property bool tuningAvailable: false
  property bool tuningInstalled: false
  property bool tuningBusy: false

  function activated() {
    if (!sys) return
    refreshSinkAvailability()
    resolveVolumeSink()
    refreshDisplay()
    sys.sh("for c in wiremix pulsemixer pavucontrol alsamixer; do command -v \"$c\" >/dev/null 2>&1 && { echo \"$c\"; exit 0; }; done; exit 1",
      [], function(r) { page.mixerCommand = r.code === 0 ? r.stdout.trim() : "" })
    refreshTuning()
  }

  function refreshSinkAvailability() {
    if (!sys) return
    sys.run(["omarchy-audio-sink-availability"], function(r) {
      if (r.code !== 0) return
      page.sinkAvailability = Model.parseSinkAvailability(r.stdout)
      page.sinkAvailabilityLoaded = true
    })
  }

  function resolveVolumeSink() {
    if (!sys) return
    sys.run(["omarchy-audio-output-sink"], function(r) {
      page.volumeSinkName = r.code === 0 ? String(r.stdout).trim() : ""
    })
  }

  function refreshTuning() {
    if (!sys) return
    sys.run(["omarchy-audio-tuning", "status"], function(r) {
      var out = String(r.stdout || "")
      page.tuningInstalled = /Installed:\s+yes/.test(out)
      page.tuningAvailable = page.tuningInstalled || (/Matches:/.test(out) && !/nothing ships/.test(out))
    })
  }

  // ---- actions (only from explicit user input) ---------------------------
  function setNodeVolume(node, v) {
    if (!node) return
    if (node.audio) node.audio.volume = v
    else if (sys) sys.run(["wpctl", "set-volume", String(node.id), v.toFixed(2)])
  }

  function toggleNodeMute(node) {
    if (!node) return
    if (node.audio) node.audio.muted = !node.audio.muted
    else if (sys) sys.run(["wpctl", "set-mute", String(node.id), "toggle"])
  }

  function setOutputVolume(v) {
    var node = volumeSink
    if (!node) return
    var volume = Math.max(0, Math.min(1, v))
    if (node.audio && stereoIdx && Math.abs(outputBalance) > 0.001)
      node.audio.volumes = Model.volumesFor(volume, outputBalance, stereoIdx)
    else setNodeVolume(node, volume)
  }

  function setOutputBalance(b) {
    if (!hasOutput || !stereoIdx) return
    volumeSink.audio.volumes = Model.volumesFor(outputVolume, b, stereoIdx)
  }

  function setDefault(node, isOutput) {
    if (!node || !sys) return
    var label = Model.nodeLabel(node)
    switchingId = String(node.id)
    if (isOutput) Pipewire.preferredDefaultAudioSink = node
    else Pipewire.preferredDefaultAudioSource = node
    var cmd = isOutput ? "omarchy-audio-output-set-default" : "omarchy-audio-input-set-default"
    sys.run([cmd, String(node.id), String(node.name || "")], function(r) {
      page.switchingId = ""
      if (r.code !== 0) app.toast("Could not switch " + (isOutput ? "output" : "input") + ": " + (r.stderr || r.stdout).trim(), true)
      else app.toast((isOutput ? "Output: " : "Input: ") + label)
    })
  }

  function openMixer() {
    if (!sys || mixerCommand === "") return
    if (mixerCommand === "pavucontrol") sys.detached(["omarchy-launch-or-focus", "pavucontrol", "uwsm-app -- pavucontrol"])
    else sys.detached(["omarchy-launch-or-focus-tui", mixerCommand])
    app.toast("Opening " + mixerCommand)
  }

  function openAudioPanel() {
    if (!sys) return
    sys.detached(["omarchy-shell", "shell", "toggle", "omarchy.audio"])
  }

  function setTuning(on) {
    if (!sys || tuningBusy) return
    tuningBusy = true
    sys.run(["omarchy-audio-tuning", on ? "on" : "off"], function(r) {
      page.tuningBusy = false
      var msg = String(r.stdout || "").trim().split("\n").pop()
      if (r.code !== 0) app.toast("Speaker tuning failed: " + (String(r.stderr || "").trim() || msg), true)
      else app.toast(msg || (on ? "Speaker tuning on" : "Speaker tuning off"))
      page.refreshTuning()
      page.refreshSinkAvailability()
      page.resolveVolumeSink()
    })
  }

  function restartAudio() {
    app.confirm("Restart PipeWire and WirePlumber? Playing audio will stop briefly.", "Restart", function() {
      sys.terminal("omarchy-restart-audio")
    })
  }

  // ---- plumbing -----------------------------------------------------------
  // Bind the nodes so their audio interface (volume/mute/channels) is live.
  PwObjectTracker { objects: page.candidateSinks }
  PwObjectTracker { objects: page.candidateSources }
  PwObjectTracker { objects: page.candidateStreams }

  // Live microphone level. Opens a capture stream, so only while on screen.
  PwNodePeakMonitor {
    id: peakMonitor
    node: page.source
    enabled: page.onScreen && page.hasInput
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: page.pwGrace = false
  }

  Timer {
    id: refreshTimer
    interval: 75
    onTriggered: page.refreshDisplay()
  }

  // Jacks get plugged in while the page is open.
  Timer {
    interval: 5000
    repeat: true
    running: page.onScreen
    onTriggered: page.refreshSinkAvailability()
  }

  // ---- UI -----------------------------------------------------------------
  SettingsSection {
    visible: !page.pwReady && !page.pwGrace
    title: "Audio service"
    SettingsRow {
      label: "PipeWire is not reachable"
      description: "Sound devices can't be listed. Restarting the audio services usually fixes this."
      Button { text: "Restart audio"; bordered: true; onClicked: page.restartAudio() }
    }
  }

  SettingsSection {
    title: "Output"

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xs

      Repeater {
        model: page.displaySinks
        DeviceRow {
          required property var modelData
          glyph: Model.sinkGlyph(modelData)
          label: Model.nodeLabel(modelData)
          detail: Model.nodeDetail(modelData)
          selected: !!page.sink && page.sink.id === modelData.id
          busy: page.switchingId === String(modelData.id)
          onClicked: page.setDefault(modelData, true)
        }
      }

      EmptyText {
        visible: page.pwReady && page.displaySinks.length === 0
        text: "No output devices found"
      }
    }

    SettingsRow {
      visible: page.hasOutput
      stacked: true
      label: "Volume"
      description: page.volumeSink && page.sink && page.volumeSink !== page.sink
        ? "Adjusts " + Model.nodeLabel(page.volumeSink) + " behind " + Model.nodeLabel(page.sink) + "."
        : ""
      VolumeRow {
        width: parent.width
        value: page.outputVolume
        muted: page.outputMuted
        iconText: Model.volumeGlyph(page.outputVolume, page.outputMuted)
        onMoved: function(v) { page.setOutputVolume(v) }
        onMuteToggled: page.toggleNodeMute(page.volumeSink)
      }
    }

    SettingsRow {
      visible: page.hasOutput && !!page.stereoIdx
      stacked: true
      label: "Balance"
      VolumeRow {
        width: parent.width
        minimum: -1
        maximum: 1
        step: 0.1
        value: page.outputBalance
        valueText: Math.abs(page.outputBalance) < 0.02 ? "Center"
          : (page.outputBalance < 0 ? "L " : "R ") + Math.round(Math.abs(page.outputBalance) * 100) + "%"
        onMoved: function(v) { page.setOutputBalance(Math.abs(v) < 0.05 ? 0 : v) }
        onMuteToggled: page.setOutputBalance(0)
      }
    }
  }

  SettingsSection {
    title: "Input"

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xs

      Repeater {
        model: page.displaySources
        DeviceRow {
          required property var modelData
          glyph: Model.sourceGlyph(modelData)
          label: Model.nodeLabel(modelData)
          detail: Model.nodeDetail(modelData)
          selected: !!page.source && page.source.id === modelData.id
          busy: page.switchingId === String(modelData.id)
          onClicked: page.setDefault(modelData, false)
        }
      }

      EmptyText {
        visible: page.pwReady && page.displaySources.length === 0
        text: "No input devices found"
      }
    }

    SettingsRow {
      visible: page.hasInput
      stacked: true
      label: "Volume"
      VolumeRow {
        width: parent.width
        value: page.inputVolume
        muted: page.inputMuted
        iconText: Model.micGlyph(page.inputMuted)
        onMoved: function(v) { page.setNodeVolume(page.source, Math.max(0, Math.min(1, v))) }
        onMuteToggled: page.toggleNodeMute(page.source)
      }
    }

    SettingsRow {
      visible: page.hasInput
      stacked: true
      label: "Input level"
      description: page.inputMuted ? "Microphone is muted." : "Speak to test your microphone."

      Rectangle {
        width: parent.width
        height: Math.max(Style.space(6), Style.spacing.sm)
        radius: Style.cornerRadius > 0 ? height / 2 : 0
        color: Util.alpha(Commons.Color.foreground, 0.15)
        opacity: page.inputMuted ? 0.4 : 1.0

        Rectangle {
          height: parent.height
          radius: parent.radius
          width: parent.width * Math.max(0, Math.min(1, peakMonitor.enabled ? peakMonitor.peak : 0))
          color: Commons.Color.accent
          Behavior on width { NumberAnimation { duration: 70 } }
        }
      }
    }
  }

  SettingsSection {
    title: "Applications"

    Repeater {
      model: page.displayStreams
      StreamRow {
        required property var modelData
        node: modelData
        label: Model.streamLabel(modelData, page.mprisPlayers, page.displayStreams)
        setVolume: page.setNodeVolume
        toggleMute: page.toggleNodeMute
      }
    }

    EmptyText {
      visible: page.displayStreams.length === 0
      text: "No apps are playing audio"
    }
  }

  SettingsSection {
    title: "Advanced"

    SettingsRow {
      visible: page.tuningAvailable
      label: "Speaker tuning"
      description: "Omarchy's speaker correction for this laptop."
      ToggleSwitch {
        checked: page.tuningInstalled
        busy: page.tuningBusy
        onToggled: page.setTuning(!page.tuningInstalled)
      }
    }

    SettingsRow {
      label: "Audio panel"
      description: "The quick audio controls from the top bar."
      Button { text: "Open"; bordered: true; onClicked: page.openAudioPanel() }
    }

    SettingsRow {
      visible: page.mixerCommand !== ""
      label: "Mixer"
      description: "Per-device profiles and ports in " + page.mixerCommand + "."
      Button { text: "Open mixer"; iconText: Model.glyph(Model.G.tune); bordered: true; onClicked: page.openMixer() }
    }

    SettingsRow {
      label: "Restart audio"
      description: "Restarts PipeWire and WirePlumber when sound stops working."
      Button { text: "Restart"; bordered: true; onClicked: page.restartAudio() }
    }
  }

  component EmptyText: Text {
    textFormat: Text.PlainText
    color: Util.alpha(Commons.Color.foreground, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
    Layout.leftMargin: Style.spacing.rowPaddingX
  }
}
