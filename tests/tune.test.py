#!/usr/bin/env python3
"""Validation of agent-proposed tunings.

These are regression tests for a real failure: the model was handed a null
arrival time for a speaker that had never been heard, computed "latest arrival
minus zero", and proposed an 844.9 ms delay. Range-clamping accepted it, because
844.9 ms is a legal number. The result was a group with almost a second of
delay on two of three speakers.
"""
import importlib.machinery
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.join(os.path.dirname(HERE), "bin")
loader = importlib.machinery.SourceFileLoader("jspeakertune", os.path.join(BIN, "jspeaker-tune"))
spec = importlib.util.spec_from_loader("jspeakertune", loader)
tune = importlib.util.module_from_spec(spec)
loader.exec_module(tune)

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


def profile():
    return {"speakers": [
        {"key": "heard", "label": "Measured speaker", "enabled": True, "sink": "s1",
         "channel": "stereo", "gain": 1.0, "delayMs": 0.0,
         "measured": {"heard": True, "relativeMs": 300.0, "levelDb": -20.0}},
        {"key": "unheard", "label": "Never heard", "enabled": True, "sink": "s2",
         "channel": "stereo", "gain": 1.0, "delayMs": 0.0,
         "measured": {"heard": False}},
    ]}


def apply(sug, prof=None):
    prof = prof or profile()
    applied, rejected = tune.apply_suggestion(prof, sug, "test")
    return prof, rejected


def by_key(prof, key):
    return next(s for s in prof["speakers"] if s["key"] == key)


# The core regression.
prof, rejected = apply({"speakers": [
    {"key": "heard", "channel": "stereo", "gain": 1.0, "delayMs": 0.0},
    {"key": "unheard", "channel": "stereo", "gain": 1.0, "delayMs": 844.9},
]})
check("a delay for an unheard speaker is refused", by_key(prof, "unheard")["delayMs"] == 0.0,
      by_key(prof, "unheard")["delayMs"])
check("the refusal is reported", any("never heard" in r for r in rejected), rejected)

prof, _ = apply({"speakers": [{"key": "heard", "channel": "stereo",
                               "gain": 1.0, "delayMs": 240.3}]})
check("a delay for a measured speaker is kept", by_key(prof, "heard")["delayMs"] == 240.3)

# Ranges. A delay past the cap would ask PipeWire for an enormous buffer.
prof, _ = apply({"speakers": [{"key": "heard", "channel": "stereo",
                               "gain": 1.0, "delayMs": 999999}]})
check("an absurd delay is clamped", by_key(prof, "heard")["delayMs"] == tune.DELAY_MAX)
prof, _ = apply({"speakers": [{"key": "heard", "channel": "stereo",
                               "gain": 99, "delayMs": 0}]})
check("gain is clamped to group", by_key(prof, "heard")["gain"] == tune.GAIN_MAX)
prof, _ = apply({"speakers": [{"key": "heard", "channel": "stereo",
                               "gain": -5, "delayMs": 0}]})
check("gain has a floor", by_key(prof, "heard")["gain"] == tune.GAIN_MIN)

# Garbage in from a model that ignored the contract.
for bad in (None, "nonsense", float("nan")):
    prof, _ = apply({"speakers": [{"key": "heard", "channel": "stereo",
                                   "gain": bad, "delayMs": bad}]})
    check("non-numeric gain/delay (%r) falls back" % (bad,),
          by_key(prof, "heard")["gain"] == 1.0 and by_key(prof, "heard")["delayMs"] == 0.0)

prof, rejected = apply({"speakers": [{"key": "heard", "channel": "diagonal",
                                      "gain": 1.0, "delayMs": 0}]})
check("an invalid channel role is rejected", by_key(prof, "heard")["channel"] == "stereo")
check("the bad role is reported", any("bad channel" in r for r in rejected), rejected)

prof, rejected = apply({"speakers": [{"key": "ghost", "channel": "stereo",
                                      "gain": 1.0, "delayMs": 0}]})
check("an unknown speaker key is rejected", any("unknown speaker" in r for r in rejected))

# A one-sided split would silently drop the other channel entirely.
prof, rejected = apply({"speakers": [
    {"key": "heard", "channel": "left", "gain": 1.0, "delayMs": 0},
    {"key": "unheard", "channel": "stereo", "gain": 1.0, "delayMs": 0},
]})
check("a one-sided left/right split is undone",
      by_key(prof, "heard")["channel"] == "stereo")
check("the one-sided split is reported", any("one-sided" in r for r in rejected))

prof, _ = apply({"speakers": [
    {"key": "heard", "channel": "left", "gain": 1.0, "delayMs": 0},
    {"key": "unheard", "channel": "right", "gain": 1.0, "delayMs": 0},
]})
check("a paired left/right split is kept",
      (by_key(prof, "heard")["channel"], by_key(prof, "unheard")["channel"]) == ("left", "right"))

# The payload must not hand the model a null to do arithmetic on.
payload = tune.build_payload(profile(), "a room")
unheard = next(s for s in payload["speakers"] if s["key"] == "unheard")
check("unheard speakers carry no arrival figure", "measuredArrivalMs" not in unheard, unheard)
check("unheard speakers are explained to the model", "note" in unheard)
heard = next(s for s in payload["speakers"] if s["key"] == "heard")
check("heard speakers carry their arrival", heard.get("measuredArrivalMs") == 300.0)

print("\n%d/%d tune checks passed" % (total - len(failures), total))
sys.exit(1 if failures else 0)
