import QtQuick
import qs.Commons
import qs.Commons as Commons

// Small preview of the geometry: the monitor outline with the app rectangle
// placed where Hyprland will put it. Proportions are approximated from a
// 1440 px-tall reference; it is a diagram, not a pixel-exact render.
Item {
  id: preview
  property real monitorAspect: 16 / 9
  property real widthPercent: 60
  property real heightPercent: 80
  property real topOffset: 12
  property real reservedTop: 26
  property real sideMargin: 0
  property string edge: "top"
  property string placement: "center"
  property real boxWidth: 260
  property real boxHeight: 120

  readonly property real monWidth: Math.min(boxWidth, boxHeight * monitorAspect)
  readonly property real monHeight: monWidth / monitorAspect
  readonly property real appW: Math.max(8, monWidth * (widthPercent || 0) / 100)
  readonly property real appH: Math.max(6, monHeight * (heightPercent || 0) / 100)
  readonly property real monX: (width - monWidth) / 2
  readonly property real monY: (height - monHeight) / 2
  readonly property real appX: placement === "left"
    ? monX + 6
    : (placement === "right" ? monX + monWidth - appW - 6 : monX + (monWidth - appW) / 2)
  readonly property real appY: placement === "top"
    ? monY + (reservedTop + topOffset) * monHeight / 1440
    : (placement === "bottom"
      ? monY + monHeight - appH - 6
      : monY + (monHeight - appH) / 2)

  width: boxWidth
  height: boxHeight

  Rectangle {
    x: preview.monX
    y: preview.monY
    width: preview.monWidth
    height: preview.monHeight
    radius: 6
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.18)
  }

  Rectangle {
    x: preview.appX
    y: preview.appY
    width: preview.appW
    height: preview.appH
    radius: 4
    color: Qt.rgba(1, 1, 1, 0.10)
    border.width: 1
    border.color: Commons.Color.accent

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: Math.round(preview.widthPercent) + "% × " + Math.round(preview.heightPercent) + "%"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
