import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Clickable image tile used by the theme gallery and the background picker:
// a 16:9 preview (loaded asynchronously and downscaled), an optional label
// under it, a check badge when `current`, and a dimmed spinner when `busy`.
//
//   ImageCard { source: "file:///…/preview.png"; label: "Tokyo Night"; current: true; onClicked: … }
Item {
  id: card

  property url source: ""
  property string label: ""
  property string tooltip: ""
  property bool current: false
  property bool busy: false
  // Width the image is decoded at; keeps 4K backgrounds cheap.
  property int decodeWidth: 480

  readonly property color foreground: Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property bool hot: mouse.containsMouse && card.enabled

  signal clicked()

  implicitWidth: Style.space(200)
  implicitHeight: surface.height

  BorderSurface {
    id: surface
    width: parent.width
    height: frame.height + (labelText.visible ? labelText.height + Style.spacing.md : 0) + Style.spacing.md * 2
    radius: Style.cornerRadius
    color: card.current ? Style.selectedFill : (card.hot ? Style.hoverFill : Style.normalFill)
    borderSpec: card.current ? Border.flat(card.accent, Math.max(2, Style.normalBorderWidth * 2))
              : Border.controlSpec(card.hot ? "hover-cursor" : "normal", card.foreground, card.accent)

    Rectangle {
      id: frame
      x: Style.spacing.md
      y: Style.spacing.md
      width: parent.width - Style.spacing.md * 2
      height: Math.round(width * 9 / 16)
      color: Util.alpha(card.foreground, 0.06)
      radius: Math.max(0, Style.cornerRadius - Style.spacing.md / 2)
      clip: true

      Image {
        id: image
        anchors.fill: parent
        source: card.source
        asynchronous: true
        cache: true
        smooth: true
        mipmap: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: card.decodeWidth
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
      }

      Text {
        anchors.centerIn: parent
        visible: image.status !== Image.Ready
        text: image.status === Image.Loading ? "" : String.fromCodePoint(0xF02E9)
        color: Util.alpha(card.foreground, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.font.iconLarge * 1.4
      }

      Rectangle {
        anchors.fill: parent
        visible: card.busy
        color: Util.alpha(Commons.Color.background, 0.55)

        Text {
          id: spinner
          anchors.centerIn: parent
          text: String.fromCodePoint(0xF0450)
          color: card.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.iconLarge * 1.4
          RotationAnimator on rotation {
            running: card.busy
            from: 0; to: 360
            duration: 900
            loops: Animation.Infinite
          }
        }
      }

      Rectangle {
        visible: card.current
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.spacing.md
        width: badge.implicitWidth + Style.spacing.md * 2
        height: width
        radius: Style.cornerRadius > 0 ? width / 2 : 0
        color: card.accent

        Text {
          id: badge
          anchors.centerIn: parent
          text: String.fromCodePoint(0xF012C)
          color: Commons.Color.background
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
    }

    Text {
      id: labelText
      visible: card.label !== ""
      anchors.top: frame.bottom
      anchors.topMargin: Style.spacing.md
      anchors.left: frame.left
      anchors.right: frame.right
      text: card.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      color: card.current ? card.accent : card.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: card.current
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: card.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (card.enabled && !card.busy) card.clicked()
  }

  PanelToolTip {
    visible: card.tooltip !== "" && mouse.containsMouse
    text: card.tooltip
  }
}
