import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Jetti Speaker panel.
//
// Layout follows the order the work actually happens in: pick the speakers,
// measure them, let the agent tune them, turn the group on. Anything that
// changes hardware state outside this plugin -- unlocking a card profile --
// says what it costs before it does it.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string jspeaker: pluginDir + "bin/jspeaker"

  // Not readonly: the shell assigns this during Loader.onLoaded, and a
  // readonly property makes that assignment throw -- which aborts the rest of
  // onLoaded, so the panel never registers and never opens.
  property var service: shell ? shell.serviceFor("jetti.speaker") : null
  readonly property var profile: service ? service.profile : null
  readonly property var devices: service ? service.devices : null
  readonly property bool running: service ? service.running : false
  readonly property bool busy: (service ? service.busy : false) || calibrateProcess.running || tuneProcess.running

  readonly property var liveSpeakers: {
    if (!profile || !profile.speakers) return []
    return profile.speakers.filter(function (s) { return s.sink })
  }
  readonly property var lockedSpeakers: {
    if (!devices || !devices.speakers) return []
    return devices.speakers.filter(function (s) { return s.state === "locked" })
  }
  readonly property var warnings: devices && devices.warnings ? devices.warnings : []

  property string activity: ""
  property string transcript: ""
  property string roomDescription: ""

  // Matrix green through to purple. Deliberately not taken from the Omarchy
  // theme: this is the plugin's own identity. The background still comes from
  // the theme, so the panel sits in the desktop rather than fighting it.
  readonly property color matrixGreen: "#00FF41"
  readonly property color matrixDim:   "#3BD98A"
  readonly property color forcePurple: "#A855F7"
  readonly property color forceDeep:   "#7C3AED"

  readonly property color fg: Color.popups.text
  readonly property color bg: Color.popups.background
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.38)

  function open() {
    opened = true
    if (service) {
      service.refreshDevices()
      service.syncProfile()
    }
  }

  function close() {
    opened = false
    activity = ""
  }

  function toggle() { opened ? close() : open() }

  property bool rescanning: false

  // Live output levels, sampled by bin/jspeaker-levels while the panel is open.
  property var levels: null
  property var levelHistory: ({})

  readonly property string levelsPath:
    Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-jetti-speaker/levels.json"

  // Count before and after so the result can say what actually changed --
  // "rescanned" on its own leaves you wondering whether it did anything.
  property int speakersBeforeRescan: -1

  function redetect() {
    if (busy || !service) return
    rescanning = true
    speakersBeforeRescan = liveSpeakers.length
    activity = "Re-reading the hardware…"
    service.redetect()
  }

  // Crossover steps follow the octave-ish points people actually reach for,
  // rather than a free slider that invites 1 Hz precision nobody can hear.
  readonly property var crossoverSteps: [200, 300, 400, 500, 700, 1000, 1400, 2000, 3000]

  function nextCrossover(current, direction) {
    var value = Number(current) || 800
    var steps = crossoverSteps
    var i = 0
    while (i < steps.length && steps[i] < value - 1) i++
    i = Math.max(0, Math.min(steps.length - 1, i + (direction >= 0 ? 1 : -1)))
    return steps[i]
  }

  // Only speakers that are actually in the group appear on the stage; an
  // absent or disabled one has no position worth arranging.
  readonly property var stageSpeakers: {
    if (!profile || !profile.speakers) return []
    return profile.speakers.filter(function (s) {
      return s.enabled && s.sink && s.present !== false
    })
  }

  // posX is -1..1 across the stage, posY is 0 (far) .. 1 (close to you). The
  // vertical axis is inverted on screen because "further away" reads as
  // higher up, away from the listener at the bottom.
  function stageX(stage, chip, posX) {
    var span = Math.max(1, stage.width - chip.width)
    return ((Number(posX) || 0) + 1) / 2 * span
  }

  function stageY(stage, chip, posY) {
    var span = Math.max(1, stage.height - chip.height - 26)
    return (1 - Math.max(0, Math.min(1, Number(posY) || 0))) * span
  }

  function stagePosX(stage, chip) {
    var span = Math.max(1, stage.width - chip.width)
    return Math.round((chip.x / span * 2 - 1) * 1000) / 1000
  }

  function stagePosY(stage, chip) {
    var span = Math.max(1, stage.height - chip.height - 26)
    return Math.round((1 - chip.y / span) * 1000) / 1000
  }

  onOpenedChanged: if (opened) Qt.callLater(function () { keyCatcher.forceActiveFocus() })

  // --- long-running actions --------------------------------------------
  // Calibration and tuning take many seconds and produce text worth reading,
  // so they get their own processes rather than going through the service's
  // single command slot.

  function calibrate() {
    if (busy) return
    activity = "Measuring: each speaker sweeps in turn. Stay quiet."
    transcript = ""
    calibrateProcess.command = [jspeaker, "calibrate"]
    calibrateProcess.running = true
  }

  function tune() {
    if (busy) return
    activity = Model.isCalibrated(profile)
      ? "Asking the agent to place and align the speakers…"
      : "Nothing measured yet — calibrate first."
    if (!Model.isCalibrated(profile)) return
    transcript = ""
    var args = [jspeaker, "tune"]
    if (roomDescription.trim().length > 0) args.push(roomDescription.trim())
    tuneProcess.command = args
    tuneProcess.running = true
  }

  // Sampling costs one capture stream per speaker, so it runs only while the
  // panel is actually on screen.
  Process {
    id: levelsProcess
    running: root.opened && root.running
    command: [root.pluginDir + "bin/jspeaker-levels"]
  }

  FileView {
    id: levelsFile
    path: root.opened ? root.levelsPath : ""
    watchChanges: true
    printErrors: false
    onLoaded: {
      var parsed = Model.safeParse(text(), null)
      if (!parsed) return
      root.levels = parsed
      root.levelHistory = Model.pushLevels(root.levelHistory, parsed)
      outputChart.requestPaint()
    }
    onFileChanged: reload()
  }

  Process {
    id: calibrateProcess
    property string out: ""
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: calibrateProcess.out = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text) root.transcript = Model.clean(text, 600) }
    onExited: function (code) {
      root.transcript = code === 0 ? calibrateProcess.out : (root.transcript || "Calibration failed.")
      root.activity = code === 0 ? "Measurement complete." : "Calibration failed."
      calibrateProcess.out = ""
      if (root.service) root.service.refreshDevices()
    }
  }

  Process {
    id: tuneProcess
    property string out: ""
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: tuneProcess.out = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text) root.transcript = Model.clean(text, 600) }
    onExited: function (code) {
      root.transcript = code === 0 ? tuneProcess.out : (root.transcript || "Tuning failed.")
      root.activity = code === 0 ? "Tuning applied to the profile." : "Tuning failed."
      tuneProcess.out = ""
    }
  }

  Connections {
    target: root.service
    function onCommandFinished(action, ok, output) {
      if (!ok) {
        root.rescanning = false
        root.activity = root.service.lastError || (action + " failed")
        return
      }
      if (action === "redetect") {
        root.rescanning = false
        if (root.service) root.service.refreshDevices()
        var now = root.liveSpeakers.length
        var was = root.speakersBeforeRescan
        if (was < 0 || now === was)
          root.activity = "Rescanned — " + now + (now === 1 ? " speaker" : " speakers")
            + ", nothing changed."
        else if (now > was)
          root.activity = "Rescanned — found " + (now - was) + " new."
        else
          root.activity = "Rescanned — " + (was - now) + " no longer present."
        root.speakersBeforeRescan = -1
        return
      }
      if (action === "unhide") { root.activity = "Hidden outputs restored."; return }
      if (action === "forget") { root.activity = "Removed from the group."; return }
      if (action === "apply") root.activity = "Group is live."
      else if (action === "stop") root.activity = "Group stopped."
      else if (action === "unlock") root.activity = "Output unlocked."
      else if (action === "revert") root.activity = "Card profiles restored."
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-jetti-speaker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Clicking the dimmed backdrop closes, which is the gesture people try
    // first and costs nothing to support.
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the room description is being typed, Escape and every other key
      // belong to the field, not to the panel.
      blocked: descriptionField.activeFocus
      onCloseRequested: root.close()

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(760, parent.width - 80)
      height: Math.min(contentColumn.implicitHeight + 48, parent.height - 80)
      color: root.bg
      radius: Style.cornerRadius
      border.width: Style.normalBorderWidth
      border.color: Color.popups.border

      // Swallow clicks so they do not reach the close-on-backdrop handler.
      MouseArea { anchors.fill: parent }

      QQC.ScrollView {
        anchors.fill: parent
        anchors.margins: 24
        clip: true
        contentWidth: availableWidth

        Column {
          id: contentColumn
          width: card.width - 48
          spacing: 14

          // ---- header ----
          Item {
            width: parent.width
            height: 42

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: 10

              Image {
                anchors.verticalCenter: parent.verticalCenter
                source: Qt.resolvedUrl("logo.svg")
                sourceSize.width: 34
                sourceSize.height: 34
                width: 34
                height: 34
                smooth: true
                // The waves pulse gently only while the group is actually
                // playing, so the header doubles as a state indicator.
                opacity: root.running ? 1.0 : 0.45
                Behavior on opacity { NumberAnimation { duration: 350 } }
              }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              Text {
                text: "Jetti Speaker"
                color: root.matrixGreen
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: root.running
                  ? Model.summary(root.service ? root.service.status : null, root.profile)
                  : "Every speaker, one sound"
                color: root.running ? root.matrixDim : root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            }

            Button {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.running ? "Stop" : "Start group"
              bordered: true
              active: root.running
              enabled: !root.busy
              onClicked: if (root.service) root.service.toggle()
            }
          }

          PanelSeparator { width: parent.width }

          // ---- warnings ----
          Repeater {
            model: root.warnings
            Rectangle {
              width: contentColumn.width
              height: warnText.implicitHeight + 16
              color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.10)
              radius: Style.cornerRadius
              Text {
                id: warnText
                anchors.fill: parent
                anchors.margins: 8
                text: modelData.message
                color: root.fg
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- stage ----
          PanelSectionHeader {
            width: parent.width
            foreground: root.matrixDim
            text: "Where your speakers are"
            visible: root.stageSpeakers.length > 0
          }

          Text {
            width: parent.width
            visible: root.stageSpeakers.length > 0
            text: "Drag each speaker to match your desk. Left and right set the "
              + "stereo image; further away means it has further to travel."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            id: stage
            width: contentColumn.width
            height: 168
            visible: root.stageSpeakers.length > 0
            color: Style.normalFill
            radius: Style.cornerRadius
            border.width: Style.normalBorderWidth
            border.color: root.faint

            // The listener sits at the near edge, centred: everything on the
            // stage is positioned relative to where the person actually is.
            Rectangle {
              id: listener
              width: 12; height: 12; radius: 6
              color: root.forcePurple
              opacity: 0.9
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 10
            }
            Text {
              anchors.horizontalCenter: listener.horizontalCenter
              anchors.bottom: listener.top
              anchors.bottomMargin: 2
              text: "you"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.left: parent.left; anchors.leftMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              text: "L"; color: root.faint
              font.family: Style.font.family; font.pixelSize: Style.font.caption
            }
            Text {
              anchors.right: parent.right; anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              text: "R"; color: root.faint
              font.family: Style.font.family; font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.stageSpeakers

              Rectangle {
                id: chip
                width: Math.max(96, chipLabel.implicitWidth + 20)
                height: 34
                radius: Style.cornerRadius > 0 ? 8 : 0
                color: modelData.band === "primary" ? Style.selectedFill : Style.normalFill
                border.width: Style.normalBorderWidth
                // Green carries the full range, purple carries a part of it --
                // the same split the logo's waves use.
                border.color: dragArea.drag.active
                  ? root.matrixGreen
                  : (modelData.band === "primary"
                     ? Qt.rgba(root.matrixGreen.r, root.matrixGreen.g, root.matrixGreen.b, 0.7)
                     : Qt.rgba(root.forcePurple.r, root.forcePurple.g, root.forcePurple.b, 0.6))

                // While a drag is in flight the chip owns its own position;
                // otherwise it follows the profile, so an edit from anywhere
                // else moves it too.
                property bool dragging: dragArea.drag.active
                x: dragging ? x : root.stageX(stage, chip, modelData.posX)
                y: dragging ? y : root.stageY(stage, chip, modelData.posY)

                Column {
                  id: chipLabel
                  anchors.centerIn: parent
                  spacing: 0
                  Text {
                    text: Model.clean(modelData.label, 18)
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: Model.bandLabel(modelData.band)
                    color: modelData.band === "primary" ? root.matrixDim : root.forcePurple
                    font.family: Style.font.family
                    font.pixelSize: Math.max(8, Style.font.caption - 2)
                  }
                }

                MouseArea {
                  id: dragArea
                  anchors.fill: parent
                  cursorShape: Qt.SizeAllCursor
                  drag.target: chip
                  drag.axis: Drag.XAndYAxis
                  drag.minimumX: 0
                  drag.maximumX: stage.width - chip.width
                  drag.minimumY: 0
                  drag.maximumY: stage.height - chip.height - 26
                  onReleased: {
                    if (!root.service) return
                    root.service.setSpeakerPos(
                      modelData.key,
                      root.stagePosX(stage, chip),
                      root.stagePosY(stage, chip))
                  }
                }
              }
            }
          }

          // ---- live output ----
          PanelSectionHeader {
            width: parent.width
            foreground: root.matrixDim
            text: "Live output"
            visible: root.running
          }

          Rectangle {
            width: contentColumn.width
            height: 150
            visible: root.running
            color: Qt.rgba(0, 0, 0, 0.28)
            radius: Style.cornerRadius
            border.width: Style.normalBorderWidth
            border.color: Qt.rgba(root.matrixGreen.r, root.matrixGreen.g,
                                  root.matrixGreen.b, 0.28)

            Canvas {
              id: outputChart
              anchors.fill: parent
              anchors.margins: 6
              antialiasing: true

              readonly property real floorDb: root.levels && root.levels.floorDb
                ? root.levels.floorDb : -70

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.clearRect(0, 0, width, height)

                // Grid: a line every 20 dB, labelled, so the chart reads as
                // measurement rather than decoration.
                ctx.lineWidth = 1
                ctx.font = "9px monospace"
                for (var db = 0; db >= floorDb; db -= 20) {
                  var y = height - Model.levelFraction(db, floorDb) * height
                  ctx.strokeStyle = Qt.rgba(1, 1, 1, db === 0 ? 0.16 : 0.08)
                  ctx.beginPath()
                  ctx.moveTo(26, y)
                  ctx.lineTo(width, y)
                  ctx.stroke()
                  ctx.fillStyle = Qt.rgba(1, 1, 1, 0.35)
                  ctx.fillText(db + "", 2, Math.min(height - 2, y + 3))
                }

                var speakers = (root.levels && root.levels.speakers) || []
                for (var i = 0; i < speakers.length; i++) {
                  var sp = speakers[i]
                  var series = root.levelHistory[sp.key] || []
                  if (series.length < 2) continue

                  var step = (width - 26) / (Model.LEVEL_HISTORY - 1)
                  // Right-align: newest sample at the right edge, so the chart
                  // scrolls the way people expect rather than growing from 0.
                  var startX = width - (series.length - 1) * step

                  ctx.strokeStyle = sp.colour
                  ctx.lineWidth = 1.8
                  ctx.lineJoin = "round"
                  ctx.beginPath()
                  for (var j = 0; j < series.length; j++) {
                    var x = startX + j * step
                    var yy = height - Model.levelFraction(series[j], floorDb) * height
                    if (j === 0) ctx.moveTo(x, yy)
                    else ctx.lineTo(x, yy)
                  }
                  ctx.stroke()
                }
              }
            }
          }

          // Legend doubles as a readout: the colour identifies the line, the
          // number says where it is right now.
          Flow {
            width: contentColumn.width
            spacing: 14
            visible: root.running

            Repeater {
              model: (root.levels && root.levels.speakers) || []

              Row {
                spacing: 6
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: 12; height: 3; radius: 1.5
                  color: modelData.colour
                }
                Text {
                  text: Model.clean(modelData.label, 24)
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: Model.formatDb(modelData.rmsDb)
                  color: modelData.colour
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                }
                Text {
                  // A speaker pinned at the floor while others move is the
                  // signature of a link that has dropped.
                  visible: modelData.rmsDb <= (root.levels.floorDb + 0.1)
                  text: "silent"
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.italic: true
                }
              }
            }
          }

          // ---- speakers ----
          Item {
            width: parent.width
            height: 24

            PanelSectionHeader {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Speakers"
              foreground: root.matrixDim
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6

              // Something removed stays removed across a rescan, so the way
              // back has to live next to the rescan or it is undiscoverable.
              Button {
                visible: root.service && root.service.hiddenCount > 0
                text: "Restore " + (root.service ? root.service.hiddenCount : 0) + " hidden"
                bordered: true
                enabled: !root.busy
                tooltipText: "Outputs you removed are skipped when detecting. "
                  + "This makes them visible again."
                onClicked: if (root.service) root.service.unhide()
              }

              Button {
                text: root.busy && root.rescanning ? "Detecting…" : "Redetect speakers"
                bordered: true
                enabled: !root.busy
                tooltipText: "Re-read the hardware and fold anything new into the group. "
                  + "Existing tuning is kept; nothing is played."
                onClicked: root.redetect()
              }
            }
          }

          Repeater {
            model: root.liveSpeakers

            Rectangle {
              width: contentColumn.width
              height: speakerRow.implicitHeight + 16
              color: modelData.enabled ? Style.normalFill : "transparent"
              radius: Style.cornerRadius
              border.width: Style.normalBorderWidth
              border.color: modelData.enabled ? Style.normalBorderColor : root.faint

              Column {
                id: speakerRow
                property var speaker: modelData
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 10
                spacing: 6

                Item {
                  width: parent.width - 20
                  x: 10
                  height: 22

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.clean(modelData.label, 42)
                      + (modelData.present === false ? "  (not connected)" : "")
                    color: modelData.enabled ? root.fg : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Button {
                      text: Model.roleLabel(modelData.channel)
                      bordered: true
                      enabled: modelData.enabled && !root.busy
                      tooltipText: "Which channels this speaker reproduces"
                      onClicked: if (root.service)
                        root.service.setSpeaker(modelData.key, "channel",
                                                Model.nextRole(modelData.channel))
                    }

                    Button {
                      text: modelData.enabled ? "On" : "Off"
                      bordered: true
                      active: modelData.enabled
                      enabled: !root.busy && modelData.present !== false
                      onClicked: if (root.service)
                        root.service.setSpeaker(modelData.key, "enabled",
                                                modelData.enabled ? "false" : "true")
                    }
                  }
                }

                Row {
                  x: 10
                  spacing: 6
                  visible: modelData.enabled

                  Repeater {
                    model: ["primary", "tweeter", "bass"]
                    Button {
                      text: Model.bandLabel(modelData)
                      bordered: true
                      // `modelData` here is the band string; the speaker comes
                      // from the enclosing delegate.
                      property string band: modelData
                      active: speakerRow.speaker.band === band
                      enabled: !root.busy
                      tooltipText: Model.bandHint(band, speakerRow.speaker.crossoverHz)
                      onClicked: if (root.service)
                        root.service.setSpeaker(speakerRow.speaker.key, "band", band)
                    }
                  }

                  Button {
                    text: "\u2212"
                    bordered: true
                    enabled: !root.busy
                    tooltipText: "Quieter"
                    onClicked: if (root.service)
                      root.service.setSpeaker(speakerRow.speaker.key, "gain",
                        Model.nextGain(speakerRow.speaker.gain, -1))
                  }

                  Button {
                    text: Model.gainDb(speakerRow.speaker.gain)
                    bordered: true
                    active: Model.gainIsBoost(speakerRow.speaker.gain)
                    accent: Model.gainIsBoost(speakerRow.speaker.gain)
                      ? root.forcePurple : root.matrixGreen
                    enabled: false
                    tooltipText: Model.gainIsBoost(speakerRow.speaker.gain)
                      ? "Boosted above unity — can distort a small speaker"
                      : "Level for this speaker"
                  }

                  Button {
                    text: "+"
                    bordered: true
                    enabled: !root.busy
                    tooltipText: "Louder"
                    onClicked: if (root.service)
                      root.service.setSpeaker(speakerRow.speaker.key, "gain",
                        Model.nextGain(speakerRow.speaker.gain, 1))
                  }

                  Button {
                    text: "\u23ea"
                    bordered: true
                    enabled: !root.busy
                    tooltipText: "Earlier — less delay"
                    onClicked: if (root.service)
                      root.service.setSpeaker(speakerRow.speaker.key, "delayMs",
                        Model.nextDelay(speakerRow.speaker.delayMs, -1))
                  }

                  Button {
                    text: Model.formatDelay(speakerRow.speaker.delayMs)
                    bordered: true
                    active: (Number(speakerRow.speaker.delayMs) || 0) > 0.01
                    accent: root.forcePurple
                    enabled: false
                    tooltipText: "How long this speaker waits, to line up with the others"
                  }

                  Button {
                    text: "\u23e9"
                    bordered: true
                    enabled: !root.busy
                    tooltipText: "Later — more delay. Use this on a speaker that sounds ahead."
                    onClicked: if (root.service)
                      root.service.setSpeaker(speakerRow.speaker.key, "delayMs",
                        Model.nextDelay(speakerRow.speaker.delayMs, 1))
                  }

                  Button {
                    visible: speakerRow.speaker.band !== "primary"
                    text: Math.round(speakerRow.speaker.crossoverHz || 800) + " Hz"
                    bordered: true
                    enabled: !root.busy
                    tooltipText: "Crossover point — click to step it, right-click to step back"
                    onClicked: if (root.service)
                      root.service.setSpeaker(speakerRow.speaker.key, "crossoverHz",
                        root.nextCrossover(speakerRow.speaker.crossoverHz, 1))
                  }
                }

                Text {
                  x: 10
                  width: parent.width - 20
                  text: {
                    var bits = ["gain " + Model.formatGain(modelData.gain)
                                + " (" + Model.gainDb(modelData.gain) + ")",
                                "delay " + Model.formatDelay(modelData.delayMs)]
                    var m = modelData.measured
                    if (m && m.heard)
                      bits.push("measured " + m.levelDb.toFixed(1) + " dB")
                    else if (m)
                      bits.push("not heard when measured")
                    return bits.join("   ·   ")
                  }
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  x: 10
                  width: parent.width - 20
                  height: Model.looksDead(modelData) ? deadRow.implicitHeight : 0
                  visible: Model.looksDead(modelData)

                  Row {
                    id: deadRow
                    spacing: 8
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      width: speakerRow.width - 130
                      text: Model.deadNote(modelData)
                      color: Color.urgent
                      wrapMode: Text.WordWrap
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      text: "Remove"
                      bordered: true
                      enabled: !root.busy
                      tooltipText: "Drop this output from the group and stop offering it"
                      onClicked: if (root.service) root.service.forget(speakerRow.speaker.key)
                    }
                  }
                }

                Text {
                  x: 10
                  width: parent.width - 20
                  visible: Model.weaknessNote(modelData).length > 0
                  text: Model.weaknessNote(modelData)
                    + (Model.suggestionDiffers(modelData)
                       ? "  (calibration suggests " + Model.bandLabel(modelData.measured.suggestedBand) + ")"
                       : "")
                  color: Model.suggestionDiffers(modelData) ? Color.popups.text : root.faint
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  x: 10
                  width: parent.width - 20
                  visible: !!modelData.notes
                  text: modelData.notes || ""
                  color: root.dim
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.italic: true
                }
              }
            }
          }

          // ---- locked outputs ----
          PanelSectionHeader {
            width: parent.width
            foreground: root.matrixDim
            text: "Hidden outputs"
            visible: root.lockedSpeakers.length > 0
          }

          Repeater {
            model: root.lockedSpeakers

            Rectangle {
              width: contentColumn.width
              height: lockedCol.implicitHeight + 16
              color: "transparent"
              radius: Style.cornerRadius
              border.width: Style.normalBorderWidth
              border.color: root.faint

              Column {
                id: lockedCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Item {
                  width: parent.width - 20
                  x: 10
                  height: 22
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.clean(modelData.label, 42)
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                  }
                  Button {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Unlock"
                    bordered: true
                    enabled: !root.busy
                    tooltipText: "Switches the card profile, then plays a brief sweep "
                      + "through each newly exposed output and undoes the whole thing "
                      + "if none of them is heard"
                    onClicked: if (root.service) root.service.unlock(modelData.card)
                  }
                }

                Text {
                  x: 10
                  width: parent.width - 20
                  text: {
                    var u = modelData.unlock
                    if (!u) return ""
                    if (u.sacrifices && u.sacrifices.length > 0)
                      return "Switching to " + u.description + " turns off: "
                        + u.sacrifices.join(", ")
                    return u.note || ("Switches this card to " + u.description + ".")
                  }
                  color: root.faint
                  wrapMode: Text.WordWrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Button {
            visible: root.lockedSpeakers.length > 0 || (root.devices && root.devices.restorable)
            text: "Restore card profiles"
            bordered: true
            enabled: !root.busy
            onClicked: if (root.service) root.service.revertCards()
          }

          PanelSeparator { width: parent.width }

          // ---- measure and tune ----
          PanelSectionHeader { width: parent.width; text: "Harmonize" }

          Text {
            width: parent.width
            text: "Describe where your speakers are. The agent combines this with the "
              + "microphone measurement to decide stereo placement, level, and timing."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: descriptionField
            width: parent.width
            placeholderText: "e.g. Bluetooth speaker 2 m to my left, laptop in front of me"
            text: root.roomDescription
            onTextChanged: root.roomDescription = text
          }

          Row {
            spacing: 8

            Button {
              text: calibrateProcess.running ? "Measuring…" : "Calibrate with mic"
              bordered: true
              enabled: !root.busy
              tooltipText: "Plays a sweep through each speaker and listens with your microphone"
              onClicked: root.calibrate()
            }

            Button {
              text: tuneProcess.running ? "Thinking…" : "Tune with AI"
              bordered: true
              enabled: !root.busy && Model.isCalibrated(root.profile)
              tooltipText: Model.isCalibrated(root.profile)
                ? "Turn the measurements into channel roles, levels, and delays"
                : "Calibrate first — there is nothing to reason about yet"
              onClicked: root.tune()
            }

            Button {
              text: "Use measured roles"
              bordered: true
              enabled: !root.busy && Model.isCalibrated(root.profile)
              tooltipText: "Set each speaker's role and crossover from the measurement"
              onClicked: if (root.service) root.service.applySuggestions()
            }

            Button {
              text: "Apply"
              bordered: true
              active: true
              enabled: !root.busy
              tooltipText: "Rebuild the group with the current tuning"
              onClicked: if (root.service) root.service.start()
            }
          }

          Text {
            width: parent.width
            visible: root.activity.length > 0
            text: root.activity
            color: root.fg
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: parent.width
            visible: root.transcript.length > 0
            height: transcriptText.implicitHeight + 16
            color: Style.normalFill
            radius: Style.cornerRadius

            Text {
              id: transcriptText
              anchors.fill: parent
              anchors.margins: 8
              text: root.transcript
              color: root.dim
              wrapMode: Text.WordWrap
              font.family: "monospace"
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: !!(root.profile && root.profile.ai && root.profile.ai.summary)
            text: root.profile && root.profile.ai ? root.profile.ai.summary : ""
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.italic: true
          }
        }
      }
    }
    }
  }

  // Shell entry points. `summon` carries an optional JSON payload; an action of
  // "toggle" is what the bar widget sends.
  function summon(payloadJson) {
    var payload = Model.safeParse(payloadJson, {})
    if (payload.action === "calibrate") { open(); calibrate(); return }
    if (payload.action === "toggle") { toggle(); return }
    open()
  }
}
