import QtQuick
import qs.Commons
import qs.Commons as Commons

// One adjustable settings row. The label and the stepper form one bounded,
// centred group on a fixed internal grid: label column, minus, value, plus.
// Mouse users can click either arrow; Enter advances the value.
Item {
  id: row
  property string label: ""
  property string value: ""
  property bool selected: false
  property bool disabled: false
  property int labelWidth: Math.min(220, Math.max(90, (parent ? parent.width : 300) - 192))
  signal adjust(int delta)
  signal activate()

  width: parent ? parent.width : 300
  height: 38

  Rectangle {
    anchors.fill: parent
    radius: 8
    color: row.selected ? Qt.rgba(1, 1, 1, 0.12) : (hover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
  }

  Row {
    anchors.centerIn: parent
    spacing: 12

    Text {
      width: row.labelWidth
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: row.label
      color: row.disabled ? Qt.darker(Commons.Color.popups.text, 1.8) : Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Rectangle {
      width: 22
      height: 22
      anchors.verticalCenter: parent.verticalCenter
      radius: 6
      color: leftHover.hovered ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.10)

      Text {
        anchors.centerIn: parent
        text: "−"
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: 14
      }
      HoverHandler { id: leftHover }
      MouseArea {
        anchors.fill: parent
        enabled: !row.disabled
        cursorShape: Qt.PointingHandCursor
        onClicked: row.adjust(-1)
      }
    }

    Text {
      width: 82
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignHCenter
      text: row.value
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Rectangle {
      width: 22
      height: 22
      anchors.verticalCenter: parent.verticalCenter
      radius: 6
      color: rightHover.hovered ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.10)

      Text {
        anchors.centerIn: parent
        text: "+"
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: 14
      }
      HoverHandler { id: rightHover }
      MouseArea {
        anchors.fill: parent
        enabled: !row.disabled
        cursorShape: Qt.PointingHandCursor
        onClicked: row.adjust(1)
      }
    }
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    anchors.rightMargin: 170
    enabled: !row.disabled
    onClicked: row.activate()
  }
}
