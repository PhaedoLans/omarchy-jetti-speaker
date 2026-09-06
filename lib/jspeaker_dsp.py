"""Signal generation and measurement for Jetti Speaker calibration.

The measurement problem
-----------------------
We want, for each speaker, how long sound takes to reach the listener and how
loud each frequency band arrives. The obstacle is that `pw-play` and
`pw-record` do not start at the same instant and the offset between them is
both unknown and different every run -- so a naive "play a sweep, time it"
measures the software start jitter, not the speaker.

The fix is to never measure a speaker alone. Every speaker's sweep lives in one
multichannel file played through one stream, so all sweeps share a single
unknown start offset T0. For speaker i emitted at known time e_i, the recorded
arrival is  a_i = T0 + e_i + flight_i.  Subtracting the known e_i leaves
T0 + flight_i, and because T0 is identical for every speaker it cancels the
moment we compare speakers to each other -- which is all a delay alignment
needs.

Everything here runs on the standard library. numpy is used when present purely
for speed; results are the same either way.
"""

import cmath
import math
import struct
import wave

try:
    import numpy as _np
except ImportError:
    _np = None

SAMPLE_RATE = 48000
SWEEP_F0 = 100.0
SWEEP_F1 = 12000.0
SWEEP_SECONDS = 1.0
SLOT_SECONDS = 2.0      # one sweep plus room decay before the next speaker
LEAD_SECONDS = 1.0      # silence before the first sweep, for level settling
TAIL_SECONDS = 1.0
AMPLITUDE = 0.32

# Delay estimation runs on a decimated copy. 12 kHz still resolves 83 us, which
# is 2.8 cm of air -- far finer than anyone can place a speaker, and ~16x less
# arithmetic than correlating at the full rate.
DECIM = 4
DECIM_RATE = SAMPLE_RATE // DECIM

OCTAVE_BANDS = (125, 250, 500, 1000, 2000, 4000, 8000)


# --------------------------------------------------------------------------
# generation
# --------------------------------------------------------------------------

def exponential_sweep(seconds=SWEEP_SECONDS, f0=SWEEP_F0, f1=SWEEP_F1,
                      rate=SAMPLE_RATE, amplitude=AMPLITUDE):
    """An exponential sine sweep, faded at both ends.

    Exponential (rather than linear) so energy per octave is constant: a small
    laptop speaker is not asked to spend most of the sweep reproducing bass it
    does not have, and the low end still gets enough excitation to measure.
    """
    n = int(seconds * rate)
    k = math.log(f1 / f0)
    out = [0.0] * n
    fade = max(1, int(0.01 * rate))
    for i in range(n):
        t = i / rate
        phase = 2.0 * math.pi * f0 * seconds / k * (math.exp(t * k / seconds) - 1.0)
        env = 1.0
        if i < fade:
            env = i / fade
        elif i > n - fade:
            env = (n - i) / fade
        out[i] = amplitude * env * math.sin(phase)
    return out


def sweep_frequency_time(freq, seconds=SWEEP_SECONDS, f0=SWEEP_F0, f1=SWEEP_F1):
    """When during the sweep a given frequency is being produced.

    Inverting the sweep's frequency law turns "how loud is 2 kHz" into "how loud
    is the recording 0.43 s after the sweep started", which is a windowed RMS
    rather than a transform.
    """
    if freq <= f0:
        return 0.0
    if freq >= f1:
        return seconds
    return seconds * math.log(freq / f0) / math.log(f1 / f0)


def write_multichannel_wav(path, channel_signals, rate=SAMPLE_RATE):
    """Interleave one signal per speaker into a single 16-bit WAV."""
    channels = len(channel_signals)
    length = max(len(c) for c in channel_signals)
    frames = bytearray()
    for i in range(length):
        for c in channel_signals:
            v = c[i] if i < len(c) else 0.0
            v = max(-1.0, min(1.0, v))
            frames += struct.pack("<h", int(v * 32767))
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


def build_calibration_signal(speaker_count, rate=SAMPLE_RATE):
    """One channel per speaker; speaker i sweeps alone in its own time slot.

    Returns (channels, emission_times) where emission_times[i] is when speaker
    i's sweep begins, measured from the start of the file.
    """
    sweep = exponential_sweep(rate=rate)
    total = int((LEAD_SECONDS + speaker_count * SLOT_SECONDS + TAIL_SECONDS) * rate)
    channels = [[0.0] * total for _ in range(speaker_count)]
    emissions = []
    for i in range(speaker_count):
        start_t = LEAD_SECONDS + i * SLOT_SECONDS
        start = int(start_t * rate)
        for j, v in enumerate(sweep):
            if start + j < total:
                channels[i][start + j] = v
        emissions.append(start_t)
    return channels, emissions


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------

def read_wav_mono(path):
    """Read a WAV as one mono float track, averaging channels if need be."""
    with wave.open(path, "rb") as w:
        channels, width, rate, frames = (
            w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        )
        raw = w.readframes(frames)
    if width != 2:
        raise ValueError("expected 16-bit PCM, got %d-byte samples" % width)
    count = len(raw) // 2
    if _np is not None:
        data = _np.frombuffer(raw, dtype="<i2").astype("float64") / 32768.0
        if channels > 1:
            usable = (len(data) // channels) * channels
            data = data[:usable].reshape(-1, channels).mean(axis=1)
        return data.tolist(), rate
    samples = struct.unpack("<%dh" % count, raw[: count * 2])
    if channels > 1:
        mono = []
        for i in range(0, len(samples) - channels + 1, channels):
            mono.append(sum(samples[i:i + channels]) / (channels * 32768.0))
        return mono, rate
    return [s / 32768.0 for s in samples], rate


# --------------------------------------------------------------------------
# transforms
# --------------------------------------------------------------------------

def _next_pow2(n):
    p = 1
    while p < n:
        p <<= 1
    return p


def _fft(a, inverse=False):
    """Iterative radix-2 Cooley-Tukey, used only when numpy is absent."""
    n = len(a)
    if n & (n - 1):
        raise ValueError("length must be a power of two")
    out = list(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    length = 2
    sign = 1.0 if inverse else -1.0
    while length <= n:
        ang = sign * 2.0 * math.pi / length
        wl = cmath.exp(complex(0.0, ang))
        for i in range(0, n, length):
            w = complex(1.0, 0.0)
            half = length >> 1
            for k in range(half):
                u = out[i + k]
                v = out[i + k + half] * w
                out[i + k] = u + v
                out[i + k + half] = u - v
                w *= wl
        length <<= 1
    if inverse:
        out = [x / n for x in out]
    return out


def decimate(signal, factor=DECIM):
    """Average-and-drop decimation.

    The box average is a crude anti-alias filter, but the sweep is already
    band-limited well below the new Nyquist and we only need the arrival peak's
    position, not a clean spectrum.
    """
    if _np is not None:
        arr = _np.asarray(signal, dtype="float64")
        usable = (len(arr) // factor) * factor
        if usable == 0:
            return []
        return arr[:usable].reshape(-1, factor).mean(axis=1).tolist()
    out = []
    for i in range(0, len(signal) - factor + 1, factor):
        out.append(sum(signal[i:i + factor]) / factor)
    return out


def matched_filter_peak(segment, reference):
    """Offset, in samples into `segment`, where `reference` best lines up.

    A matched filter (correlation against the sweep) rather than a raw envelope
    threshold, so a quiet speaker measured against room noise still produces an
    unambiguous peak. Returns (offset, peak_value, confidence) where confidence
    is the peak's height over the correlation's own mean -- a flat correlation
    means nothing was heard, and the caller should say so instead of reporting
    a number.
    """
    n = _next_pow2(len(segment) + len(reference))
    if _np is not None:
        seg = _np.zeros(n); seg[: len(segment)] = segment
        ref = _np.zeros(n); ref[: len(reference)] = reference
        corr = _np.fft.irfft(_np.fft.rfft(seg) * _np.conj(_np.fft.rfft(ref)), n)
        corr = _np.abs(corr[: len(segment)])
        idx = int(_np.argmax(corr))
        peak = float(corr[idx])
        mean = float(_np.mean(corr)) or 1e-12
        return idx, peak, peak / mean

    seg = [complex(x, 0.0) for x in segment] + [0j] * (n - len(segment))
    ref = [complex(x, 0.0) for x in reference] + [0j] * (n - len(reference))
    S, R = _fft(seg), _fft(ref)
    prod = [S[i] * R[i].conjugate() for i in range(n)]
    corr = _fft(prod, inverse=True)
    mags = [abs(c) for c in corr[: len(segment)]]
    idx = max(range(len(mags)), key=mags.__getitem__)
    peak = mags[idx]
    mean = (sum(mags) / len(mags)) or 1e-12
    return idx, peak, peak / mean


def rms(signal):
    if not signal:
        return 0.0
    if _np is not None:
        return float(_np.sqrt(_np.mean(_np.square(_np.asarray(signal)))))
    return math.sqrt(sum(v * v for v in signal) / len(signal))


def db(value, floor=-90.0):
    if value <= 1e-9:
        return floor
    return max(floor, 20.0 * math.log10(value))


def band_power_db(window, low_hz, high_hz, rate=SAMPLE_RATE):
    """Energy between two frequencies, in dB.

    A plain RMS of the time window would measure *everything* in it -- room
    noise across the whole spectrum, plus the speaker's own distortion
    harmonics. For a band the speaker cannot actually reproduce that reads back
    as the noise floor rather than as silence, which makes every speaker look
    equally capable of bass and destroys the comparison the roles depend on.
    Transforming first and summing only the bins inside the band measures what
    the speaker really put out at those frequencies.
    """
    n = _next_pow2(len(window))
    if n < 64:
        return -90.0
    if _np is not None:
        spec = _np.abs(_np.fft.rfft(_np.asarray(window, dtype="float64"), n))
        freqs = _np.fft.rfftfreq(n, 1.0 / rate)
        mask = (freqs >= low_hz) & (freqs <= high_hz)
        if not mask.any():
            return -90.0
        power = float(_np.sum(spec[mask] ** 2))
    else:
        padded = [complex(v, 0.0) for v in window] + [0j] * (n - len(window))
        spec = _fft(padded)
        lo = max(1, int(low_hz * n / rate))
        hi = min(n // 2, int(high_hz * n / rate))
        if hi <= lo:
            return -90.0
        power = sum(abs(spec[i]) ** 2 for i in range(lo, hi + 1))
    # Normalise by transform length so the figure is comparable between bands.
    return round(db(math.sqrt(power) / n), 2)


def band_response(recording, arrival_sample, rate=SAMPLE_RATE):
    """Level in each octave band, read off the sweep's own time/frequency map.

    The sweep visits each frequency at a known moment, so the window is placed
    where the band is being produced -- then only that band's bins are counted.
    """
    out = {}
    for band in OCTAVE_BANDS:
        if band >= SWEEP_F1:
            continue
        low, high = band / 1.414, band * 1.414
        # Long enough to resolve the band (a 125 Hz band needs several cycles),
        # short enough that the sweep has not moved far past it.
        span = max(0.04, 6.0 / low)
        start_t = sweep_frequency_time(max(SWEEP_F0, low))
        end_t = sweep_frequency_time(min(SWEEP_F1 - 1, high))
        centre = arrival_sample + int(((start_t + end_t) / 2.0) * rate)
        half = int(span * rate / 2)
        start = max(0, centre - half)
        end = min(len(recording), centre + half)
        if end - start < 64:
            continue
        out[str(band)] = band_power_db(recording[start:end], low, high, rate)
    return out
