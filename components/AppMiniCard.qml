import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// One small card in the expanded "all apps" drawer. It lists the app key and
// the optional direct Hyprland shortcut without using a full palette row.
Rectangle {
  id: card
  property var app: null
  property bool reveal: false
  property bool motionEnabled: true
  property bool selected: false
  property int order: 0
  signal activated()

  property real wobble: 0

  height: 54
  radius: 8
  color: "transparent"
  opacity: reveal ? 1 : 0
  scale: reveal ? (hover.hovered && motionEnabled ? 1.02 : 1) : 0.97
  z: hover.hovered && motionEnabled ? 2 : 0
  transform: [
    Translate {
      y: reveal ? 0 : 6
      Behavior on y {
        NumberAnimation { duration: card.motionEnabled ? 180 : 0; easing.type: Easing.OutCubic }
      }
    },
    Rotation {
      origin.x: card.width / 2
      origin.y: card.height / 2
      axis { x: 0; y: 0; z: 1 }
      angle: card.wobble
    }
  ]

  Behavior on opacity {
    NumberAnimation { duration: card.motionEnabled ? 160 : 0; easing.type: Easing.OutCubic }
  }
  Behavior on scale {
    NumberAnimation { duration: card.motionEnabled ? 120 : 0; easing.type: Easing.OutCubic }
  }

  SequentialAnimation {
    id: wobbleAnim
    NumberAnimation { target: card; property: "wobble"; to: 2.4; duration: 70; easing.type: Easing.OutQuad }
    NumberAnimation { target: card; property: "wobble"; to: -1.6; duration: 80; easing.type: Easing.InOutQuad }
    NumberAnimation { target: card; property: "wobble"; to: 0.9; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: card; property: "wobble"; to: 0; duration: 90; easing.type: Easing.OutCubic }
  }

  Timer {
    id: appearWobble
    interval: 100 + Math.max(0, card.order) * 28
    onTriggered: if (card.reveal && card.motionEnabled) wobbleAnim.restart()
  }

  onRevealChanged: {
    if (reveal) appearWobble.restart()
    else {
      appearWobble.stop()
      wobble = 0
    }
  }
  // Same inset as AppTile: the wobble rotation must not clip the frame.
  Rectangle {
    id: shell
    anchors.fill: parent
    anchors.margins: 4
    radius: card.radius
    color: hover.hovered || card.selected ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.035)
    border.width: card.selected ? 2 : 1
    border.color: hover.hovered || card.selected ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.08)
  }

  Image {
    id: icon
    anchors.left: parent.left
    anchors.leftMargin: 12
    anchors.verticalCenter: parent.verticalCenter
    width: 18
    height: 18
    source: card.app && card.app.icon ? Quickshell.iconPath(String(card.app.icon), true) : ""
    fillMode: Image.PreserveAspectFit
    opacity: 0.95
  }

  Column {
    anchors.left: icon.right
    anchors.leftMargin: 8
    anchors.right: keyCap.left
    anchors.rightMargin: 8
    anchors.verticalCenter: parent.verticalCenter
    spacing: 1

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: card.app ? String(card.app.name || card.app.id) : ""
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: card.app
        ? (card.app.shortcut || Model.stateLabel(card.app.state))
        : ""
      color: card.app && card.app.shortcut
        ? Commons.Color.accent
        : Qt.darker(Commons.Color.popups.text, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  KeyCap {
    id: keyCap
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.top: parent.top
    anchors.topMargin: 8
    label: card.app ? (card.app.key || "—") : "—"
    active: true
  }

  HoverHandler {
    id: hover
    onHoveredChanged: if (hovered && card.motionEnabled) wobbleAnim.restart()
  }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: card.activated()
  }
}
