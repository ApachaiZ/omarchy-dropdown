import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// One application row: icon, name, secondary line, keycap, state dot and an
// optional checkbox. Used by every list in the palette.
Item {
  id: row
  property var app: null
  readonly property string secondaryLabel: {
    if (!row.app) return ""
    var parts = []
    if (row.app.shortcut) parts.push(String(row.app.shortcut))
    var rest = row.app.conflict || row.app.note || row.app.detail || ""
    if (rest) parts.push(String(rest))
    return parts.join(" · ")
  }
  property bool selected: false
  property bool showCheckbox: false
  property bool interactive: true
  signal activated()

  width: parent ? parent.width : 200
  height: 42

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 10 ? 8 : Style.cornerRadius
    color: row.selected ? Qt.rgba(1, 1, 1, 0.12) : (hover.hovered ? Qt.rgba(1, 1, 1, 0.05) : "transparent")
    border.width: row.selected ? 1 : 0
    border.color: Qt.rgba(1, 1, 1, 0.08)
  }

  Rectangle {
    id: check
    visible: row.showCheckbox
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    width: 16
    height: 16
    radius: 4
    color: row.app && row.app.enabled ? Commons.Color.accent : "transparent"
    border.width: 1
    border.color: row.app && row.app.enabled ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.28)

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: row.app !== null && row.app.enabled === true
      text: "✓"
      color: Commons.Color.background
      font.family: Style.font.family
      font.pixelSize: 10
      font.bold: true
    }
  }

  Image {
    id: icon
    anchors.left: parent.left
    anchors.leftMargin: row.showCheckbox ? 36 : 10
    anchors.verticalCenter: parent.verticalCenter
    width: 22
    height: 22
    source: row.app && row.app.icon ? Quickshell.iconPath(String(row.app.icon), true) : ""
    fillMode: Image.PreserveAspectFit
    smooth: true
  }

  Text {
    textFormat: Text.PlainText
    visible: !row.app || !row.app.icon
    anchors.centerIn: icon
    text: "•"
    color: Commons.Color.popups.text
    font.family: Style.font.family
    font.pixelSize: 16
  }

  Column {
    anchors.left: icon.right
    anchors.leftMargin: 10
    anchors.right: row.app && row.app.key ? keyCap.left : stateDot.left
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    spacing: 1

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: row.app ? String(row.app.name || row.app.id) : ""
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: row.secondaryLabel !== ""
      text: row.secondaryLabel
      color: row.app && (row.app.conflict || row.app.state === "error")
        ? Commons.Color.urgent : Qt.darker(Commons.Color.popups.text, 1.45)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  KeyCap {
    id: keyCap
    visible: row.app !== null && !!row.app.key
    anchors.right: stateDot.left
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    label: row.app ? String(row.app.key) : ""
    active: row.selected
  }

  Rectangle {
    id: stateDot
    anchors.right: parent.right
    anchors.rightMargin: 12
    anchors.verticalCenter: parent.verticalCenter
    width: 7
    height: 7
    radius: 4
    color: {
      if (!row.app) return "transparent"
      if (row.app.state === "visible") return Commons.Color.accent
      if (row.app.state === "hidden") return Qt.darker(Commons.Color.accent, 1.8)
      if (row.app.state === "launching") return Commons.Color.popups.text
      if (row.app.state === "error") return Commons.Color.urgent
      return "transparent"
    }
    border.width: row.app !== null && row.app.state === "stopped" ? 1 : 0
    border.color: Qt.rgba(1, 1, 1, 0.18)
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    enabled: row.interactive
    cursorShape: Qt.PointingHandCursor
    onClicked: row.activated()
  }
}
