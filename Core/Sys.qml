import QtQuick
import Quickshell
import Quickshell.Io

// System access shared by every settings page. The host creates exactly one
// instance and injects it into each page as `sys`.
//
// Everything is asynchronous and callback-based:
//
//   sys.run(["hyprctl", "monitors", "all", "-j"], function(r) {
//     if (r.code !== 0) return app.toast(r.stderr, true)
//     var monitors = JSON.parse(r.stdout)
//   })
//
// A result is always { code, stdout, stderr }.
QtObject {
  id: sys

  readonly property string home: Quickshell.env("HOME")
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string hyprDir: home + "/.config/hypr"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"

  // Files already backed up during this session; one backup per file per
  // session keeps ~/.config from filling up with .bak files while dragging
  // sliders around.
  property var _backedUp: ({})

  property Component _procComponent: Component {
    Process {
      id: proc

      property var callback: null
      property int _pending: 3
      property int _code: -1

      function _settle() {
        _pending -= 1
        if (_pending > 0) return
        var cb = callback
        var result = { code: _code, stdout: String(out.text || ""), stderr: String(err.text || "") }
        proc.destroy()
        if (typeof cb === "function") {
          try { cb(result) } catch (e) { console.warn("omatings: callback threw:", e) }
        }
      }

      stdout: StdioCollector {
        id: out
        waitForEnd: true
        onStreamFinished: proc._settle()
      }
      stderr: StdioCollector {
        id: err
        waitForEnd: true
        onStreamFinished: proc._settle()
      }
      onExited: function(exitCode, exitStatus) {
        proc._code = exitCode
        proc._settle()
      }
    }
  }

  // Run argv (no shell). `callback(result)` is optional.
  function run(argv, callback) {
    var p = _procComponent.createObject(sys, { command: argv, callback: callback || null })
    if (!p) {
      if (callback) callback({ code: -1, stdout: "", stderr: "omatings: could not create process" })
      return
    }
    p.running = true
  }

  // Run a bash script. Extra args are available as "$1", "$2", ... — pass
  // user-provided values that way instead of interpolating them into `script`.
  function sh(script, args, callback) {
    if (typeof args === "function") { callback = args; args = [] }
    run(["bash", "-c", script, "omatings"].concat(args || []), callback)
  }

  // Run `cmd` and JSON.parse stdout. callback(data, result); data is null on failure.
  function json(argv, callback) {
    run(argv, function(r) {
      var data = null
      if (r.code === 0) {
        try { data = JSON.parse(r.stdout) } catch (e) { data = null }
      }
      if (callback) callback(data, r)
    })
  }

  // Fire-and-forget (opens terminals, TUIs, external apps).
  function detached(argv) {
    Quickshell.execDetached(argv)
  }

  // Run an interactive command in a floating terminal, the way the Omarchy
  // menu does (`omarchy launch floating terminal with presentation`).
  function terminal(commandLine) {
    detached(["omarchy-launch-floating-terminal-with-presentation", commandLine])
  }

  // callback(text, exists)
  function readFile(path, callback) {
    sh("[ -f \"$1\" ] || exit 3; cat -- \"$1\"", [path], function(r) {
      if (callback) callback(r.code === 0 ? r.stdout : "", r.code === 0)
    })
  }

  // Atomically write `text` to `path` (creating parent dirs). The first
  // write to a file in a session copies the old version to
  // `<path>.bak.<epoch>`, matching Omarchy's backup naming.
  // callback(ok, result)
  function writeFile(path, text, callback) {
    var backup = _backedUp[path] ? "0" : "1"
    sh("set -e\n"
      + "dir=$(dirname -- \"$1\"); mkdir -p -- \"$dir\"\n"
      + "if [ \"$3\" = 1 ] && [ -f \"$1\" ]; then cp -- \"$1\" \"$1.bak.$(date +%s)\"; fi\n"
      + "tmp=$(mktemp \"$1.omatings.XXXXXX\")\n"
      + "printf '%s' \"$2\" > \"$tmp\"\n"
      + "mv -- \"$tmp\" \"$1\"",
      [path, String(text), backup],
      function(r) {
        if (r.code === 0) {
          var next = ({})
          for (var k in _backedUp) next[k] = true
          next[path] = true
          _backedUp = next
        }
        if (callback) callback(r.code === 0, r)
      })
  }

  // Read a JSON file. callback(data) — data is null when missing/invalid.
  function readJson(path, callback) {
    readFile(path, function(text, exists) {
      var data = null
      if (exists) {
        try { data = JSON.parse(text) } catch (e) { data = null }
      }
      if (callback) callback(data)
    })
  }

  // Read-modify-write ~/.config/omarchy/shell.json. `mutate(config)` edits
  // the object in place. The shell hot-reloads the file on save.
  function updateShellConfig(mutate, callback) {
    readJson(shellConfigPath, function(config) {
      if (!config || typeof config !== "object") config = { version: 1 }
      mutate(config)
      writeFile(shellConfigPath, JSON.stringify(config, null, 2) + "\n", callback)
    })
  }

  // Reload Hyprland and report config errors.
  // callback(errors) — errors is "" when the config is clean.
  function hyprReload(callback) {
    sh("hyprctl reload >/dev/null 2>&1; sleep 0.3; hyprctl configerrors 2>&1", [], function(r) {
      var text = String(r.stdout || "").trim()
      // hyprctl prints an empty line or this sentence when there are no errors
      if (/^no errors/i.test(text)) text = ""
      if (callback) callback(text)
    })
  }

  // Run a Hyprland Lua expression live (not persisted), e.g.
  //   sys.hyprEval('hl.monitor({ output = "DP-1", mode = "preferred", position = "auto", scale = 1 })')
  // Persist with a managed block in the matching ~/.config/hypr/*.lua file.
  function hyprEval(lua, callback) {
    run(["hyprctl", "eval", lua], callback)
  }
}
