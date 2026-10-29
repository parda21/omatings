import QtQuick
import Quickshell

// Headless load check for omatings QML files (used by tools/check.sh).
// Loads $OMATINGS_CHECK, injects a real Sys plus a fake `app`, waits for
// async startup work, then exits. No window is created for pages; for
// Settings.qml the FloatingWindow is created but never shown.
ShellRoot {
  id: harness

  property var sysObj: null
  property var page: null

  QtObject {
    id: fakeApp
    property var window: null
    function toast(text, isError) { console.log("[toast" + (isError ? ":error" : "") + "] " + text) }
    function confirm(message, confirmText, onConfirm) { console.log("[confirm] " + message) }
    function openPage(id) { console.log("[openPage] " + id) }
  }

  Item { id: holder; width: 800; height: 600 }

  Timer {
    id: quitTimer
    interval: Number(Quickshell.env("OMATINGS_CHECK_WAIT") || 2500)
    onTriggered: {
      console.log("OMATINGS_CHECK_DONE")
      Qt.exit(0)
    }
  }

  Component.onCompleted: {
    var root = Quickshell.env("OMATINGS_ROOT")
    var target = Quickshell.env("OMATINGS_CHECK")
    var sysComponent = Qt.createComponent("file://" + root + "/Core/Sys.qml")
    if (sysComponent.status !== Component.Ready) {
      console.log("OMATINGS_CHECK_FAIL Sys.qml: " + sysComponent.errorString())
      Qt.exit(1)
      return
    }
    sysObj = sysComponent.createObject(harness)

    var c = Qt.createComponent("file://" + target)
    if (c.status === Component.Error) {
      console.log("OMATINGS_CHECK_FAIL " + c.errorString())
      Qt.exit(1)
      return
    }
    var obj = c.createObject(holder, { width: 800 })
    if (!obj) {
      console.log("OMATINGS_CHECK_FAIL could not instantiate " + target)
      Qt.exit(1)
      return
    }
    page = obj
    if ("sys" in obj) obj.sys = sysObj
    if ("app" in obj) obj.app = fakeApp
    if (typeof obj.activated === "function") obj.activated()
    console.log("OMATINGS_CHECK_LOADED implicitHeight=" + obj.implicitHeight)
    quitTimer.start()
  }
}
