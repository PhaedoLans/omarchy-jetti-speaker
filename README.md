# Jetti Speaker

Play through **every speaker at once** — Bluetooth, laptop, and the ones inside
your monitor — then measure the room with a microphone and let an agent
time-align and stereo-place them.

An Omarchy shell plugin (bar widget + panel + service) on top of a CLI that does
the real work.

The logo is a speaker driver with three waves — green nearest the cone, purple
furthest out, one wave per speaker in a group. The panel uses the same run of
colour throughout, and it carries meaning rather than decoration: **green** is
full range and carrying the bass, **purple** is a part of the range or something
being pushed. Backgrounds still come from the Omarchy theme, so the panel sits
in the desktop instead of fighting it.

## The problem it solves

Playing the same audio through several speakers is easy. Playing it through
several speakers *and having it sound like one system* is not, because they do
not arrive together:

```
measured on a ThinkPad + a cheap Bluetooth speaker

  laptop speakers   ▇ 0 ms
  Bluetooth SK010   ································▇ 233.5 ms
```

A third of a second of skew is not a stereo image, it is an echo. Jetti Speaker
measures that number instead of guessing it, then delays the *early* speakers so
everything lands together.

## How it works

```
   apps ──▶ jetti_speaker ──┬─▶ pw-loopback ──(delay 233.5 ms, gain 1.00)──▶ laptop speakers
        (virtual sink)  ├─▶ pw-loopback ──(delay   0.0 ms, gain 0.25)──▶ Bluetooth speaker
                        └─▶ pw-loopback ──(delay  12.0 ms, gain 0.70)──▶ monitor speakers
```

One virtual sink fans out through one `pw-loopback` per speaker. Each loopback
carries that speaker's own delay, gain, and channel role, so speakers stay
independently tunable while sharing a single clock.

### Finding speakers that are not there yet

Some outputs exist in hardware but are invisible because the sound card is in a
profile that hides them — a monitor's DisplayPort audio, an S/PDIF jack. Worse,
on a shared HDA codec the normal profiles are *mutually exclusive*: you can have
laptop speakers or monitor speakers, not both.

Jetti Speaker lists those as **hidden outputs** and offers to unlock them,
saying up front what the switch costs. The `pro-audio` profile exposes every
output on the card simultaneously, at the price of automatic jack detection and
hardware volume. Nothing switches without a click, and `jspeaker card revert` puts it
all back.

**Unlock verifies itself.** The panel's Unlock switches the card profile, plays
a brief sweep through each newly exposed output, and **reverts the whole thing**
— profile, WirePlumber pin and saved state — if none of them is heard. Exposing
a sink is not proof it makes a sound, and an unverified unlock can leave you
with fewer working speakers than you started with. `jspeaker card unlock <card>
--verify` does the same from the CLI; `jspeaker calibrate --probe <sink>`
measures one output on its own and changes nothing.

A probe uses a lower confidence bar than a full calibration (18 vs 40) and takes
the best of two sweeps. It asks a cruder question on less data: measured here, a
silent DisplayPort output scored 6x while working laptop speakers scored 35x,
which the calibration floor would have called silent too.

**Verify before you trust it.** Exposure is not proof of sound, and a card in
pro-audio behaves differently in two ways worth knowing:

- PipeWire does not manage the card's mixer, so whatever ALSA's `Master`,
  `Speaker` and `PCM` controls happen to be set to is what you get. A card that
  seems silent or very quiet in pro-audio is often just a low `Master`
  (`amixer -c <n> sget Master`). The digital output switches matter too: an
  HDMI/DP output whose `IEC958 Playback Switch` is off accepts audio and makes
  no sound.
- Pro-audio sinks name their channels `aux0`/`aux1` rather than `front-left`/
  `front-right`. They *do* have a working volume control, but a script that
  reads `.volume."front-left"` gets `null` and concludes there is none. Read the
  first channel whatever it is called, or just use
  `pactl set-sink-volume <sink> <n>%`, which sets every channel regardless.

It also renames the card's capture devices, which changes the microphone
calibration uses. After unlocking, run `jspeaker calibrate`: if the newly
exposed speaker reports *not heard* while a speaker on another card reports high
confidence, check the mixer and the `IEC958` switch before concluding the
profile is useless — and `jspeaker card revert` is always the way back.

### Measuring, without a stopwatch problem

`pw-play` and `pw-record` do not start at the same instant, and the offset
between them is unknown and different every run. Timing a sweep naively measures
that jitter, not the speaker.

So no speaker is ever measured alone. Every speaker's sweep lives in **one
multichannel file played through one stream**, isolated per speaker by channel:

```
jetti_speaker_cal (4-channel sink)
  monitor_FL ─▶ loopback ─▶ speaker 1      sweeps at t = 1.0 s
  monitor_FR ─▶ loopback ─▶ speaker 2      sweeps at t = 3.0 s
  monitor_RL ─▶ loopback ─▶ speaker 3      sweeps at t = 5.0 s
```

Every sweep now shares one unknown start offset `T0`. For a speaker emitted at
known time `e`, the recorded arrival is `T0 + e + flight`. Subtracting the known
`e` leaves `T0 + flight`, and since `T0` is identical for all of them it cancels
the moment speakers are compared — which is all an alignment needs.

Arrival is found with a matched filter against the sweep, on a decimated copy
(12 kHz still resolves 83 µs, or 2.8 cm of air). Synthetic signals with known
delays recover to **better than 0.1 ms**. The correlation peak's height above
its own mean is kept as a confidence figure, so a speaker that was muted or out
of range is reported as *not heard* rather than as a plausible-looking number.

### What the agent decides

The measurement says what is true. It does not say which speaker is on your
left, or whether the speaker behind you belongs in the stereo image at all. So
the numbers plus your own description of the room go to your Omarchy default
agent, which returns channel roles, gains, and delays.

Every field it returns is validated and clamped against the same rules the
profile editor enforces — a bad reply degrades to a rejected suggestion, never
to two seconds of delay or a blown driver. A one-sided left/right split is
rejected outright, because it would silently drop a channel. With no agent
available, a deterministic fallback (align to the latest, trim to the quietest)
still produces a working profile.

## Roles: which speaker does which job

Speakers in a group are rarely equals. A Bluetooth speaker has real bass; the
drivers in a laptop lid do not, and asking them for it just makes them distort.
So each speaker gets a **role** as well as a position:

| Role | What it does |
|---|---|
| **Primary** | Full range, and the reference everything else aligns to. The speaker that can actually carry bass. |
| **Tweeter** | High-passed. Removing the bass a small driver cannot reproduce frees its excursion, so it plays the highs it *is* good at louder and cleaner. |
| **Bass** | Low-passed. The opposite job, for a speaker with reach but no detail. |

Each filtered speaker gets its own 4th-order Linkwitz-Riley crossover
(24 dB/octave, two cascaded biquads) running in its own PipeWire filter-chain
process, inserted between that speaker's loopback and the speaker itself:

```
group sink ─▶ loopback (delay + gain) ─▶ crossover ─▶ speaker
```

### Gain range

Gain is a linear amplitude and runs from 0.25 to **4.0** (-12 dB to +12 dB).
Above 1.0 it is a boost, which the panel marks in purple. That range exists
because a small speaker crossed over high genuinely needs it: on the machine
this was built on, the laptop tweeter measured 18 dB below the primary at the
listening position and could not be balanced within unity gain. Crossing it over
frees the excursion that makes the boost survivable — the bass that would have
made it distort is already gone.

### Finding the weak ones by measurement

Calibration already sweeps each speaker, so it also records an octave-band
response. Comparing each speaker's **bass-to-midrange ratio** answers "does this
thing have any low end at all" independently of how loud it is or how far away
it sits. On the machine this was built on:

```
                    125Hz   250Hz   500Hz    1kHz    2kHz   bass vs mid
  SK010 (BT)        -17.7   -13.4   -18.3   -19.1   -13.1     +0.5 dB
  laptop speakers   -60.6   -54.5   -46.6   -29.1   -39.5    -23.3 dB
```

The Bluetooth speaker is flat to 125 Hz; the laptop is 23 dB down. So the
Bluetooth speaker becomes the primary and the laptop becomes a tweeter, crossed
over at its *knee* — the lowest band where it still keeps up with its own
midrange, 1 kHz here. `jspeaker profile suggest`, or **Use measured roles** in
the panel, applies that.

Measuring this needs in-band energy, not a broadband RMS of a time window: a
window measures room noise and distortion harmonics too, which reads back as
the noise floor for a band the speaker cannot reproduce and makes every speaker
look equally capable of bass.

## The live output chart

While the panel is open and the group is playing, it charts what each speaker
is **actually being sent**, in dBFS, one coloured line per speaker. The legend
doubles as a readout, and a speaker pinned at the floor while the others move is
marked *silent* — which is the quickest way to notice one has fallen out of the
group.

That distinction is the point: the chart shows measured output, not what the
profile says the settings are. A speaker can keep perfect settings and be
receiving nothing.

Getting the levels needs one non-obvious thing. Capturing a sink's `.monitor`
source by name **does not work** — `pw-record --target <sink>.monitor` silently
records something else, returning identical readings for every sink including
one with nothing routed to it. Capture the **sink** with
`stream.capture.sink=true` instead, which is the same property the fan-out
loopbacks use:

```bash
pw-record --target <sink-name> -P stream.capture.sink=true \
          --rate 48000 --channels 1 --format s16 --raw -
```

Sampling runs only while the panel is visible, since it costs one capture stream
per speaker. `bin/jspeaker-levels` does the work and writes a rolling snapshot
the panel watches.

## Redetecting

**Redetect speakers** in the panel re-reads the hardware and folds anything new
into the list. It is safe to press while the group is playing: existing tuning
is kept, nothing is played, and a speaker discovered by a rescan is listed but
left **off** until you turn it on — pressing rescan should never change what you
are hearing. (Building a profile from scratch with `profile init` does enable
what it finds, since the point there is to end up with a working group.)

Outputs you **Remove** are recorded in an `ignored` list and skipped by future
rescans, so they stay gone. The panel offers *Restore N hidden* next to the
rescan button when there are any.

## The stage

The panel shows a stage with you at the near edge and a draggable chip per
speaker. Left/right sets the stereo image, and further away means further to
travel. Dragging is deliberately loose about the stereo image: a speaker only
becomes a dedicated left or right channel past 0.75 of the way to an edge, and
the **primary is never narrowed** — it carries the bass and the main image, so
assigning it a single channel would silently drop the other.

## Using it

Click the speaker icon in the bar, or:

```bash
jspeaker profile init                    # build a profile from what is plugged in
jspeaker calibrate                       # play sweeps, listen, measure
jspeaker tune "BT speaker 2 m to my left, laptop in front of me"
jspeaker apply                           # route everything through the group
jspeaker stop                            # tear it down, restore the old default sink
```

`jspeaker` lives in this plugin's `bin/`. Add it to `PATH` if you want it everywhere:

```bash
export PATH="$HOME/.config/omarchy/plugins/jetti.speaker/bin:$PATH"
```

Right-clicking the bar widget starts and stops the group without opening the panel.

### Commands

| Command | What it does |
|---|---|
| `jspeaker devices` | every speaker, including ones a card is hiding |
| `jspeaker profile init \| sync \| show \| set` | read and edit the tuning profile |
| `jspeaker card unlock <card> [--verify] \| revert \| list` | expose hidden outputs (verified), and put them back |
| `jspeaker calibrate [--mic M] [--volume N]` | measure the group with a microphone |
| `jspeaker calibrate --probe <sink>` | measure one output alone; changes nothing |
| `jspeaker profile forget \| unhide` | drop an output from the group, or bring hidden ones back |
| `jspeaker profile suggest` | apply the roles calibration worked out |
| `jspeaker profile pos <key> <x> <y>` | place a speaker on the stage |
| `jspeaker levels` | stream live per-speaker output levels as JSON |
| `jspeaker tune [description] [--no-ai]` | turn measurements into a tuning |
| `jspeaker apply \| stop \| restart \| status` | drive the audio graph |

## Safety

Multi-speaker routing has one way to genuinely hurt someone: a fan-out loopback
whose playback lands back on the virtual sink feeds that sink its own monitor,
and the result is a feedback squeal at whatever volume is set. Three things
prevent it — loopbacks are created with `node.dont-reconnect=true` so a
vanishing target cannot bounce them to the default sink, the virtual sink is
refused as a speaker, and every status refresh actively checks for the loop and
breaks it on sight.

Calibration turns your microphone gain down to get headroom (laptop mics
commonly clip on room noise alone at 100%) and restores both mic and speaker
volumes afterward, including on failure.

## Notes on other software

**EasyEffects** moves playback streams into its own sink. That used to capture
Jetti Speaker's fan-out loopbacks, so this plugin no longer lets the session
manager place them at all: each loopback is created with
`node.autoconnect=false` and its ports are linked onto the target sink
explicitly. An explicit link cannot be intercepted, so the route is always what
the profile says.

Because of that, **pointing EasyEffects' output at Jetti Speaker is the right
setup** — its processing then applies to everything before the group fans it
out, and it can no longer pull a loopback into a loop. (An earlier version of
this README said the opposite. That warning was correct only while the
loopbacks were session-placed; the explicit-link change removed the hazard.)

One thing to know: if EasyEffects is aimed at a sink that stops existing — say
the group is renamed — it keeps running with nothing connected to its output and
every application playing through it goes silent. Restarting EasyEffects makes
it re-resolve to the current default sink.

## Requirements

PipeWire (`pw-loopback`, `pw-play`, `pw-record`), `pactl`, `jq`, `python3`,
and `alsa-utils` for `aplay -l`. No Python packages are required — the DSP is
standard library only. `python-numpy`, if installed, is used automatically and
makes calibration faster.

## Maintaining it

[`docs/ENGINEERING-NOTES.md`](docs/ENGINEERING-NOTES.md) records why the plugin
is built this way and the traps that cost time building it — the Quickshell
property that silently stops a panel from ever opening, the compile cache that
reproduces fixed errors, why playback streams are linked by hand, and why a
value passing a range check is not the same as a value being justified.

## Tests

```bash
./tests/run
```

66 checks covering the measurement maths (against signals with known answers),
validation of agent-proposed tunings (including the 844.9 ms regression),
device detection (against a captured hardware topology, no audio hardware
needed), and the shared display logic. Nothing in the suite plays sound,
touches the audio graph, or needs a network.
