#!/usr/bin/env python3
"""Device detection against a captured topology (no hardware needed)."""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
env = dict(os.environ, PATH=os.path.join(HERE, "fixtures") + os.pathsep + os.environ["PATH"])

out = subprocess.run([os.path.join(ROOT, "bin", "jspeaker-devices")],
                     capture_output=True, text=True, env=env)
assert out.returncode == 0, "jspeaker-devices failed: %s" % out.stderr
data = json.loads(out.stdout)
by_label = {s["label"]: s for s in data["speakers"]}
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


check("finds the Bluetooth speaker", "SK010" in by_label)
check("finds the built-in speakers", "Speakers (built-in)" in by_label)

# The whole point of the "locked" concept: hardware that is present and
# connected but hidden by the card's active profile.
screen = by_label.get("LC49G95T (screen)")
check("finds the screen behind a card profile", screen is not None)
if screen:
    check("screen is reported as locked", screen["state"] == "locked", screen["state"])
    check("screen offers pro-audio to unlock",
          screen["unlock"]["profile"] == "pro-audio", screen["unlock"]["profile"])
    check("pro-audio unlock costs no other output",
          screen["unlock"]["sacrifices"] == [], screen["unlock"]["sacrifices"])

# Our own virtual sink must never be offered as a speaker; feeding it back into
# itself is the one configuration that produces a feedback squeal.
check("never offers its own virtual sink",
      not any("jetti_speaker" in (s.get("sink") or "") for s in data["speakers"]))
# A crossover is a real Audio/Sink so a loopback can feed it. Offering it as a
# speaker made the plugin add it to the profile and give it its own loopback,
# which fed that speaker a second copy of everything.
check("never offers its own crossover as a speaker",
      not any("jsxo_" in (s.get("sink") or "") for s in data["speakers"]),
      [s["label"] for s in data["speakers"] if "jsxo_" in (s.get("sink") or "")])
check("never offers the EasyEffects sink",
      not any("easyeffects" in (s.get("sink") or "") for s in data["speakers"]))
check("warns that EasyEffects is intercepting",
      any(w["id"] == "easyeffects" for w in data["warnings"]))

# A Bluetooth card's handsfree profile is the same speaker in telephone quality,
# not a second speaker.
check("hides the Bluetooth handsfree profile",
      not any("Handsfree" in s["label"] for s in data["speakers"]))

# A Bluetooth headset microphone forces the headset into duplex mode and
# mangles the sweep, so it must not be chosen for calibration.
bt_mics = [m for m in data["mics"] if m["bus"] == "bluetooth"]
check("rejects Bluetooth mics for calibration",
      all(not m["suitable"] for m in bt_mics), bt_mics)
check("offers at least one usable mic", any(m["suitable"] for m in data["mics"]))

print("\n%d/%d device checks passed" % (total - len(failures), total))
sys.exit(1 if failures else 0)
