import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// Wrapping tab strip for the running managed windows. Tabs keep a readable
// width and flow onto the next row when the palette is narrow; the strip is
// capped at three rows and scrolls only if there are even more windows.
Item {
  id: bar
  property var apps: []
  property string activeId: ""
  property bool motionEnabled: true
  signal activated(string appId)

  readonly property int tabHeight: 28
  readonly property int gap: 4
  readonly property int pad: 4
  readonly property int maxRows: 3
  readonly property int maxHeight: pad * 2 + maxRows * tabHeight + (maxRows - 1) * gap

  readonly property int activeIndex: {
    for (var i = 0; i < apps.length; i++)
      if (String(apps[i].id) === activeId) return i
    return -1
  }

  height: Math.min(maxHeight, Math.max(tabHeight + pad * 2, flow.implicitHeight + pad * 2))
  clip: true

  Rectangle {
    anchors.fill: parent
    radius: 8
    color: Qt.rgba(1, 1, 1, 0.03)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.06)
  }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: bar.pad
    contentWidth: width
    contentHeight: flow.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    Flow {
      id: flow
      width: flick.width
      spacing: bar.gap

      Repeater {
        id: repeater
        model: bar.apps

        delegate: Rectangle {
          id: tab
          required property var modelData
          readonly property bool active: String(modelData.id) === bar.activeId
          readonly property string label: String(modelData.name || modelData.id || "")
          property real tiltX: 0
          property real tiltY: 0
          readonly property real maxTilt: bar.motionEnabled ? 3 : 0
          readonly property real parallax: bar.motionEnabled ? 1.1 : 0
          width: Math.min(156, Math.max(96, tabName.implicitWidth + 54))
          height: bar.tabHeight
          radius: 7
          z: tabHover.hovered ? 2 : 0
          scale: tabHover.hovered && bar.motionEnabled ? 1.02 : 1
          color: active ? Qt.rgba(1, 1, 1, 0.13)
            : (tabHover.hovered ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.02))
          border.width: 1
          border.color: active ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.07)
          transform: [
            Rotation {
              origin.x: tab.width / 2
              origin.y: tab.height / 2
              axis { x: 1; y: 0; z: 0 }
              angle: tab.tiltX
            },
            Rotation {
              origin.x: tab.width / 2
              origin.y: tab.height / 2
              axis { x: 0; y: 1; z: 0 }
              angle: tab.tiltY
            }
          ]

          Behavior on tiltX { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
          Behavior on tiltY { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
          Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Image {
              width: 16
              height: 16
              anchors.verticalCenter: parent.verticalCenter
              source: modelData.icon ? Quickshell.iconPath(String(modelData.icon), true) : ""
              fillMode: Image.PreserveAspectFit
              transform: Translate {
                x: tab.tiltY * tab.parallax
                y: -tab.tiltX * tab.parallax
              }
            }
            Text {
              textFormat: Text.PlainText
              id: tabName
              width: Math.min(implicitWidth, 88)
              anchors.verticalCenter: parent.verticalCenter
              text: tab.label
              color: active ? Commons.Color.accent : Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: active
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.key || "")
              color: active ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          HoverHandler { id: tabHover }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: bar.activated(String(modelData.id))
            onPositionChanged: {
              if (!bar.motionEnabled) return
              var nx = (mouseX / Math.max(1, tab.width) - 0.5) * 2
              var ny = (mouseY / Math.max(1, tab.height) - 0.5) * 2
              tab.tiltY = nx * tab.maxTilt
              tab.tiltX = -ny * tab.maxTilt
            }
            onExited: {
              tab.tiltX = 0
              tab.tiltY = 0
            }
          }
        }
      }
    }
  }

  // Keep the active tab visible when the strip has more than three rows and
  // has to scroll internally.
  function revealActive() {
    if (activeIndex < 0 || flick.contentHeight <= flick.height) return
    var item = repeater.itemAt(activeIndex)
    if (!item) return
    var top = item.y
    var bottom = top + item.height
    if (top < flick.contentY) flick.contentY = top
    else if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY))
  }

  onActiveIndexChanged: Qt.callLater(revealActive)
  onAppsChanged: Qt.callLater(revealActive)
  Component.onCompleted: Qt.callLater(revealActive)
}
