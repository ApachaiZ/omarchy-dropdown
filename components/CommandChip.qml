import QtQuick
import qs.Commons
import qs.Commons as Commons

// Mouse-reachable equivalent of a palette command.
Item {
  id: chip
  property string key: ""
  property string label: ""
  signal triggered()
  implicitWidth: row.implicitWidth + 14
  implicitHeight: 24

  Rectangle {
    anchors.fill: parent
    radius: 7
    color: hover.hovered ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.04)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.08)
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 6

    KeyCap { label: chip.key }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: chip.label
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.triggered()
  }
}
