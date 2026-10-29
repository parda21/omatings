import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "NetModel.js" as Net

// One Wi-Fi network in the Network page list. Pure view: the page owns all
// state (busy, failure, the open password prompt and its text) so a refresh
// that rebuilds the delegate doesn't lose anything.
//
// `net` is a primitive row from NetModel.buildWifiRows().
CursorSurface {
  id: row

  property var net: ({ ssid: "", signal: -1, band: "", bands: "", device: "", security: "",
    kind: "open", secured: false, connected: false, known: false, uuids: [], inRange: false })
  property string extraInfo: ""       // appended to the subtitle (e.g. the IP)
  property string busyText: ""        // "Connecting…" etc. while this row's action runs
  property string failureText: ""     // last failure for this row
  property bool actionsEnabled: true  // false while any page action runs
  property bool passwordOpen: false
  property string passwordText: ""
  property string identityText: ""

  signal connectClicked()
  signal disconnectClicked()
  signal forgetClicked()
  signal shareClicked()
  signal passwordEdited(string text)
  signal identityEdited(string text)
  signal credentialsSubmitted()
  signal passwordCanceled()

  // Saved enterprise profiles keep their identity; only new ones ask for it.
  readonly property bool isEnterprise: net.kind === "eap" && !net.known
  readonly property string problem: Net.passwordProblem(net.kind, passwordText)
  readonly property bool canSubmit: actionsEnabled && passwordText.length > 0 && problem === ""
    && (!isEnterprise || identityText.length > 0)

  readonly property string subtitle: {
    if (busyText !== "") return busyText
    var parts = []
    if (net.connected) parts.push("Connected")
    else if (!net.inRange) parts.push("Saved, out of range")
    else if (net.known) parts.push("Saved")
    if (net.inRange) {
      if (net.band) parts.push(net.band)
      parts.push(net.signal + "%")
    }
    if (net.security) parts.push(net.security)
    if (extraInfo !== "") parts.push(extraInfo)
    return parts.join(" · ")
  }

  current: net.connected
  hasCursor: rowMouse.containsMouse && net.inRange && !net.connected && actionsEnabled
  implicitHeight: body.implicitHeight + Style.spacing.lg * 2
  Layout.fillWidth: true

  // Clicking the row is the same as its primary button for networks that
  // aren't connected yet; connected rows only act through their buttons.
  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: row.net.inRange && !row.net.connected && row.actionsEnabled && !row.passwordOpen
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: row.connectClicked()
  }

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.spacing.lg
    anchors.leftMargin: Style.spacing.xxl
    anchors.rightMargin: Style.spacing.lg
    spacing: Style.spacing.md

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxl

      Text {
        textFormat: Text.PlainText
        text: Net.wifiIconFor(row.net.signal)
        color: row.net.inRange ? Commons.Color.foreground : Util.alpha(Commons.Color.foreground, 0.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.iconLarge
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.spacing.xxs

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md

          Text {
            textFormat: Text.PlainText
            text: row.net.ssid
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: row.net.connected
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.maximumWidth: implicitWidth
          }

          Text {
            visible: row.net.secured
            textFormat: Text.PlainText
            text: Net.glyph.lock
            color: Util.alpha(Commons.Color.foreground, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Item { Layout.fillWidth: true }
        }

        Text {
          textFormat: Text.PlainText
          text: row.failureText !== "" && row.busyText === "" ? row.failureText : row.subtitle
          color: row.failureText !== "" && row.busyText === "" ? Commons.Color.urgent : Util.alpha(Commons.Color.foreground, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
      }

      Button {
        visible: row.net.connected && row.net.kind !== "eap"
        enabled: row.actionsEnabled
        opacity: enabled ? 1 : 0.5
        iconText: Net.glyph.qr
        tooltipText: "Share via QR code"
        onClicked: row.shareClicked()
      }

      Button {
        visible: row.net.known
        enabled: row.actionsEnabled
        opacity: enabled ? 1 : 0.5
        iconText: Net.glyph.forget
        tooltipText: "Forget network"
        onClicked: row.forgetClicked()
      }

      Button {
        visible: row.net.inRange && !row.passwordOpen
        enabled: row.actionsEnabled
        opacity: enabled ? 1 : 0.5
        bordered: true
        text: row.net.connected ? "Disconnect" : "Connect"
        onClicked: row.net.connected ? row.disconnectClicked() : row.connectClicked()
      }
    }

    // Inline credentials prompt, like the Omarchy network panel.
    ColumnLayout {
      visible: row.passwordOpen
      Layout.fillWidth: true
      spacing: Style.spacing.md

      TextField {
        id: identityField
        visible: row.isEnterprise
        Layout.fillWidth: true
        placeholderText: "Identity (user@domain)"
        enabled: row.actionsEnabled
        text: row.identityText
        onTextChanged: if (text !== row.identityText) row.identityEdited(text)
        onAccepted: passwordField.forceActiveFocus()
        Keys.onEscapePressed: row.passwordCanceled()
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        TextField {
          id: passwordField
          Layout.fillWidth: true
          password: true
          placeholderText: row.net.kind === "wep" ? "WEP key" : "Password"
          enabled: row.actionsEnabled
          text: row.passwordText
          onTextChanged: if (text !== row.passwordText) row.passwordEdited(text)
          onAccepted: if (row.canSubmit) row.credentialsSubmitted()
          Keys.onEscapePressed: row.passwordCanceled()
        }

        Button {
          bordered: true
          text: "Connect"
          enabled: row.canSubmit
          opacity: enabled ? 1 : 0.5
          onClicked: row.credentialsSubmitted()
        }

        Button {
          text: "Cancel"
          enabled: row.actionsEnabled
          opacity: enabled ? 1 : 0.5
          onClicked: row.passwordCanceled()
        }
      }

      Text {
        visible: text !== ""
        textFormat: Text.PlainText
        text: row.passwordText.length > 0 ? row.problem : ""
        color: Util.alpha(Commons.Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        Layout.fillWidth: true
      }
    }
  }

  onPasswordOpenChanged: if (passwordOpen) focusTimer.restart()
  Component.onCompleted: if (passwordOpen) focusTimer.restart()

  Timer {
    id: focusTimer
    interval: 0
    onTriggered: {
      if (row.isEnterprise && row.identityText === "") identityField.forceActiveFocus()
      else passwordField.forceActiveFocus()
    }
  }
}
