"""APIS-K0: monotone "AI voice" processing, numpy only.

The synthetic, GLaDOS-like quality does not come from the timbre but from the melody: a human voice glides in
pitch all the time; a machine voice holds it nearly flat and jumps in steps. So:
1. find the pitch of the voice frame by frame (YIN: de Cheveigne & Kawahara, 2002);
2. re-pitch it with TD-PSOLA (pitch-synchronous overlap-add of two-period grains): every voiced grain is placed at
   the spacing of a new, flattened pitch: the melody is squeezed towards its median ("keep" = how much is left)
   and snapped to whole semitones, then shifted by "semitones". Unvoiced sounds (s, f, t...) pass unchanged.
Timing is kept: grains are taken from the source at the same moment they are written to the output.
"""

import numpy as np

HOP_SECONDS = 0.005
FMIN, FMAX = 70.0, 600.0
YIN_THRESHOLD = 0.15


def pitch_track(x, rate):
    """f0 in Hz per hop (0 = unvoiced), and the hop size in samples."""
    hop = int(rate * HOP_SECONDS)
    tau_min, tau_max = int(rate / FMAX), int(rate / FMIN)
    width = tau_max  # integration window
    span = width + tau_max
    padded = np.concatenate([x, np.zeros(span)])
    count = max(1, (len(x) - 1) // hop + 1)
    starts = np.arange(count) * hop
    frames = np.lib.stride_tricks.sliding_window_view(padded, span)[starts]  # (count, span)
    size = 1 << int(np.ceil(np.log2(2 * span)))
    head = np.fft.rfft(frames[:, :width], size)
    full = np.fft.rfft(frames, size)
    corr = np.fft.irfft(np.conj(head) * full, size)[:, : tau_max + 1]  # sum x_j x_{j+tau}, j < width
    squares = np.concatenate([np.zeros((count, 1)), np.cumsum(frames ** 2, axis=1)], axis=1)
    energy0 = squares[:, width][:, None]
    taus = np.arange(tau_max + 1)
    energy_tau = squares[:, taus + width] - squares[:, taus]
    diff = np.maximum(energy0 + energy_tau - 2 * corr, 0.0)
    # Cumulative mean normalised difference.
    cumulative = np.cumsum(diff[:, 1:], axis=1)
    cmnd = np.ones_like(diff)
    cmnd[:, 1:] = diff[:, 1:] * taus[1:] / np.maximum(cumulative, 1e-12)
    f0 = np.zeros(count)
    loud = energy0[:, 0] > (np.max(energy0) * 1e-3)
    for i in np.nonzero(loud)[0]:
        row = cmnd[i]
        below = np.nonzero(row[tau_min:] < YIN_THRESHOLD)[0]
        if len(below) == 0:
            continue
        tau = tau_min + below[0]
        while tau + 1 <= tau_max and row[tau + 1] < row[tau]:
            tau += 1
        if 0 < tau < tau_max:  # parabolic refinement
            a, b, c = row[tau - 1], row[tau], row[tau + 1]
            shift = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
            tau = tau + float(np.clip(shift, -1, 1))
        f0[i] = rate / tau
    # Drop single-hop voiced blips and fill single-hop gaps.
    voiced = f0 > 0
    for i in range(1, count - 1):
        if voiced[i] and not voiced[i - 1] and not voiced[i + 1]:
            f0[i] = 0.0
        elif not voiced[i] and voiced[i - 1] and voiced[i + 1]:
            f0[i] = 0.5 * (f0[i - 1] + f0[i + 1])
    return f0, hop


def flatten_pitch(f0, keep, semitones, steps):
    """Target pitch per hop: deviations from the median scaled by `keep`, snapped to semitones, shifted."""
    voiced = f0 > 0
    if not voiced.any():
        return f0
    log = np.log2(np.where(voiced, f0, 1.0)) * 12.0  # in semitones
    centre = np.median(log[voiced])
    target = centre + (log - centre) * keep
    if steps:
        target = centre + np.round(target - centre)
    target += semitones
    return np.where(voiced, 2.0 ** (target / 12.0), 0.0)


BREATH_MIN_SECONDS = 0.12  # unvoiced stretches at least this long can be breaths (fricatives are shorter)
BREATH_LEVEL = 0.2  # ...and only their frames quieter than this share of the voiced level (-14 dB) are muted
BREATH_FLOOR = 0.03  # what is left of a muted frame
RAMP_SECONDS = 0.008


def breath_gate(x, rate, f0, hop):
    """Gain per sample that mutes breaths: long, quiet, unvoiced stretches. Loud fricatives (s, f, j) stay."""
    count = len(f0)
    frames = np.lib.stride_tricks.sliding_window_view(np.concatenate([x, np.zeros(2 * hop)]), 2 * hop)
    rms = np.sqrt(np.mean(frames[np.arange(count) * hop] ** 2, axis=1))
    voiced = f0 > 0
    if not voiced.any():
        return np.ones(len(x))
    reference = np.median(rms[voiced])
    gain = np.ones(count)
    min_frames = int(BREATH_MIN_SECONDS / HOP_SECONDS)
    i = 0
    while i < count:
        if voiced[i]:
            i += 1
            continue
        j = i
        while j < count and not voiced[j]:
            j += 1
        if j - i >= min_frames:
            quiet = rms[i:j] < reference * BREATH_LEVEL
            gain[i:j][quiet] = BREATH_FLOOR
        i = j
    # Per sample, with short ramps so the cuts do not click.
    per_sample = np.repeat(gain, hop)[: len(x)]
    if len(per_sample) < len(x):
        per_sample = np.concatenate([per_sample, np.full(len(x) - len(per_sample), gain[-1])])
    ramp = max(1, int(rate * RAMP_SECONDS))
    return np.convolve(per_sample, np.ones(ramp) / ramp, mode="same")


def level(x, rate, amount=0.8, window_seconds=0.03):
    """Evens out loudness (no stressed syllables): each moment is pulled towards the median speech level.
    amount: 0 = unchanged, 1 = fully flat. Silence is left alone."""
    x = np.asarray(x, dtype=np.float64)
    size = max(1, int(rate * window_seconds))
    envelope = np.sqrt(np.convolve(x ** 2, np.ones(size) / size, mode="same"))
    speech = envelope > np.max(envelope) * 0.05
    if not speech.any():
        return x.astype(np.float32)
    target = np.median(envelope[speech])
    gain = np.where(speech, (target / np.maximum(envelope, 1e-9)) ** amount, 1.0)
    gain = np.clip(gain, 0.25, 4.0)
    gain = np.convolve(gain, np.ones(size) / size, mode="same")  # no zipper noise
    return (x * gain).astype(np.float32)


def machine_voice(x, rate, keep=0.0, semitones=1.5, steps=True, remove_breaths=True, level_amount=0.8,
                  octave_mix=0.15):
    """The full flat "AI" treatment: monotone pitch, no breaths, even loudness, plus a quiet copy one octave up
    (the doubled, synthetic sheen of a computer voice)."""
    voice = monotone(x, rate, keep, semitones, steps, remove_breaths)
    if octave_mix > 0:
        upper = monotone(voice, rate, 0.0, 12.0, False, False)
        voice = voice * (1.0 - octave_mix) + upper * octave_mix
    if level_amount > 0:
        voice = level(voice, rate, level_amount)
    return voice


def monotone(x, rate, keep=0.2, semitones=0.0, steps=True, remove_breaths=True):
    """Re-pitches speech towards a flat, stepped machine melody, optionally muting breaths. x: float32 mono."""
    x = np.asarray(x, dtype=np.float64)
    if len(x) < rate // 10:
        return x.astype(np.float32)
    f0, hop = pitch_track(x, rate)
    if remove_breaths:
        x = x * breath_gate(x, rate, f0, hop)
    target = flatten_pitch(f0, keep, semitones, steps)

    def at(track, t):
        return track[min(len(track) - 1, int(t // hop))]

    # Analysis marks: one per period in voiced parts (snapped to the local peak), one per hop elsewhere.
    marks, periods = [], []
    t = 0
    smooth = np.convolve(x, np.ones(5) / 5, mode="same")
    while t < len(x):
        f = at(f0, t)
        if f > 0:
            period = int(rate / f)
            lo, hi = max(0, t - period // 4), min(len(x), t + period // 4 + 1)
            peak = lo + int(np.argmax(np.abs(smooth[lo:hi]))) if hi > lo else t
            if marks and peak <= marks[-1]:
                peak = marks[-1] + max(1, period // 2)
            marks.append(peak)
            periods.append(period)
            t = peak + period
        else:
            marks.append(t)
            periods.append(hop)
            t += hop
    marks = np.array(marks)
    periods = np.array(periods)

    out = np.zeros(len(x) + 2 * rate // 10)
    norm = np.zeros_like(out)
    t_out = float(marks[0])
    while t_out < len(x):
        i = int(np.argmin(np.abs(marks - t_out)))
        centre, period = int(marks[i]), int(periods[i])
        lo, hi = centre - period, centre + period
        if lo >= 0 and hi <= len(x):
            window = np.hanning(hi - lo)
            start = int(round(t_out)) - period
            if start >= 0:
                out[start:start + hi - lo] += x[lo:hi] * window
                norm[start:start + hi - lo] += window
        f = at(target, marks[i])
        t_out += (rate / f) if f > 0 else period
    out = out[: len(x)] / np.maximum(norm[: len(x)], 0.5)
    return out.astype(np.float32)
