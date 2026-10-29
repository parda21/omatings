import QtQuick
import "../../Core"
import "../../Core/ManagedBlock.js" as MB

// Exercise Sys + ManagedBlock: tools/check.sh tools/tests/SysTest.qml
Item {
  property var sys: null
  property var app: null

  function activated() {
    sys.run(["echo", "hello"], function(r) { console.log("run:", r.code, JSON.stringify(r.stdout)) })
    sys.sh("echo \"$1-$2\"; exit 4", ["a b", "c"], function(r) { console.log("sh:", r.code, JSON.stringify(r.stdout)) })
    sys.json(["hyprctl", "monitors", "all", "-j"], function(d) { console.log("json monitors:", d ? d.length : "null") })
    var path = "/tmp/omatings-test/x.lua"
    var t1 = MB.replace("-- user stuff\nhl.monitor({ output = \"eDP-1\" })\n", "monitors", "hl.monitor(" + MB.luaValue({ output: "DP-1", scale: 1.5, mode: "preferred" }) + ")", "--")
    var t2 = MB.replace(t1, "monitors", "hl.monitor({ output = \"DP-2\" })", "--")
    console.log("block read:", JSON.stringify(MB.read(t2, "monitors", "--")))
    sys.writeFile(path, t2, function(ok) {
      sys.readFile(path, function(text, exists) { console.log("roundtrip:", exists, text === t2) ; console.log(text) })
    })
    console.log("removed:", JSON.stringify(MB.remove(t2, "monitors", "--")))
  }
}
