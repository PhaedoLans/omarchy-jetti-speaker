#!/usr/bin/env python3
"""The measurement maths, checked against signals with known answers."""
import math, os, random, sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lib"))
import jspeaker_dsp as dsp

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


sweep = dsp.exponential_sweep()
check("sweep has the requested length", len(sweep) == dsp.SAMPLE_RATE)
check("sweep stays inside full scale", max(abs(v) for v in sweep) <= 1.0)
check("sweep is faded in", abs(sweep[0]) < 0.01)
check("sweep is faded out", abs(sweep[-1]) < 0.01)

# Time/frequency mapping is what the band response reads levels off.
check("sweep starts at f0", dsp.sweep_frequency_time(dsp.SWEEP_F0) == 0.0)
check("sweep ends at f1",
      abs(dsp.sweep_frequency_time(dsp.SWEEP_F1) - dsp.SWEEP_SECONDS) < 1e-9)
check("frequency mapping is monotonic",
      dsp.sweep_frequency_time(500) < dsp.sweep_frequency_time(4000))

channels, emissions = dsp.build_calibration_signal(3)
check("one channel per speaker", len(channels) == 3)
check("speakers sweep in separate slots",
      emissions == [dsp.LEAD_SECONDS,
                    dsp.LEAD_SECONDS + dsp.SLOT_SECONDS,
                    dsp.LEAD_SECONDS + 2 * dsp.SLOT_SECONDS], emissions)
# Slots must not overlap, or one speaker's sweep would be measured as another's.
check("slots are longer than the sweep", dsp.SLOT_SECONDS > dsp.SWEEP_SECONDS)

# Delay recovery: the number the whole feature depends on.
random.seed(11)
reference = dsp.decimate(sweep)
worst = 0.0
for true_ms in (0.0, 4.5, 37.0, 122.0, 233.5):
    lag = int(true_ms / 1000.0 * dsp.SAMPLE_RATE)
    seg = [random.gauss(0, 0.002) for _ in range(int(1.7 * dsp.SAMPLE_RATE))]
    for i, v in enumerate(sweep):
        if lag + i < len(seg):
            seg[lag + i] += v * 0.2
    idx, _peak, conf = dsp.matched_filter_peak(dsp.decimate(seg), reference)
    worst = max(worst, abs(idx / dsp.DECIM_RATE * 1000.0 - true_ms))
check("recovers known delays within 1 ms", worst < 1.0, "worst %.3f ms" % worst)

# Silence must not be reported as a confident measurement.
quiet = [random.gauss(0, 0.002) for _ in range(int(1.7 * dsp.SAMPLE_RATE))]
_i, _p, quiet_conf = dsp.matched_filter_peak(dsp.decimate(quiet), reference)
check("silence is not confident", quiet_conf < 40.0, "confidence %.1f" % quiet_conf)

check("dB floor is respected", dsp.db(0.0) == -90.0)
check("dB of full scale is 0", abs(dsp.db(1.0)) < 1e-9)
check("rms of silence is zero", dsp.rms([0.0] * 100) == 0.0)
check("decimation reduces rate by DECIM",
      abs(len(dsp.decimate([0.0] * 4000)) - 1000) <= 1)

# Band measurement. A broadband RMS of a time window cannot tell "this speaker
# produces no bass" from "the room is noisy"; only in-band energy can, and the
# role detection depends entirely on that distinction.
tone2k = [0.3 * math.sin(2 * math.pi * 2000 * i / dsp.SAMPLE_RATE) for i in range(4096)]
in_band = dsp.band_power_db(tone2k, 1414, 2828)
out_band = dsp.band_power_db(tone2k, 88, 177)
check("a tone registers in its own band", in_band > -30, "%.1f dB" % in_band)
check("a tone does not leak into a distant band", out_band < in_band - 25,
      "in %.1f vs out %.1f" % (in_band, out_band))

random.seed(3)
noise = [random.gauss(0, 0.01) for _ in range(4096)]
check("broadband noise does not masquerade as bass",
      dsp.band_power_db(noise, 88, 177) < -55,
      "%.1f dB" % dsp.band_power_db(noise, 88, 177))
check("an empty window is reported as silence", dsp.band_power_db([], 88, 177) == -90.0)

# A speaker with no low end must grade differently from one that has it.
rate = dsp.SAMPLE_RATE
full = [0.3 * (math.sin(2*math.pi*150*i/rate) + math.sin(2*math.pi*2000*i/rate))
        for i in range(4096)]
thin = [0.3 * math.sin(2 * math.pi * 2000 * i / rate) for i in range(4096)]
full_ratio = dsp.band_power_db(full, 88, 177) - dsp.band_power_db(full, 1414, 2828)
thin_ratio = dsp.band_power_db(thin, 88, 177) - dsp.band_power_db(thin, 1414, 2828)
check("bass-to-mid separates a full-range speaker from a thin one",
      full_ratio > thin_ratio + 20, "full %.1f vs thin %.1f" % (full_ratio, thin_ratio))

print("\n%d/%d dsp checks passed" % (total - len(failures), total))
sys.exit(1 if failures else 0)
