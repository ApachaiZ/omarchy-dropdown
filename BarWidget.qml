import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Discreet bar entry point. Left click opens the palette, right click opens
// Manage, middle click hides the current dropdown. No timer runs here: the
// glyph only reflects the service's current application.
BarWidget {
  id: root
  moduleName: "apach.dropdown"

  property var service: null

  readonly property bool hasCurrent: service !== null && service.currentAppId !== ""
  readonly property bool hasHidden: service !== null && service.lastAppId !== "" && service.currentAppId === ""
  readonly property var hostWindow: QsWindow.window
  readonly property string hostScreenName: hostWindow && hostWindow.screen
    ? String(hostWindow.screen.name || "") : ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function resolveService() {
    if (root.service) return
    var api = root.bar ? root.bar.shell : null
    if (api && typeof api.serviceFor === "function") {
      var target = api.serviceFor("apach.dropdown")
      if (target) root.service = target
    }
  }

  Component.onCompleted: resolveService()
  onBarChanged: resolveService()

  // The shell creates services before the bar in practice; this short probe
  // covers a bar that was rebuilt during a plugin rescan.
  Timer {
    interval: 500
    running: root.service === null
    onTriggered: root.resolveService()
  }

  function openPalette(view) {
    if (!root.service) return
    // The bar is per screen. Invoking its widget must open on that screen even
    // when another output holds keyboard focus.
    root.service.openPalette(view || "palette", root.hostScreenName)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf2d0"
    active: root.hasCurrent
    tooltipText: root.service ? root.service.barTooltip : "Dropdown"
    onPressed: function(b) {
      if (!root.service) return
      if (b === Qt.LeftButton) root.service.toggleFromBar("palette", root.hostScreenName)
      else if (b === Qt.RightButton) root.openPalette("manage")
      else if (b === Qt.MiddleButton) {
        var result = root.service.hideVisibleCurrent()
        if (!result.ok) root.service.notify(result.message)
      }
    }
  }

}
