import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Core"
import "Core/Pages.js" as Pages

// Omarchy Settings — a GNOME-style settings window hosted inside
// omarchy-shell as a `panel` plugin.
//
//   omarchy-shell shell toggle omatings '{}'
//   omarchy-shell shell summon omatings '{"page":"displays"}'
//
// The host owns the window, sidebar, toasts and confirm dialog. Each page in
// Core/Pages.js is a self-contained QML file under pages/ that receives:
//   sys — Core/Sys.qml (run commands, read/write files, reload Hyprland)
//   app — this object (toast, confirm, openPage, window)
Item {
  id: root

  readonly property string pluginId: (manifest && manifest.id) || "omatings"

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null

  // ---- state --------------------------------------------------------------
  property bool opened: false
  property bool closingFromHost: false
  property string currentPageId: Pages.pages[0].id
  property string searchText: ""
  // Pages stay loaded once visited so their state survives page switches.
  property var visited: ({})

  readonly property var currentPage: Pages.find(currentPageId)
  readonly property var filteredPages: Pages.pages.filter(function(p) { return Pages.matches(p, root.searchText) })
  readonly property alias window: window

  readonly property color foreground: Commons.Color.foreground
  readonly property color background: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent

  Sys { id: sys }

  // ---- plugin lifecycle ---------------------------------------------------
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || ({}) } catch (e) { payload = ({}) }
    if (payload.page && Pages.find(payload.page)) openPage(payload.page)
    else openPage(currentPageId)

    closingFromHost = false
    opened = true
    if (window.visible) {
      Qt.callLater(function() { contentFocus.forceActiveFocus() })
      return
    }
    // Hyprland would tile the window like any app. Register a float/center
    // rule right before mapping it; rules added via eval don't survive a
    // config reload, so this runs on every open.
    sys.hyprEval(windowRule, function() {
      if (!root.opened) return
      window.visible = true
      Qt.callLater(function() { contentFocus.forceActiveFocus() })
    })
  }

  readonly property string windowRule: 'o.window({ class = "org.quickshell", title = "^Omarchy Settings$" }, '
    + '{ float = true, center = true, size = { 1100, 760 }, tag = "-default-opacity", opacity = "1.0 1.0" })'

  // Host-initiated close (`shell hide`).
  function close() {
    closingFromHost = true
    opened = false
    window.visible = false
    closingFromHost = false
  }

  // User-initiated close (Esc, window close button).
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // ---- API for pages (`app`) ----------------------------------------------
  function openPage(id) {
    if (!Pages.find(id)) return
    if (!visited[id]) {
      var next = ({})
      for (var k in visited) next[k] = true
      next[id] = true
      visited = next
    }
    currentPageId = id
  }

  function toast(text, isError) {
    toastText.text = String(text || "").trim()
    toastBox.isError = isError === true
    toastBox.shown = toastText.text !== ""
    toastTimer.interval = isError ? 7000 : 3500
    toastTimer.restart()
  }

  // confirm("Remove this binding?", "Remove", function() { ... })
  property var _confirmAction: null
  function confirm(message, confirmText, onConfirm) {
    _confirmAction = onConfirm || null
    confirmDialog.message = message
    confirmDialog.confirmText = confirmText || "Confirm"
    confirmDialog.selectedIndex = 1
    confirmDialog.opened = true
    contentFocus.forceActiveFocus()
  }

  // ---- window -------------------------------------------------------------
  FloatingWindow {
    id: window
    title: "Omarchy Settings"
    visible: false
    color: root.background
    implicitWidth: 1040
    implicitHeight: 720
    minimumSize: Qt.size(760, 520)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.opened) {
        root.opened = false
        if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
      }
    }

    FocusScope {
      id: contentFocus
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (confirmDialog.opened) {
          if (confirmDialog.handleKey(event)) event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (searchField.activeFocus && searchField.text !== "") { searchField.text = ""; event.accepted = true; return }
          root.requestClose()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
          searchField.forceActiveFocus()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_PageDown || event.key === Qt.Key_Tab)) {
          root.cyclePage(1); event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_PageUp || event.key === Qt.Key_Backtab)) {
          root.cyclePage(-1); event.accepted = true
        }
      }

      RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---- sidebar ------------------------------------------------------
        Rectangle {
          Layout.fillHeight: true
          Layout.preferredWidth: Style.space(230)
          color: Util.alpha(root.foreground, 0.03)

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.spacing.panelPadding
            spacing: Style.spacing.lg

            Text {
              text: "Settings"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title * 1.4
              font.bold: true
              Layout.bottomMargin: Style.spacing.sm
            }

            TextField {
              id: searchField
              Layout.fillWidth: true
              placeholderText: "Search  (Ctrl+F)"
              onTextChanged: root.searchText = text
              onAccepted: if (root.filteredPages.length > 0) root.openPage(root.filteredPages[0].id)
            }

            ListView {
              id: pageList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: Style.spacing.xxs
              model: root.filteredPages
              boundsBehavior: Flickable.StopAtBounds

              delegate: Button {
                required property var modelData
                width: ListView.view.width
                leftAlign: true
                text: modelData.title
                iconText: Pages.glyph(modelData)
                selected: modelData.id === root.currentPageId
                verticalPadding: Style.spacing.md
                onClicked: root.openPage(modelData.id)
              }
            }
          }
        }

        Rectangle {
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          color: Util.alpha(root.foreground, 0.12)
        }

        // ---- content ------------------------------------------------------
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 0

          RowLayout {
            Layout.fillWidth: true
            Layout.margins: Style.spacing.panelPadding
            Layout.leftMargin: Style.spacing.panelPadding * 1.5
            Layout.bottomMargin: Style.spacing.md
            spacing: Style.spacing.lg

            Text {
              text: Pages.glyph(root.currentPage)
              color: root.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge * 1.2
            }
            Text {
              text: root.currentPage ? root.currentPage.title : ""
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title * 1.4
              font.bold: true
              Layout.fillWidth: true
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Repeater {
              model: Pages.pages

              // Each page scrolls independently. Pages report their height
              // through implicitHeight and get the viewport width.
              Flickable {
                id: pageScroll
                required property var modelData
                readonly property bool current: modelData.id === root.currentPageId

                anchors.fill: parent
                visible: current
                clip: true
                contentWidth: width
                contentHeight: pageLoader.item ? pageLoader.item.implicitHeight + Style.spacing.panelPadding * 2 : 0
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                onCurrentChanged: if (current && pageLoader.item && typeof pageLoader.item.activated === "function") pageLoader.item.activated()

                Loader {
                  id: pageLoader
                  x: Style.spacing.panelPadding * 1.5
                  y: Style.spacing.md
                  width: pageScroll.width - Style.spacing.panelPadding * 3
                  active: root.visited[pageScroll.modelData.id] === true
                  asynchronous: true
                  source: Qt.resolvedUrl(pageScroll.modelData.source)

                  onLoaded: {
                    if ("sys" in item) item.sys = sys
                    if ("app" in item) item.app = root
                    if (typeof item.activated === "function") item.activated()
                  }
                  onStatusChanged: {
                    if (status === Loader.Error)
                      console.warn("omatings: page " + pageScroll.modelData.id + " failed to load")
                  }
                }

                Text {
                  visible: pageLoader.status === Loader.Error
                  anchors.centerIn: parent
                  text: "This page failed to load. Check the shell log."
                  color: root.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
              }
            }
          }
        }
      }

      // ---- toast ----------------------------------------------------------
      BorderSurface {
        id: toastBox
        property bool shown: false
        property bool isError: false

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: shown ? Style.spacing.panelPadding : -height
        width: Math.min(parent.width - Style.space(80), toastText.implicitWidth + Style.spacing.xxl * 2)
        height: toastText.implicitHeight + Style.spacing.lg * 2
        visible: anchors.bottomMargin > -height
        color: root.background
        radius: Style.cornerRadius
        borderSpec: Border.flat(isError ? root.urgent : root.accent, Math.max(1, Style.normalBorderWidth))
        Behavior on anchors.bottomMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Text {
          id: toastText
          anchors.centerIn: parent
          width: Math.min(implicitWidth, toastBox.parent.width - Style.space(80) - Style.spacing.xxl * 2)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea { anchors.fill: parent; onClicked: toastBox.shown = false }
      }

      Timer {
        id: toastTimer
        onTriggered: toastBox.shown = false
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        onCanceled: { opened = false; root._confirmAction = null }
        onConfirmed: {
          opened = false
          var action = root._confirmAction
          root._confirmAction = null
          if (typeof action === "function") action()
        }
      }
    }
  }

  function cyclePage(delta) {
    var list = Pages.pages
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === currentPageId) {
        openPage(list[(i + delta + list.length) % list.length].id)
        return
      }
    }
  }
}
