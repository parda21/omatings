import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "appearance"
import "appearance/Appearance.js" as A

// Appearance: theme gallery, background, font, text size and the Hyprland
// window look (gaps, borders, rounding, blur, shadows, dimming, animations).
//
// Themes, backgrounds, font and text size go through `omarchy …` commands.
// The window look is previewed live with `hyprctl eval` and persisted
// (debounced) in the "looknfeel" managed block of ~/.config/hypr/looknfeel.lua.
// Only options the user actually touched are written, so theme-provided
// values (e.g. a theme's rounding) keep working for everything else.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // Write target for the window look. Tests point this at /tmp.
  property string looknfeelPath: Quickshell.env("HOME") + "/.config/hypr/looknfeel.lua"
  // Tests: never touch the live session (no hyprctl eval/reload).
  property bool dryRun: false

  spacing: Style.spacing.huge

  // ---- state ----------------------------------------------------------------
  property var themes: []
  property string currentTheme: ""
  property bool themesLoaded: false
  property string themeBusy: ""          // slug being applied
  property bool hasExtraThemes: false
  property bool updatingThemes: false

  property var backgrounds: ({ current: "", currentResolved: "", items: [] })
  property string backgroundBusy: ""     // path being applied
  property bool nextBackgroundBusy: false

  property var fonts: []
  property string currentFont: ""
  property bool fontBusy: false

  property int textSize: A.TEXT_DEFAULT
  property bool textSizeIsDefault: true
  property bool textSizeBusy: false
  property int _pendingTextSize: -1

  property var look: A.defaults()        // effective (live) values
  property var lookOverrides: ({})        // what our managed block holds / will hold
  property bool lookHasBlock: false
  property bool lookSaving: false
  property bool noGapsToggle: false
  property var _pendingLive: ({})

  readonly property var overrideLabels: A.overrideLabels(lookOverrides)

  function activated() {
    if (!sys) return
    loadThemes()
    loadBackgrounds()
    loadFonts()
    loadTextSize()
    if (!saveTimer.running && !lookSaving) loadLook()
    loadNoGaps()
  }

  function _err(r, fallback) {
    var t = String((r && (r.stderr || r.stdout)) || "").trim()
    return t || fallback
  }

  // ---- themes ---------------------------------------------------------------
  function loadThemes() {
    sys.sh(A.THEMES_SCRIPT, [sys.omarchyPath], function(r) {
      var parsed = A.parseThemes(r.stdout)
      page.themes = parsed.themes
      page.currentTheme = parsed.current
      page.themesLoaded = true
    })
    sys.run(["omarchy-theme-extras"], function(r) {
      page.hasExtraThemes = r.code === 0 && String(r.stdout).trim() !== ""
    })
  }

  function applyTheme(t) {
    if (!sys || themeBusy !== "") return
    if (t.slug === currentTheme) {
      if (app) app.toast(t.name + " is already the current theme")
      return
    }
    themeBusy = t.slug
    // Output goes to a temp file so background jobs spawned by the theme
    // hooks cannot keep our pipes (and the busy state) open.
    sys.sh('out=$(mktemp); omarchy theme set "$1" >"$out" 2>&1; c=$?; cat "$out"; rm -f "$out"; exit $c',
      [t.name], function(r) {
        page.themeBusy = ""
        if (r.code !== 0) {
          if (app) app.toast("Could not apply " + t.name + ": " + page._err(r, "exit " + r.code), true)
        } else {
          if (app) app.toast("Theme set to " + t.name)
        }
        page.loadThemes()
        page.loadBackgrounds()
        page.loadLook()
      })
  }

  function installTheme() {
    if (!sys) return
    sys.terminal("omarchy-theme-install")
    if (app) app.toast("Paste the theme's git URL in the terminal. Refresh this page when it's done.")
  }

  function updateThemes() {
    if (!sys || updatingThemes) return
    updatingThemes = true
    sys.sh("GIT_TERMINAL_PROMPT=0 omarchy-theme-update 2>&1", [], function(r) {
      page.updatingThemes = false
      if (r.code !== 0) {
        if (app) app.toast("Theme update failed: " + page._err(r, "exit " + r.code), true)
      } else {
        if (app) app.toast("Themes updated. Apply a theme again to use its new version.")
      }
      page.loadThemes()
    })
  }

  // ---- backgrounds ------------------------------------------------------------
  function loadBackgrounds() {
    sys.sh(A.BACKGROUNDS_SCRIPT, [], function(r) {
      page.backgrounds = A.parseBackgrounds(r.stdout)
    })
  }

  function setBackground(item) {
    if (!sys || backgroundBusy !== "" || A.isCurrentBackground(backgrounds, item)) return
    backgroundBusy = item.path
    sys.run(["omarchy", "theme", "bg", "set", item.path], function(r) {
      page.backgroundBusy = ""
      if (r.code !== 0) { if (app) app.toast("Could not set background: " + page._err(r, "exit " + r.code), true) }
      else if (app) app.toast("Background set to " + item.name)
      page.loadBackgrounds()
    })
  }

  function nextBackground() {
    if (!sys || nextBackgroundBusy) return
    nextBackgroundBusy = true
    sys.run(["omarchy", "theme", "bg", "next"], function(r) {
      page.nextBackgroundBusy = false
      if (r.code !== 0 && app) app.toast("Could not change background: " + page._err(r, "exit " + r.code), true)
      page.loadBackgrounds()
    })
  }

  function addBackgrounds() {
    if (!sys) return
    sys.detached(["omarchy-theme-bg-install"])
    if (app) app.toast("Opened the background folder for this theme. Refresh when you've added images.")
  }

  // ---- font ---------------------------------------------------------------------
  function loadFonts() {
    sys.run(["omarchy", "font", "list"], function(r) {
      if (r.code !== 0) return
      page.fonts = String(r.stdout).split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
    })
    sys.run(["omarchy", "font", "current"], function(r) {
      if (r.code === 0) page.currentFont = String(r.stdout).trim()
      fontDropdown.value = page.currentFont
    })
  }

  function requestFont(name) {
    // The dropdown shows the live font until the change actually happens.
    fontDropdown.value = currentFont
    if (!sys || !app || !name || name === currentFont) return
    app.confirm("Change the font to " + name + "? The Omarchy shell restarts to apply it, which closes this window.",
      "Change font", function() {
        page.fontBusy = true
        // Detached: omarchy font set restarts the shell this page lives in.
        page.sys.detached(["omarchy", "font", "set", name])
        if (page.app) page.app.toast("Applying " + name + "…")
      })
  }

  // ---- text size ----------------------------------------------------------------
  function loadTextSize() {
    sys.run(["omarchy", "display", "text", "size"], function(r) {
      var t = A.parseTextSize(r.stdout)
      if (!t) return
      page.textSize = t.size
      page.textSizeIsDefault = t.isDefault
    })
  }

  function requestTextSize(size) {
    _pendingTextSize = Math.round(size)
    textSize = _pendingTextSize
    textSizeTimer.restart()
  }

  function _runTextSize(arg) {
    if (!sys) return
    textSizeBusy = true
    sys.run(["omarchy", "display", "text", "size", String(arg)], function(r) {
      page.textSizeBusy = false
      if (r.code !== 0) { if (app) app.toast("Could not change text size: " + page._err(r, "exit " + r.code), true) }
      else if (app) app.toast(arg === "reset" ? "Text size reset" : "Text size set to " + arg + " px")
      page.loadTextSize()
    })
  }

  Timer {
    id: textSizeTimer
    interval: 400
    onTriggered: {
      if (page._pendingTextSize < 0) return
      var s = page._pendingTextSize
      page._pendingTextSize = -1
      page._runTextSize(s)
    }
  }

  // ---- window look --------------------------------------------------------------
  function loadLook() {
    if (!sys) return
    var names = A.OPTIONS.map(function(o) { return o.hypr })
    sys.sh('for o in "$@"; do printf "%s\\t" "$o"; hyprctl getoption "$o" -j 2>/dev/null | tr -d "\\n"; echo; done',
      names, function(r) {
        var next = A.defaults()
        var lines = String(r.stdout).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var tab = lines[i].indexOf("\t")
          if (tab < 0) continue
          var name = lines[i].slice(0, tab)
          for (var j = 0; j < A.OPTIONS.length; j++) {
            if (A.OPTIONS[j].hypr !== name) continue
            var v = A.parseGetOption(A.OPTIONS[j].key, lines[i].slice(tab + 1))
            if (v !== null) next[A.OPTIONS[j].key] = v
          }
        }
        page.look = next
      })
    sys.readFile(looknfeelPath, function(text) {
      page.lookOverrides = A.readOverrides(text)
      page.lookHasBlock = A.hasBlock(text)
    })
  }

  function loadNoGaps() {
    sys.run(["omarchy-hyprland-toggle-enabled", "window-no-gaps"], function(r) {
      page.noGapsToggle = r.code === 0
    })
  }

  function _with(obj, key, value) {
    var next = ({})
    for (var k in obj) next[k] = obj[k]
    next[key] = value
    return next
  }

  // Change one option: preview live right away, persist 600 ms later.
  function setLook(key, value) {
    var v = A.normalize(key, value)
    look = _with(look, key, v)
    lookOverrides = _with(lookOverrides, key, v)
    _pendingLive = _with(_pendingLive, key, v)
    if (!liveTimer.running) liveTimer.start()
    saveTimer.restart()
  }

  Timer {
    id: liveTimer
    interval: 50
    onTriggered: {
      var pending = page._pendingLive
      page._pendingLive = ({})
      if (page.dryRun || !page.sys) return
      page.sys.hyprEval(A.evalLua(pending), function(r) {
        var out = String(r.stdout || "") + String(r.stderr || "")
        if (r.code !== 0 || /error/i.test(out)) {
          if (page.app) page.app.toast("Live preview failed: " + out.trim(), true)
        }
      })
      if ("rounding" in pending || "gaps_out" in pending) page._refreshShellStyle()
    }
  }

  Timer {
    id: saveTimer
    interval: 600
    onTriggered: page.saveLook()
  }

  // The shell reads rounding/gaps from Hyprland at startup and on theme
  // changes; nudge it so panels (and this window) follow right away.
  function _refreshShellStyle() {
    if (dryRun) return
    if (typeof Style.scheduleRefresh === "function") Style.scheduleRefresh()
  }

  function _writeLook(transform, successText, callback) {
    if (!sys) return
    lookSaving = true
    sys.readFile(looknfeelPath, function(text, exists) {
      var next = transform(text)
      if (next === text) {
        page.lookSaving = false
        if (callback) callback(true)
        return
      }
      page.sys.writeFile(page.looknfeelPath, next, function(ok, r) {
        if (!ok) {
          page.lookSaving = false
          if (page.app) page.app.toast("Could not save " + page.looknfeelPath + ": " + page._err(r, "write failed"), true)
          if (callback) callback(false)
          return
        }
        page.lookHasBlock = A.hasBlock(next)
        if (page.dryRun) {
          page.lookSaving = false
          if (page.app) page.app.toast(successText)
          if (callback) callback(true)
          return
        }
        page.sys.hyprReload(function(errors) {
          page.lookSaving = false
          if (errors) { if (page.app) page.app.toast("Hyprland reported config errors:\n" + errors, true) }
          else if (page.app) page.app.toast(successText)
          page._refreshShellStyle()
          if (callback) callback(!errors)
        })
      })
    })
  }

  function saveLook(callback) {
    var overrides = lookOverrides
    _writeLook(function(text) { return A.applyOverrides(text, overrides) }, "Window look saved", callback)
  }

  function resetLook() {
    if (!app) return
    app.confirm("Remove your window look settings and go back to the Omarchy and theme defaults?", "Reset", function() {
      saveTimer.stop()
      page.lookOverrides = ({})
      page._writeLook(function(text) { return A.removeBlock(text) }, "Window look reset to defaults", function() {
        page.loadLook()
      })
    })
  }

  function turnOffNoGaps() {
    if (!sys) return
    sys.run(["omarchy-hyprland-toggle", "window-no-gaps", "off"], function(r) {
      if (r.code !== 0) { if (app) app.toast("Could not turn gaps back on: " + page._err(r, "exit " + r.code), true) }
      else if (app) app.toast("Gaps are back on")
      page.loadNoGaps()
      page.loadLook()
      page._refreshShellStyle()
    })
  }

  // ---- shared bits ----------------------------------------------------------------
  component SectionButtons: RowLayout {
    Layout.fillWidth: true
    spacing: Style.spacing.md
  }

  // =================================================================== Theme
  SettingsSection {
    title: "Theme"
    description: "Click a theme to apply it everywhere: shell, terminals, editors, browser and the background."

    SectionButtons {
      Text {
        Layout.fillWidth: true
        text: page.themeBusy !== "" ? "Applying theme…"
            : page.themesLoaded ? page.themes.length + " themes" : "Loading themes…"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        text: "Install theme…"
        iconText: String.fromCodePoint(0xF01DA)
        bordered: true
        tooltipText: "Install a theme from a git repository (opens a terminal)"
        onClicked: page.installTheme()
      }
      Button {
        visible: page.hasExtraThemes
        text: page.updatingThemes ? "Updating…" : "Update themes"
        iconText: String.fromCodePoint(0xF06B0)
        iconSpinning: page.updatingThemes
        bordered: true
        enabled: !page.updatingThemes
        tooltipText: "Pull the latest version of themes installed from git"
        onClicked: page.updateThemes()
      }
      Button {
        iconText: String.fromCodePoint(0xF0450)
        bordered: true
        tooltipText: "Refresh"
        onClicked: page.activated()
      }
    }

    Item {
      id: themeGridBox
      Layout.fillWidth: true
      implicitHeight: themeGrid.height
      readonly property int columns: Math.max(2, Math.floor((width + Style.spacing.lg) / (Style.space(190) + Style.spacing.lg)))
      readonly property real cellWidth: (width - Style.spacing.lg * (columns - 1)) / columns

      Grid {
        id: themeGrid
        width: parent.width
        columns: themeGridBox.columns
        spacing: Style.spacing.lg

        Repeater {
          model: page.themes
          ImageCard {
            required property var modelData
            width: themeGridBox.cellWidth
            source: A.fileUrl(modelData.preview)
            label: modelData.name
            tooltip: modelData.source === "git" ? "Installed from git" : (modelData.source === "user" ? "Your theme" : "")
            current: modelData.slug === page.currentTheme
            busy: modelData.slug === page.themeBusy
            enabled: page.themeBusy === ""
            decodeWidth: 400
            onClicked: page.applyTheme(modelData)
          }
        }
      }
    }
  }

  // ============================================================== Background
  SettingsSection {
    title: "Background"
    description: "Backgrounds that come with the current theme, plus your own for it."

    SectionButtons {
      Text {
        Layout.fillWidth: true
        text: page.backgrounds.items.length === 0 ? "This theme has no backgrounds" : page.backgrounds.items.length + " backgrounds"
        textFormat: Text.PlainText
        color: Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        text: "Add backgrounds…"
        iconText: String.fromCodePoint(0xF024B)
        bordered: true
        tooltipText: "Open this theme's folder for your own backgrounds"
        onClicked: page.addBackgrounds()
      }
      Button {
        text: "Next background"
        iconText: String.fromCodePoint(0xF0915)
        iconSpinning: page.nextBackgroundBusy
        bordered: true
        enabled: !page.nextBackgroundBusy && page.backgrounds.items.length > 1
        onClicked: page.nextBackground()
      }
    }

    Item {
      id: bgGridBox
      Layout.fillWidth: true
      visible: page.backgrounds.items.length > 0
      implicitHeight: bgGrid.height
      readonly property int columns: Math.max(2, Math.floor((width + Style.spacing.lg) / (Style.space(150) + Style.spacing.lg)))
      readonly property real cellWidth: (width - Style.spacing.lg * (columns - 1)) / columns

      Grid {
        id: bgGrid
        width: parent.width
        columns: bgGridBox.columns
        spacing: Style.spacing.lg

        Repeater {
          model: page.backgrounds.items
          ImageCard {
            required property var modelData
            width: bgGridBox.cellWidth
            source: A.fileUrl(modelData.thumb || modelData.path)
            tooltip: modelData.name + (modelData.user ? " (yours)" : "")
            current: A.isCurrentBackground(page.backgrounds, modelData)
            busy: modelData.path === page.backgroundBusy
            enabled: page.backgroundBusy === ""
            decodeWidth: 320
            onClicked: page.setBackground(modelData)
          }
        }
      }
    }
  }

  // ==================================================================== Text
  SettingsSection {
    title: "Text"

    SettingsRow {
      label: "Font"
      description: "Monospace font for the shell, terminals and other Omarchy apps. Changing it restarts the shell."
      SearchableDropdown {
        id: fontDropdown
        showLabel: false
        enabled: !page.fontBusy && page.fonts.length > 0
        options: page.fonts
        value: page.currentFont
        placeholderText: "Search fonts…"
        onChanged: function(v) { page.requestFont(v) }
      }
    }

    SettingsRow {
      label: "Text size"
      description: page.textSizeIsDefault ? "Scales text in the shell, GTK apps and terminals together. Default: "
                                           + A.TEXT_DEFAULT + " px."
                                         : "Scales text in the shell, GTK apps and terminals together. Reset returns to "
                                           + A.TEXT_DEFAULT + " px and the default terminal font size."
      RowLayout {
        spacing: Style.spacing.lg
        SliderField {
          minimum: A.TEXT_MIN
          maximum: A.TEXT_MAX
          integer: true
          value: page.textSize
          suffix: " px"
          enabled: !page.textSizeBusy
          onReleased: function(v) { page.requestTextSize(v) }
        }
        Button {
          text: "Reset"
          bordered: true
          enabled: !page.textSizeIsDefault && !page.textSizeBusy
          onClicked: page._runTextSize("reset")
        }
      }
    }
  }

  // ================================================================= Windows
  SettingsSection {
    title: "Windows"
    description: "Changes preview live and are saved to ~/.config/hypr/looknfeel.lua. Only the settings you change here are saved; everything else follows Omarchy and the current theme."

    SettingsRow {
      visible: page.noGapsToggle
      label: "Gaps are turned off"
      description: "Omarchy's \"no gaps\" toggle is on. It removes gaps, borders and rounding and overrides the values below."
      Button {
        text: "Turn gaps on"
        bordered: true
        onClicked: page.turnOffNoGaps()
      }
    }

    SettingsRow {
      label: "Inner gaps"
      description: "Space between windows."
      SliderField {
        minimum: A.option("gaps_in").min; maximum: A.option("gaps_in").max
        value: page.look.gaps_in; suffix: " px"
        onMoved: function(v) { page.setLook("gaps_in", v) }
      }
    }

    SettingsRow {
      label: "Outer gaps"
      description: "Space between windows and the screen edges. Omarchy panels keep half of it to the edge."
      SliderField {
        minimum: A.option("gaps_out").min; maximum: A.option("gaps_out").max
        value: page.look.gaps_out; suffix: " px"
        onMoved: function(v) { page.setLook("gaps_out", v) }
      }
    }

    SettingsRow {
      label: "Border size"
      description: "Border colors come from the theme."
      SliderField {
        minimum: A.option("border_size").min; maximum: A.option("border_size").max
        value: page.look.border_size; suffix: " px"
        onMoved: function(v) { page.setLook("border_size", v) }
      }
    }

    SettingsRow {
      label: "Rounding"
      description: "Corner radius of windows. Omarchy panels and this window follow it. Some themes set their own rounding; a value saved here wins over every theme."
      SliderField {
        minimum: A.option("rounding").min; maximum: A.option("rounding").max
        value: page.look.rounding; suffix: " px"
        onMoved: function(v) { page.setLook("rounding", v) }
      }
    }

    SettingsRow {
      label: "Blur"
      description: "Blur what's behind transparent windows. Uses more GPU."
      ToggleSwitch {
        checked: page.look.blur
        onToggled: page.setLook("blur", !page.look.blur)
      }
    }

    SettingsRow {
      label: "Shadows"
      description: "Drop shadows under windows."
      ToggleSwitch {
        checked: page.look.shadow
        onToggled: page.setLook("shadow", !page.look.shadow)
      }
    }

    SettingsRow {
      label: "Dim inactive windows"
      description: "Darken windows that don't have focus."
      ToggleSwitch {
        checked: page.look.dim_inactive
        onToggled: page.setLook("dim_inactive", !page.look.dim_inactive)
      }
    }

    SettingsRow {
      visible: page.look.dim_inactive
      label: "Dim strength"
      SliderField {
        minimum: 0; maximum: 1; step: 0.05; integer: false; decimals: 2
        value: page.look.dim_strength
        onMoved: function(v) { page.setLook("dim_strength", Math.round(v * 20) / 20) }
      }
    }

    SettingsRow {
      label: "Animations"
      description: "Animate opening, closing and moving windows and workspaces."
      ToggleSwitch {
        checked: page.look.animations
        onToggled: page.setLook("animations", !page.look.animations)
      }
    }

    PanelSeparator { Layout.fillWidth: true }

    SettingsRow {
      label: "Reset to defaults"
      description: page.overrideLabels.length > 0
                   ? "Saved here: " + page.overrideLabels.join(", ") + "."
                   : "Nothing saved here. Using Omarchy and theme defaults."
      Button {
        text: page.lookSaving ? "Saving…" : "Reset"
        bordered: true
        enabled: page.lookHasBlock && !page.lookSaving
        onClicked: page.resetLook()
      }
    }
  }
}
