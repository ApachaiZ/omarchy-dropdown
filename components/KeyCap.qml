import QtQuick
import qs.Commons
import qs.Commons as Commons

// Small keycap used in menus and hints.
Rectangle {
  id: cap
  property string label: ""
  property bool active: false
  implicitWidth: Math.max(20, text.implicitWidth + 12)
  implicitHeight: 20
  radius: 5
  color: cap.active ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.05)
  border.width: 1
  border.color: cap.active ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.10)

  Text {
    id: text
    anchors.centerIn: parent
    text: cap.label
    color: cap.active ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.15)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: cap.active
  }
}
