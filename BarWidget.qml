import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry: shows whether the group is live and how many speakers are in it.
// Left click opens the panel, right click toggles the group, so the common
// action never costs a trip through the UI.
BarWidget {
  id: root

  moduleName: "jetti.speaker"

  property var service: bar && bar.shell
    ? bar.shell.serviceFor("jetti.speaker") : null

  // The service is the shared source of truth, but a bar widget must still
  // render before services finish mounting, so every read is defensive.
  readonly property bool running: service ? service.running : false
  readonly property int speakerCount: service ? service.speakerCount : 0
  readonly property var profile: service ? service.profile : null

  readonly property string tooltip: {
    if (!service) return "Jetti Speaker"
    if (!running) return "Jetti Speaker is off  ·  click to open, right-click to start"
    var spread = Model.delaySpread(profile)
    var base = Model.summary(service.status, profile)
    return spread > 0 ? base + "  ·  aligned across " + spread + " ms" : base
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font: a speaker with waves when live, a plain one when idle.
    text: root.running ? "" : ""
    active: root.running
    tooltipText: root.tooltip

    onPressed: function (mouseButton) {
      if (!root.bar) return
      if (mouseButton === Qt.RightButton) {
        if (root.service) root.service.toggle()
        return
      }
      root.bar.run("omarchy-shell shell toggle jetti.speaker")
    }
  }

  // A count badge only earns its space once more than one speaker is playing,
  // which is exactly when the user cares that the group is a group.
  Rectangle {
    visible: root.running && root.speakerCount > 1
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -2
    anchors.topMargin: 1
    width: countText.implicitWidth + 6
    height: countText.implicitHeight + 2
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Color.bar.active

    Text {
      id: countText
      anchors.centerIn: parent
      text: root.speakerCount
      color: Color.bar.background
      font.family: Style.font.family
      font.pixelSize: Math.max(8, Style.font.caption - 2)
      font.bold: true
    }
  }
}
