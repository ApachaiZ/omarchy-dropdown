import QtQuick
import qs.Commons
import qs.Commons as Commons

// Contextual shortcuts pinned to the bottom of the dropdown. One horizontal
// band, no wrapping, so it always reads as a footer rather than a second menu.
Item {
  id: band
  property var items: []
  width: parent ? parent.width : 300
  height: 34

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: Qt.rgba(1, 1, 1, 0.07)
  }

  Row {
    anchors.centerIn: parent
    spacing: 12

    Repeater {
      model: band.items
      delegate: Row {
        required property var modelData
        spacing: 5
        height: 22

        KeyCap { anchors.verticalCenter: parent.verticalCenter; label: modelData.key; active: false }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          color: Qt.darker(Commons.Color.popups.text, 1.35)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
