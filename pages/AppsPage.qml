import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"
import "apps/AppsModel.js" as Model

// Default Apps: browser, editor, terminal and coding agent the Omarchy way
// (`omarchy default <kind>`), plus default handlers for common file types
// (mimeapps.list, like xdg-mime).
//
//   current value   `omarchy-default-<kind>` with no argument (read-only)
//   candidates      the Omarchy menu's `omarchy-cmd-present <cmd>` checks
//   set             `omarchy-default-<kind> <value>` — except the agent: that
//                   command also launches the agent, so the page writes the
//                   same state file (~/.config/omarchy/defaults/agent) itself
//                   for agents that are already installed.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  // Write targets. Empty = the real files. Tests point them at /tmp.
  property string agentPath: ""
  property string mimeappsPath: ""

  spacing: Style.spacing.huge

  // ---- state ---------------------------------------------------------------
  property var current: ({ browser: "", editor: "", terminal: "", agent: "" })
  property var installed: ({})          // value -> true (browsers/editors/terminals)
  property var installedAgents: ({})    // agent -> true
  property string busyKind: ""
  property bool appsLoaded: false

  property var mimeScan: ({ defaults: {}, apps: {} })
  property string busyMime: ""

  readonly property color fg: Commons.Color.foreground

  function agentFile() { return agentPath !== "" ? agentPath : sys.home + "/.config/omarchy/defaults/agent" }
  function mimeappsFile() { return mimeappsPath !== "" ? mimeappsPath : sys.home + "/.config/mimeapps.list" }

  function listFor(kind) {
    if (kind === "browser") return Model.BROWSERS
    if (kind === "editor") return Model.EDITORS
    if (kind === "terminal") return Model.TERMINALS
    return Model.AGENTS
  }

  // ---- loading -------------------------------------------------------------
  function activated() {
    if (!sys) return
    loadCurrent()
    loadInstalled()
    loadMime()
  }

  function loadCurrent() {
    sys.sh("printf 'browser\\t%s\\n' \"$(omarchy-default-browser 2>/dev/null)\"\n"
      + "printf 'editor\\t%s\\n' \"$(omarchy-default-editor 2>/dev/null)\"\n"
      + "printf 'terminal\\t%s\\n' \"$(omarchy-default-terminal 2>/dev/null)\"\n"
      + "printf 'agent\\t%s\\n' \"$(omarchy-default-agent 2>/dev/null)\"\n",
      [], function(r) {
        var next = { browser: "", editor: "", terminal: "", agent: "" }
        var lines = String(r.stdout || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var tab = lines[i].indexOf("\t")
          if (tab > 0) next[lines[i].substring(0, tab)] = lines[i].substring(tab + 1).trim()
        }
        page.current = next
        page.syncDropdowns()
      })
  }

  function loadInstalled() {
    var specs = []
    var lists = [Model.BROWSERS, Model.EDITORS, Model.TERMINALS]
    for (var l = 0; l < lists.length; l++)
      for (var i = 0; i < lists[l].length; i++) specs.push("cmd|" + lists[l][i].value + "|" + lists[l][i].command)
    for (var a = 0; a < Model.AGENTS.length; a++)
      specs.push("agent|" + Model.AGENTS[a].value + "|" + (Model.AGENTS[a].package || ""))

    // Agent detection follows omarchy-default-agent's agent_present (a
    // user-owned ~/.local/bin/<agent> or a mise install), without running
    // `mise where` (slow) or the Hermes/OpenClaw installers.
    sys.sh("tools=$(mise ls --installed --json 2>/dev/null | jq -r 'keys[]' 2>/dev/null)\n"
      + "wrapper() { [[ -f $1 && ! -L $1 ]] && grep -q '^mise use -g' \"$1\"; }\n"
      + "for spec in \"$@\"; do\n"
      + "  IFS='|' read -r kind value extra <<<\"$spec\"\n"
      + "  if [[ $kind == cmd ]]; then command -v -- \"$extra\" >/dev/null 2>&1 && echo \"cmd $value\"; continue; fi\n"
      + "  own=$HOME/.local/bin/$value\n"
      + "  if [[ -x $own ]] && ! wrapper \"$own\"; then echo \"agent $value\"; continue; fi\n"
      + "  if [[ -n $extra ]] && grep -qxF -- \"$extra\" <<<\"$tools\"; then echo \"agent $value\"; continue; fi\n"
      + "  p=$(command -v -- \"$value\" 2>/dev/null) || continue\n"
      + "  [[ $p == \"$own\" ]] && wrapper \"$own\" && continue\n"
      + "  echo \"agent $value\"\n"
      + "done\n",
      specs, function(r) {
        var cmds = {}
        var agents = {}
        var lines = String(r.stdout || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim().split(" ")
          if (p.length !== 2) continue
          if (p[0] === "cmd") cmds[p[1]] = true
          else if (p[0] === "agent") agents[p[1]] = true
        }
        page.installed = cmds
        page.installedAgents = agents
        page.appsLoaded = true
        page.syncDropdowns()
      })
  }

  function loadMime() {
    var primaries = Model.MIME_GROUPS.map(function(g) { return g.types[0] })
    // For each primary type: the current default (xdg-mime, ignoring the
    // desktop-specific list like omarchy-default-browser does) and every
    // registered app with its Name/NoDisplay/MimeType.
    sys.sh("IFS=: read -ra dirs <<<\"${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\"\n"
      + "field() { awk -v k=\"$1\" -F= '/^\\[Desktop Entry\\]/{s=1;next} /^\\[/{s=0} s && $1==k {print substr($0, length(k)+2); exit}' \"$2\"; }\n"
      + "for mime in \"$@\"; do\n"
      + "  printf 'default\\t%s\\t%s\\n' \"$mime\" \"$(XDG_CURRENT_DESKTOP= xdg-mime query default \"$mime\" 2>/dev/null)\"\n"
      + "  gio mime \"$mime\" 2>/dev/null | awk '/^Registered applications:/{r=1;next} /^[A-Za-z]/{r=0} r && NF {print $1}' | while read -r id; do\n"
      + "    for d in \"${dirs[@]}\"; do f=$d/applications/$id; [[ -r $f ]] || continue\n"
      + "      printf 'app\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$mime\" \"$id\" \"$(field Name \"$f\")\" \"$(field NoDisplay \"$f\")\" \"$(field MimeType \"$f\")\"\n"
      + "      break\n"
      + "    done\n"
      + "  done\n"
      + "done\n",
      primaries, function(r) {
        page.mimeScan = Model.parseMimeScan(r.stdout)
      })
  }

  function syncDropdowns() {
    browserDropdown.value = current.browser
    editorDropdown.value = current.editor
    terminalDropdown.value = current.terminal
    agentDropdown.value = current.agent
  }

  // ---- actions -------------------------------------------------------------
  function setCurrent(kind, value) {
    var next = ({})
    for (var k in current) next[k] = current[k]
    next[kind] = value
    current = next
  }

  function setDefault(kind, value) {
    if (busyKind !== "" || value === current[kind]) return
    var label = Model.labelFor(listFor(kind), value)

    if (kind === "agent") {
      busyKind = kind
      sys.writeFile(agentFile(), value + "\n", function(ok, r) {
        page.busyKind = ""
        if (!ok) {
          page.syncDropdowns()
          app.toast("Could not save default agent: " + (r && r.stderr ? r.stderr : "write failed"), true)
          return
        }
        page.setCurrent("agent", value)
        page.syncDropdowns()
        app.toast(label + " is now the default agent")
      })
      return
    }

    busyKind = kind
    sys.run(["omarchy-default-" + kind, value], function(r) {
      page.busyKind = ""
      if (r.code !== 0) {
        page.syncDropdowns()
        app.toast("Could not set default " + kind + ": " + (r.stderr || r.stdout || ("exit " + r.code)), true)
        return
      }
      app.toast(label + " is now the default " + kind)
      page.loadCurrent()
      if (kind === "browser") page.loadMime()
    })
  }

  function appFor(group, id) {
    var apps = mimeScan.apps[group.types[0]] || []
    for (var i = 0; i < apps.length; i++) if (apps[i].id === id) return apps[i]
    return null
  }

  function setMimeDefault(group, id) {
    if (busyMime !== "") return
    var current = mimeScan.defaults[group.types[0]] || ""
    if (id === current) return
    var appEntry = appFor(group, id)
    var types = Model.typesFor(group, appEntry)
    var assignments = ({})
    for (var i = 0; i < types.length; i++) assignments[types[i]] = id

    busyMime = group.id
    var path = mimeappsFile()
    // mimeapps.list may be a symlink (dotfiles); write through to its target.
    sys.run(["readlink", "-f", "--", path], function(rl) {
      var target = rl.code === 0 && rl.stdout.trim() !== "" ? rl.stdout.trim() : path
      sys.readFile(target, function(text) {
        sys.writeFile(target, Model.setDefaults(text, assignments), function(ok, r) {
          page.busyMime = ""
          if (!ok) {
            app.toast("Could not save mimeapps.list: " + (r && r.stderr ? r.stderr : "write failed"), true)
          } else {
            app.toast((appEntry ? appEntry.name : id.replace(/\.desktop$/, "")) + " is now the " + group.label.toLowerCase())
          }
          page.loadMime()
        })
      })
    })
  }

  // ---- view ------------------------------------------------------------------
  component ValueText: Text {
    textFormat: Text.PlainText
    color: Util.alpha(page.fg, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  SettingsSection {
    title: "Applications"

    SettingsRow {
      label: "Web browser"
      description: "Opens links from every app."
      Dropdown {
        id: browserDropdown
        showLabel: false
        enabled: page.busyKind === ""
        options: Model.options(Model.BROWSERS, page.installed, page.current.browser)
        value: page.current.browser
        onChanged: function(value) { page.setDefault("browser", value) }
      }
    }

    SettingsRow {
      label: "Editor"
      description: "Used by the editor shortcut and Omarchy's “edit” actions."
      Dropdown {
        id: editorDropdown
        showLabel: false
        enabled: page.busyKind === ""
        options: Model.options(Model.EDITORS, page.installed, page.current.editor)
        value: page.current.editor
        onChanged: function(value) { page.setDefault("editor", value) }
      }
    }

    SettingsRow {
      label: "Terminal"
      description: "Used by the terminal shortcut and xdg-terminal-exec."
      Dropdown {
        id: terminalDropdown
        showLabel: false
        enabled: page.busyKind === ""
        options: Model.options(Model.TERMINALS, page.installed, page.current.terminal)
        value: page.current.terminal
        onChanged: function(value) { page.setDefault("terminal", value) }
      }
    }

    SettingsRow {
      label: "Coding agent"
      description: Object.keys(page.installedAgents).length === 0 && page.appsLoaded
        ? "No coding agent installed yet. Pick one in the Omarchy menu to install it."
        : (page.current.agent === "" ? "Not chosen yet. Started by the agent shortcut." : "Started by the agent shortcut.")

      RowLayout {
        spacing: Style.spacing.md
        Dropdown {
          id: agentDropdown
          showLabel: false
          visible: options.length > 0
          enabled: page.busyKind === ""
          options: Model.options(Model.AGENTS, page.installedAgents, page.current.agent)
          value: page.current.agent
          onChanged: function(value) { page.setDefault("agent", value) }
        }
        Button {
          text: agentDropdown.visible ? "More…" : "Install…"
          tooltipText: "Choose from every agent Omarchy supports. Missing ones are installed in a terminal."
          bordered: true
          onClicked: page.sys.detached(["omarchy-menu", "summon", "setup.default.agent"])
        }
      }
    }
  }

  SettingsSection {
    title: "File types"
    description: "Apps that open files from the file manager, browser downloads and xdg-open."

    Repeater {
      model: Model.MIME_GROUPS

      SettingsRow {
        required property var modelData
        readonly property string currentId: page.mimeScan.defaults[modelData.types[0]] || ""
        readonly property var opts: Model.mimeOptions(page.mimeScan.apps[modelData.types[0]], currentId)

        Layout.fillWidth: true
        label: modelData.label
        description: modelData.description

        Item {
          implicitWidth: opts.length > 0 ? mimeDropdown.implicitWidth : noneText.implicitWidth
          implicitHeight: opts.length > 0 ? mimeDropdown.implicitHeight : noneText.implicitHeight

          Dropdown {
            id: mimeDropdown
            visible: opts.length > 0
            showLabel: false
            enabled: page.busyMime === ""
            options: opts
            value: currentId
            onChanged: function(value) { page.setMimeDefault(modelData, value) }
          }
          ValueText {
            id: noneText
            visible: opts.length === 0
            text: "No app installed"
          }
        }

        // The dropdown sets its own value on selection; follow the real
        // default again after every rescan.
        onCurrentIdChanged: mimeDropdown.value = currentId
        Connections {
          target: page
          function onMimeScanChanged() { mimeDropdown.value = currentId }
        }
      }
    }
  }
}
