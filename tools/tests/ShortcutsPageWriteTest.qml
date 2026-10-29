import QtQuick
import "../../pages"
import "../../Core/ManagedBlock.js" as MB
import "../../pages/shortcuts/ShortcutLogic.js" as L

// Loads ShortcutsPage with real (read-only) binding data and drives its
// write path against a temp file with liveApply off (no hyprctl reload,
// nothing in ~/.config is touched). Confirms are auto-accepted.
//   OMATINGS_CHECK_WAIT=6000 tools/check.sh tools/tests/ShortcutsPageWriteTest.qml
Item {
  id: root
  property var sys: null
  property var app: null
  readonly property string tmp: "/tmp/omatings-shortcuts/bindings.lua"
  readonly property string seed: "-- my own\nhl.unbind(\"SUPER + SHIFT + S\")\no.bind(\"SUPER + SHIFT + S\", \"Screenshot\", \"omarchy-capture-screenshot\")\n"

  QtObject {
    id: autoApp
    property var window: null
    function toast(text, isError) { console.log("[toast" + (isError ? ":error" : "") + "] " + text) }
    function confirm(message, confirmText, fn) { console.log("[confirm:" + confirmText + "] " + message); fn() }
    function openPage(id) {}
  }

  ShortcutsPage {
    id: page
    configPath: root.tmp
    liveApply: false
  }

  function activated() {
    sys.sh("rm -rf /tmp/omatings-shortcuts; mkdir -p /tmp/omatings-shortcuts", [], function() {
      sys.writeFile(root.tmp, root.seed, function() {
        page.app = autoApp
        page.sys = root.sys
        page.activated()
        step1.start()
      })
    })
  }

  function findBind(desc) {
    for (var i = 0; i < page.binds.length; i++) if (page.binds[i].description === desc) return page.binds[i]
    return null
  }

  Timer {
    id: step1
    interval: 2500
    onTriggered: {
      console.log("binds:", page.binds.length, "groups:", page.groups.map(function(g) { return g.title + "=" + g.items.length }).join(", "))
      console.log("actions known:", page.binds.filter(function(b) { return b.action }).length, "apps:", page.apps.length)
      var fs = root.findBind("Full screen")
      console.log("full screen:", fs ? fs.combo + " -> " + L.actionLabel(fs.action) : "missing")
      var ss = root.findBind("Screenshot")
      console.log("screenshot user flag:", ss ? ss.user : "missing")
      if (page.binds.length === 0) console.log("OMATINGS_CHECK_FAIL no binds loaded")

      // conflicting add (auto-confirmed)
      page.openEditor(-1)
      page.saveDraft({ keys: "SUPER + F", description: "Files", action: "app", value: "org.gnome.Nautilus.desktop" }, false)
      step2.start()
    }
  }

  Timer {
    id: step2
    interval: 600
    onTriggered: {
      var music = root.findBind("Music") || page.binds.filter(function(b) { return b.description && !b.custom })[0]
      page.disableBind(music)
      step3.start()
    }
  }

  Timer {
    id: step3
    interval: 600
    onTriggered: {
      page.openEditor(-1)
      page.saveDraft({ keys: "SUPER + CTRL + ALT + code:10", description: "SSH box", action: "command", value: "alacritty -e ssh \"box\"" }, false)
      step4.start()
    }
  }

  Timer {
    id: step4
    interval: 600
    onTriggered: sys.readFile(root.tmp, function(text) {
      console.log("---- file ----\n" + text + "--------------")
      if (text.indexOf(root.seed) !== 0) console.log("OMATINGS_CHECK_FAIL user lines changed")
      var entries = L.parseEntries(MB.read(text, "bindings", "--"))
      var kinds = entries.map(function(e) { return e.kind + ":" + e.keys + (e.replaces ? "(replaces " + e.was + ")" : "") })
      console.log("entries:", JSON.stringify(kinds))
      if (entries.length !== 3 || !entries[0].replaces || entries[1].kind !== "disable") console.log("OMATINGS_CHECK_FAIL unexpected entries")
      // edit the first one, then remove the command one
      var idx = 0
      page.editIndex = idx
      page.saveDraft({ keys: "SUPER + F", description: "Files 2", action: "app", value: "org.gnome.Nautilus.desktop" }, false)
      step5.start()
    })
  }

  Timer {
    id: step5
    interval: 600
    onTriggered: {
      page.removeEntry(2)
      step6.start()
    }
  }

  Timer {
    id: step6
    interval: 600
    onTriggered: sys.readFile(root.tmp, function(text) {
      var entries = L.parseEntries(MB.read(text, "bindings", "--"))
      console.log("after edit/remove:", JSON.stringify(entries))
      if (entries.length !== 2 || entries[0].description !== "Files 2" || !entries[0].replaces || entries[0].was !== "Full screen")
        console.log("OMATINGS_CHECK_FAIL edit/remove wrong")
      else console.log("write path ok")
    })
  }
}
