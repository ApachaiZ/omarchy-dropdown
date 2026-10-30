import QtQuick
import qs.Commons
import qs.Commons as Commons

// Centred section title used inside the settings panels. The divider sits
// below it so the next group reads as a separate region.
Item {
  property string title: ""
  width: parent ? parent.width : 200
  height: 28

  Text {
    anchors.centerIn: parent
    text: parent.title
    color: Qt.darker(Commons.Color.popups.text, 1.25)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Rectangle {
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    width: parent.width * 0.72
    height: 1
    color: Qt.rgba(1, 1, 1, 0.06)
  }
}
