import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// One of the five most-used apps. Equal-width tile; the name is always
// elided inside the tile, so adding apps can never widen or break the frame.
Rectangle {
  id: tile
  property var app: null
  property int rank: 0
  property bool motionEnabled: true
  signal activated()

  // A few degrees of tilt and a counter-moving icon give the card volume
  // without turning the palette into a 3D scene.
  property real tiltX: 0
  property real tiltY: 0
  readonly property real maxTilt: motionEnabled ? 4 : 0
  readonly property real parallax: motionEnabled ? 1.6 : 0

  height: 92
  radius: 10
  color: "transparent"
  z: hover.hovered ? 2 : 0
  scale: hover.hovered && motionEnabled ? 1.015 : 1

  transform: [
    Rotation {
      origin.x: tile.width / 2
      origin.y: tile.height / 2
      axis { x: 1; y: 0; z: 0 }
      angle: tile.tiltX
    },
    Rotation {
      origin.x: tile.width / 2
      origin.y: tile.height / 2
      axis { x: 0; y: 1; z: 0 }
      angle: tile.tiltY
    }
  ]

  Behavior on tiltX { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
  Behavior on tiltY { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
  Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

  // Inset frame: a 3D tilt can clip a border drawn on the transformed edge.
  // Keeping the border two pixels inside leaves room for rotation and scale.
  Rectangle {
    id: shell
    anchors.fill: parent
    anchors.margins: 4
    radius: tile.radius
    color: hover.hovered ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.035)
    border.width: 1
    border.color: hover.hovered ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.08)
  }

  Text {
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.top: parent.top
    anchors.topMargin: 7
    text: "#" + tile.rank
    color: Qt.darker(Commons.Color.popups.text, 1.55)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  KeyCap {
    anchors.right: parent.right
    anchors.rightMargin: 9
    anchors.top: parent.top
    anchors.topMargin: 6
    label: tile.app ? (tile.app.key || "—") : "—"
    active: true
  }

  Image {
    anchors.centerIn: parent
    width: 30
    height: 30
    source: tile.app && tile.app.icon ? Quickshell.iconPath(String(tile.app.icon), true) : ""
    fillMode: Image.PreserveAspectFit
    scale: hover.hovered && tile.motionEnabled ? 1.06 : 1
    transform: Translate {
      x: tile.tiltY * tile.parallax
      y: -tile.tiltX * tile.parallax
    }
    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
  }

  Text {
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: 8
    anchors.rightMargin: 8
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 9
    horizontalAlignment: Text.AlignHCenter
    text: tile.app ? String(tile.app.name || tile.app.id) : ""
    color: Commons.Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: tile.activated()
    onPositionChanged: {
      if (!tile.motionEnabled) return
      var nx = (mouseX / Math.max(1, tile.width) - 0.5) * 2
      var ny = (mouseY / Math.max(1, tile.height) - 0.5) * 2
      tile.tiltY = nx * tile.maxTilt
      tile.tiltX = -ny * tile.maxTilt
    }
    onExited: {
      tile.tiltX = 0
      tile.tiltY = 0
    }
  }
}
