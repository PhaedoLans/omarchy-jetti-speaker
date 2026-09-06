import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Keeps one view of the graph's state for every other part of the plugin, so
// the bar widget and the overlay never each shell out for the same answer.
//
// The CLI owns the audio graph; this only watches it. That split means the
// group keeps working when the shell restarts, and a crashed shell can never
// leave a half-built PipeWire graph behind.
Item {
  id: root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string jspeaker: pluginDir + "bin/jspeaker"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-jetti-speaker"
  readonly property string statusPath: runtimeDir + "/status.json"
  readonly property string profilePath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
    + "/omarchy/jetti-speaker/profile.json"

  property var status: ({ state: "stopped", speakerCount: 0 })
  property var profile: null
  property var devices: null
  property bool busy: false
  property string lastError: ""

  readonly property bool running: status && status.state === "running"
  readonly property int speakerCount: status && status.speakerCount ? status.speakerCount : 0

  signal refreshed()
  signal commandFinished(string action, bool ok, string output)

  // --- commands ---------------------------------------------------------

  function run(args, action) {
    if (busy) return false
    busy = true
    lastError = ""
    commandProcess.action = action || (args.length ? args[0] : "")
    commandProcess.command = [jspeaker].concat(args)
    commandProcess.running = true
    return true
  }

  function start() { return run(["apply"], "apply") }
  function stop() { return run(["stop"], "stop") }
  function toggle() { return running ? stop() : start() }
  function syncProfile() { return run(["profile", "sync"], "sync") }
  // Always verified: the button is one click, and an unverified unlock can
  // leave the user with fewer working speakers than they started with.
  function unlock(card) { return run(["card", "unlock", card, "--verify"], "unlock") }

  function forget(key) { return run(["profile", "forget", key], "forget") }

  function unhide() { return run(["profile", "unhide"], "unhide") }

  // Re-read the hardware and fold anything new into the profile. `sync` keeps
  // every speaker's existing tuning and only adds or marks absent, so this is
  // safe to press at any time -- including while the group is playing.
  function redetect() { return run(["profile", "sync"], "redetect") }

  readonly property int hiddenCount:
    profile && profile.ignored ? profile.ignored.length : 0
  function revertCards() { return run(["card", "revert"], "revert") }

  function setSpeaker(key, field, value) {
    pendingRebuild = graphFields.indexOf(field) >= 0
    return run(["profile", "set", key, field, String(value)], "set")
  }

  // Set when an edit needs the graph rebuilt to be audible; cleared once the
  // rebuild has been kicked off, so one edit never queues two applies.
  property bool pendingRebuild: false

  // Position is set in one call so the profile never holds half a move -- the
  // graph builder watches that file.
  function setSpeakerPos(key, x, y) {
    return run(["profile", "pos", key, String(x), String(y)], "pos")
  }

  function applySuggestions() { return run(["profile", "suggest"], "suggest") }

  function refreshDevices() {
    if (devicesProcess.running) return
    devicesProcess.running = true
  }

  // --- state ------------------------------------------------------------

  // Fields that change the shape of the graph need the fan-out rebuilt before
  // they can be heard. That is only safe to do automatically because a retune
  // now reuses the existing virtual sink -- rebuilding used to destroy the
  // device applications were playing into.
  readonly property var graphFields: ["gain", "delayMs", "band", "crossoverHz",
                                      "channel", "enabled"]

  Process {
    id: commandProcess
    property string action: ""
    property string output: ""
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: commandProcess.output = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.lastError = Model.clean(text, 400) }
    onExited: function (exitCode) {
      root.busy = false
      var out = output
      output = ""
      var finished = action
      root.commandFinished(finished, exitCode === 0, out)
      root.refreshDevices()
      statusFile.reload()
      profileFile.reload()

      // Apply the edit straight away, so a stepper is something you can hear
      // while the music plays rather than a value you have to remember to
      // commit. Only when the group is already up: a change made while it is
      // stopped should not start it.
      if (root.pendingRebuild && finished === "set" && exitCode === 0) {
        root.pendingRebuild = false
        if (root.running) Qt.callLater(function () { root.run(["apply"], "apply") })
      } else if (finished !== "set") {
        root.pendingRebuild = false
      }
    }
  }

  Process {
    id: devicesProcess
    command: [root.jspeaker, "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.devices = Model.safeParse(text, null)
        root.refreshed()
      }
    }
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onLoaded: root.status = Model.safeParse(text(), { state: "stopped", speakerCount: 0 })
    onFileChanged: reload()
  }

  FileView {
    id: profileFile
    path: root.profilePath
    watchChanges: true
    printErrors: false
    onLoaded: root.profile = Model.safeParse(text(), null)
    onFileChanged: reload()
  }

  // The graph lives in PipeWire, not in the shell, so its true state can change
  // without any file being written -- a Bluetooth speaker wandering out of
  // range takes a loopback with it. A slow poll keeps the bar honest without
  // making the shell busy.
  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: if (!root.busy) statusProcess.running = true
  }

  Process {
    id: statusProcess
    command: [root.jspeaker, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.safeParse(text, null)
        if (parsed) root.status = parsed
      }
    }
  }

  Component.onCompleted: {
    refreshDevices()
    statusProcess.running = true
  }
}
