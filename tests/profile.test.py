#!/usr/bin/env python3
"""Profile editing rules, especially the ones that guard the audio graph."""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.join(os.path.dirname(HERE), "bin")
loader = importlib.machinery.SourceFileLoader("prof", os.path.join(BIN, "jspeaker-profile"))
spec = importlib.util.spec_from_loader("prof", loader)
prof = importlib.util.module_from_spec(spec)
loader.exec_module(prof)

failures = []
total = 0


def check(name, cond, detail=""):
    global total
    total += 1
    if cond:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        failures.append(name)


tmpdir = tempfile.mkdtemp()
prof.CONFIG = tmpdir
prof.PROFILE = os.path.join(tmpdir, "profile.json")


def write(speakers, **extra):
    d = {"version": 1, "name": "test", "speakers": speakers}
    d.update(extra)
    with open(prof.PROFILE, "w") as fh:
        json.dump(d, fh)


def read():
    with open(prof.PROFILE) as fh:
        return json.load(fh)


base = [{"key": "s1", "label": "Speaker one", "sink": "s1", "enabled": True,
         "channel": "stereo", "gain": 1.0, "delayMs": 0.0, "band": "primary",
         "crossoverHz": 800.0, "posX": 0.0, "posY": 0.4, "measured": None, "notes": ""}]

# Gain must reach the boost range: a tweeter 18 dB below the primary cannot be
# balanced within unity.
write([dict(base[0])])
prof.cmd_set(["s1", "gain", "2.8"])
check("gain accepts a boost above unity", read()["speakers"][0]["gain"] == 2.8)
write([dict(base[0])])
try:
    prof.cmd_set(["s1", "gain", "99"])
    check("absurd gain is refused", False, "accepted 99")
except SystemExit:
    check("absurd gain is refused", True)

# Position must never quietly narrow the primary to one channel.
write([dict(base[0], band="primary")])
prof.cmd_pos(["s1", "-0.95", "0.5"])
check("the primary is never narrowed by position",
      read()["speakers"][0]["channel"] == "stereo", read()["speakers"][0]["channel"])
write([dict(base[0], band="tweeter")])
prof.cmd_pos(["s1", "-0.95", "0.5"])
check("a tweeter at the edge becomes a side channel",
      read()["speakers"][0]["channel"] == "left")
write([dict(base[0], band="tweeter")])
prof.cmd_pos(["s1", "-0.6", "0.5"])
check("a nudge does not narrow anything",
      read()["speakers"][0]["channel"] == "stereo")

# Forgetting must stick, or the next sync brings the output straight back.
write([dict(base[0]), dict(base[0], key="s2", sink="s2", label="Speaker two")])
prof.cmd_forget(["s2"])
after = read()
check("forget removes the speaker", [s["key"] for s in after["speakers"]] == ["s1"])
check("forget is remembered so sync cannot undo it", after.get("ignored") == ["s2"])
try:
    prof.cmd_forget(["nope"])
    check("forgetting an unknown key errors", False)
except SystemExit:
    check("forgetting an unknown key errors", True)

# Crossover has to stay inside what a filter can sensibly do.
write([dict(base[0])])
prof.cmd_set(["s1", "crossoverHz", "1000"])
check("a sane crossover is accepted", read()["speakers"][0]["crossoverHz"] == 1000.0)
for bad in ("10", "20000"):
    write([dict(base[0])])
    try:
        prof.cmd_set(["s1", "crossoverHz", bad])
        check("crossover %s is refused" % bad, False)
    except SystemExit:
        check("crossover %s is refused" % bad, True)

write([dict(base[0])])
try:
    prof.cmd_set(["s1", "band", "subwoofer"])
    check("an unknown band is refused", False)
except SystemExit:
    check("an unknown band is refused", True)

# Redetect must be able to bring back something you removed, or the Restore
# button in the panel is offering an action that does nothing.
write([dict(base[0]), dict(base[0], key="s2", sink="s2", label="Speaker two")])
prof.cmd_forget(["s2"])
check("forgotten output is on the ignored list", read().get("ignored") == ["s2"])
prof.cmd_unhide([])
check("unhide clears the ignored list", read().get("ignored") == [])
write([dict(base[0])])
prof.cmd_unhide([])
check("unhide on a clean profile is harmless", read().get("ignored", []) == [])

# Rescanning must never change what is playing. A sink that appears while the
# group is live gets listed, not enlisted.
dev_live = {"key": "new", "sink": "new", "label": "New thing", "kind": "other",
            "state": "live"}
check("a speaker built for a fresh profile is on",
      prof.blank_speaker(dev_live, 0, 1)["enabled"] is True)
check("a speaker found by a rescan is off",
      prof.blank_speaker(dev_live, 0, 1, enabled=False)["enabled"] is False)
check("a headset is left out even of a fresh profile",
      prof.blank_speaker(dict(dev_live, kind="usb-headset"), 0, 1)["enabled"] is False)

print("\n%d/%d profile checks passed" % (total - len(failures), total))
sys.exit(1 if failures else 0)
