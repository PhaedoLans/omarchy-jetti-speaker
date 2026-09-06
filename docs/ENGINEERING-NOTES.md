# Engineering notes

Why this plugin is built the way it is, and the traps that cost real time
building it. The README explains what Jetti Speaker does; this explains the
decisions and the sharp edges.

## Design decisions

**The CLI owns the audio graph; the shell only watches it.** `Service.qml` reads
`status.json` and `profile.json` and shells out to `jspeaker`. It never builds
PipeWire objects itself. That split means the group keeps working across shell
restarts, and a crashed shell can never leave half a graph behind.

**One `pw-loopback` per speaker, not one combine-stream.** `module-combine-stream`
fans out to several sinks but has no per-output delay, and delay is the entire
point. `pw-loopback` carries `--delay` per instance, so each speaker keeps its
own delay, gain, and channel role while sharing one clock and one virtual sink.

**Playback streams are linked explicitly, never placed by the session manager.**
Each loopback is created with `node.autoconnect=false` and its ports are wired
onto the target sink with `pw-link`. This exists because EasyEffects moves
playback streams into its own sink; when its output also feeds the group sink,
that closes a cycle (`group → loopback → easyeffects_sink → group`) and the
whole group goes silent. An explicit link cannot be intercepted. It also means
port names are read from the graph rather than assumed — a normal sink exposes
`playback_FL/FR`, a card in `pro-audio` exposes `playback_AUX0/AUX1`.

**Calibration plays one multichannel file, not one sweep per speaker.**
`pw-play` and `pw-record` do not start together and the offset between them is
unknown and different every run, so timing a single sweep measures start jitter,
not the speaker. All sweeps ride in one stream, isolated per speaker by channel
(`stream.dont-remix=true` plus a single `audio.position`), so they share one
unknown offset `T0` that cancels when speakers are compared. See the header of
`lib/jspeaker_dsp.py`.

**Range validation is not enough; a value needs justification.** The bug that
motivated this: the model was handed a null arrival time for a speaker that had
never been heard, computed "latest arrival minus zero", and proposed an 844.9 ms
delay — another speaker's raw arrival time. The clamp accepted it because
844.9 ms is a legal number. A delay is now refused outright unless that speaker
has a measurement to align to, and the payload omits metrics for unheard
speakers rather than sending nulls to do arithmetic on. Regression tests live in
`tests/tune.test.py`.

## Omarchy / Quickshell traps

**A `readonly property var service` silently breaks the whole panel.** The shell
does `if ("service" in item) item.service = shell.serviceFor(id)` inside
`Loader.onLoaded`. Assigning to a readonly property throws, which aborts the
rest of `onLoaded` — including `registerPanelLoader()`. The result is a plugin
that loads, reports `summon` as `ok`, and never opens, with no error naming your
file. Declare `service` as a plain property.

**Clear the QML compile cache when an error will not go away.** Quickshell
caches compiled QML in `~/.cache/quickshell/qmlcache/`. A stale entry reproduces
an error against source that no longer contains it — including reporting a line
number whose content is now blank. `rm -rf ~/.cache/quickshell/qmlcache/*` then
`omarchy restart shell`.

**Assigning a non-existent QML property is fatal, not cosmetic.** `PanelWindow`
has no `focus`; that one line stopped the component from being created at all.
Worse, the shell's own reporting for it is broken (`shell.qml` logs
`ReferenceError: errorString is not defined` instead of the real reason), so a
load failure can surface as nothing but silence. Grep the journal for your
plugin id after every change:

```bash
journalctl --user --since "-1 min" | grep -i jetti.speaker
```

**`PanelWindow` is not a focus scope.** Use `PanelKeyCatcher` from `qs.Ui` inside
it, give it an `id`, and `forceActiveFocus()` it when the panel opens. Set its
`blocked` property while a `TextField` has focus, or Escape and every keystroke
gets eaten by the panel instead of the field.

**Property values reaching `pw-loopback` are SPA JSON.** An unquoted space ends
the value and the rest becomes a syntax error, so a speaker labelled
`SK010` worked and one labelled `USL SK010` did not. Quote the value and strip
characters that would close the quote early — device names come from vendors.

**A plugin's presence in `shell.json`'s `bar.layout` is its enabled state** for a
bar-widget plugin. Renaming a plugin id means editing that string in place;
re-adding it via `omarchy plugin enable` loses the widget's position. Non-bar
third-party plugins are listed under the top-level `plugins` key instead.

## Hazards that bite regardless of language

**Never `pkill -f <pattern>` where the pattern matches your own command line.**
`pkill -f pw-loopback` from a shell whose argv contains `pw-loopback` kills that
shell. This happened three times here despite a comment in
`lib/jspeaker-common.sh` warning about it. Kill by recorded pid, and verify
`/proc/<pid>/cmdline` before signalling in case the pid was recycled —
`jspeaker_kill_pidfile` does both. To *list* them safely, match on `comm`, not
the full command line:

```bash
ps -eo pid,comm | awk '$2 ~ /^pw-loopback$/ {print $1}'
```

**Verify a measuring instrument before trusting a negative result.** Several
rounds were spent concluding "nothing reaches this sink" from readings that were
a broken probe: `pw-record` with a non-existent `--target` records digital
silence rather than failing. Run a control through a path known to work first.
If the control also reads silence, the instrument is wrong, not the system.

**`wpctl` and `pactl` volumes are cubic.** The measurement maths produces linear
amplitude (`10^(dB/20)`), so it must be cube-rooted before being handed to
either. Applied directly, a gain of `0.25` intended as -12 dB becomes -36 dB.
`apply_gain` in `bin/jspeaker-graph` does the conversion.

**WirePlumber pins card profiles and re-applies them.** `pactl set-card-profile`
alone is not durable; see *WirePlumber overrides card profiles* in the README.

**`pw-record --target <sink>.monitor` does not capture that sink.** It silently
records something else, and it is convincing: three sinks measured at once,
including a control with nothing routed to it, returned `-54.4 dB` to the
decimal. Capture the *sink* with `stream.capture.sink=true` instead — the same
property the fan-out loopbacks use to read the group sink. The same test then
gave the playing speaker `-34.3 dB` and both silent ones `-90.0`. This is the
third measurement in this project that looked plausible and meant nothing, after
the monitor probes and `pw-top`'s rate column. Any negative result from a new
instrument needs a positive control before it is believed.

**Channel names are not always `front-left`.** A card in pro-audio exposes
`aux0`/`aux1`, so `.volume."front-left"` returns null and it looks like the sink
has no volume control. It has one; the query was wrong. This was written into
the docs as a hardware limitation before anyone tried
`pactl set-sink-volume`, which works fine. Read the first channel whatever it is
named. The same applies to port names: `playback_FL` on a normal sink,
`playback_AUX0` under pro-audio, which is why `link_nodes` reads them from the
graph instead of assuming.

**A delay is not a latency request, but pw-loopback treats it as one.** Given
`-d 0.002`, pw-loopback asks for a quantum small enough to place a 2 ms delay --
roughly 32 samples. Every node in a fan-out shares one driver, so that becomes
the graph quantum, and a card that cannot service a 0.67 ms period xruns without
end. It presents as garbled, slow audio and slow-motion video, because players
slave video to the audio clock. Pinning `node.latency` on every created node --
loopbacks and crossovers alike -- keeps a delay a delay. Check with `pw-top`:
`W/Q` above 1 on the driver means it cannot meet its period.

**Rebuilding the fan-out must not destroy the virtual sink.** The sink is the
device applications are connected to. Tearing it down to change one speaker's
delay pulls the output device out from under whatever is playing and orphans
anything aimed at it (EasyEffects included). `graph_stop_streams` exists to
rebuild the fan-out while leaving the sink alone; a full `graph_stop` is only
for actually stopping the group.

**A crossover is a real sink, so device detection must exclude it.**
`libpipewire-module-filter-chain` publishes its capture side as an
`Audio/Sink` — that is how a loopback feeds it. Detection then saw it as a
speaker, `profile sync` added it, and it got a loopback of its own, so that
speaker received two copies of everything. Anything the plugin creates belongs
in `VIRTUAL_HINTS` in `bin/jspeaker-devices`, and there is a regression test for
it in `tests/devices.test.py`. The same reasoning covers the group sink itself.

**Count what you mean, not what matches the glob.** Crossovers write a
`<node>.xo.pid` beside the speaker's `<node>.pid`, and the status counter globbed
`*.pid` — so a two-speaker group reported three, which is the number the bar
badge shows.

**Exposure is not proof of sound — but silence is not proof of a broken profile
either.** `pro-audio` on an Intel ALC256 first measured as five exposed outputs
that made no sound, and that was reported as "pro-audio does not work on this
codec". It was wrong. Pro-audio simply hands the card's mixer back to ALSA: the
`Master` control was well below unity and the monitor's `IEC958 Playback Switch`
was off, so the outputs were real and muted. With those fixed, all of them play.
Two lessons, both expensive here: check `amixer` and the digital output switches
before blaming a profile, and be much slower to write a hardware conclusion into
the docs than to write a measurement.

## Known gaps

**A speaker that disappears does not come back on its own.** Playback streams are
created with `node.dont-reconnect=true`, deliberately: without it, a vanishing
target bounces the loopback onto the default sink, which is the group sink, and
that is a feedback loop. The cost is that when a Bluetooth speaker idles and
wakes, or any sink disappears and returns, its explicit links are gone and never
re-established. The speaker keeps every setting and receives nothing.

Observed directly: `jsout0` with no links while `bluez_output...` sat
`SUSPENDED`, the group reporting itself healthy. `jspeaker apply` restores it.
A watchdog that notices a profile speaker whose sink exists but whose loopback
has no links, and relinks it, would close this — the live output chart already
makes it *visible* (a line pinned at the floor, marked *silent*) but nothing
acts on it.

**The screen is carried at +12 dB for nothing.** An output that measures silent
repeatedly is flagged in the panel with a Remove button, but the count only
increments on a full calibration, so an output can sit in a group doing nothing
until the next measurement pass.

## Rename history

The project was originally *Unity Speaker Land* (`jetti.unity-speaker-land`,
CLI `usl`). If you find an old config or an old bar entry:

| Old | New |
|---|---|
| `jetti.unity-speaker-land` | `jetti.speaker` |
| `usl` (CLI) | `jspeaker` |
| `usl_unity` (sink) | `jetti_speaker` |
| `usl_cal` (sink) | `jetti_speaker_cal` |
| `~/.config/omarchy/unity-speaker-land/` | `~/.config/omarchy/jetti-speaker/` |
| `$XDG_RUNTIME_DIR/omarchy-usl/` | `$XDG_RUNTIME_DIR/omarchy-jetti-speaker/` |
| `USL_*` / `usl_*` | `JSPK_*` / `jspeaker_*` |
| `uslout` / `uslcal` (node prefixes) | `jsout` / `jscal` |

Note that `unity gain` in the source is the audio term for a gain of 1.0 and is
deliberately **not** renamed.
