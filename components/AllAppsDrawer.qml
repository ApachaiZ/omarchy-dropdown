import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import "../js/Keymap.js" as Keymap

// The expandable all-apps drawer. The overlay owns its open state and keyboard
// selection; this component renders the toggle row, the responsive grid and
// the reveal/stagger animation. Keeping it separate from Overlay.qml makes the
// grid width, column count and selection logic testable in one place.
Item {
  id: drawer

  property var apps: []
  property bool open: false
  property int selected: 0
  property bool motionEnabled: true
  property int maxHeight: 240
  readonly property int count: apps ? apps.length : 0
  readonly property int columns: Keymap.columnsForWidth(width, 170)
  readonly property int cardHeight: 54
  readonly property int spacing: 6

  signal toggled()
  signal activated(var app)

  width: parent ? parent.width : 0
  height: toggleRow.height + allAppsScroll.height

  function ensureVisible(index) {
    if (!open || count === 0) return
    var row = Math.floor(Math.max(0, index) / columns)
    var rowY = 8 + row * (cardHeight + spacing)
    if (rowY < allAppsScroll.contentY) allAppsScroll.contentY = rowY
    else if (rowY + cardHeight > allAppsScroll.contentY + allAppsScroll.height)
      allAppsScroll.contentY = rowY + cardHeight - allAppsScroll.height
  }

  function cardWidth() {
    var available = Math.max(0, allAppsGrid.width - (columns - 1) * spacing)
    return Math.max(80, available / columns)
  }

  onSelectedChanged: ensureVisible(selected)
  onOpenChanged: if (open) Qt.callLater(function() { drawer.ensureVisible(drawer.selected) })

  Item {
    id: toggleRow
    width: parent.width
    height: 30

    Rectangle {
      anchors.centerIn: parent
      width: toggleContent.width + 24
      height: 26
      radius: 8
      color: toggleHover.hovered ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03)
      border.width: 1
      border.color: drawer.open ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.08)
    }

    Row {
      id: toggleContent
      anchors.centerIn: parent
      spacing: 8

      KeyCap {
        anchors.verticalCenter: parent.verticalCenter
        label: "Space"
        active: drawer.open
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: "All apps · " + drawer.count
        color: drawer.open ? Commons.Color.accent : Commons.Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: "▾"
        color: drawer.open ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.3)
        font.pixelSize: Style.font.body
        rotation: drawer.open ? 180 : 0
        Behavior on rotation {
          NumberAnimation { duration: drawer.motionEnabled ? 140 : 0; easing.type: Easing.OutCubic }
        }
      }
    }

    HoverHandler { id: toggleHover }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: drawer.toggled()
    }
  }

  Flickable {
    id: allAppsScroll
    anchors.top: toggleRow.bottom
    readonly property real targetHeight: drawer.open
      ? Math.min(drawer.maxHeight, allAppsGrid.height + 16) : 0
    visible: height > 0.5
    width: parent.width
    height: targetHeight
    opacity: drawer.open ? 1 : 0
    contentWidth: width
    contentHeight: allAppsGrid.height + 16
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: 4 }
    transform: Translate {
      y: drawer.open ? 0 : -6
      Behavior on y {
        NumberAnimation { duration: drawer.motionEnabled ? 200 : 0; easing.type: Easing.OutCubic }
      }
    }
    Behavior on height {
      NumberAnimation { duration: drawer.motionEnabled ? 220 : 0; easing.type: Easing.OutCubic }
    }
    Behavior on opacity {
      NumberAnimation { duration: drawer.motionEnabled ? 160 : 0; easing.type: Easing.OutCubic }
    }

    Grid {
      id: allAppsGrid
      x: 8
      y: 8
      width: allAppsScroll.width - 18
      columns: drawer.columns
      spacing: drawer.spacing
      height: childrenRect.height

      Repeater {
        model: drawer.apps
        delegate: AppMiniCard {
          required property var modelData
          required property int index
          width: drawer.cardWidth()
          app: modelData
          reveal: drawer.open
          selected: index === drawer.selected
          motionEnabled: drawer.motionEnabled
          order: index
          onActivated: drawer.activated(modelData)
        }
      }
    }
  }
}
