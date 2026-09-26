#!/usr/bin/env python3
"""Synthesises the promo soundtrack (music + UI sound effects) from scratch and muxes it
into the promo mp4. No samples or third-party audio: every sound is generated here.

    python3 Tools/promo/audio.py                      # re-score docs/media/nootch-promo.mp4 in place
    python3 Tools/promo/audio.py --video silent.mp4 --out docs/media/nootch-promo.mp4
    python3 Tools/promo/audio.py --wav-only out.wav   # just write the mixed (un-normalised) wav

Timings mirror the scene cuts in promo.js (2.8 / 6.0 / 11.0 / 15.4 / 19.0 / 23.0 s).
Music runs at 120 BPM (beat 0.5 s, bar 2 s), so 6.0 / 11.0 / 19.0 / 23.0 fall on beats;
the 2.8 and 15.4 cuts are quantised to the next beat (3.0 / 15.5).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 48000
DURATION = 27.0
BEAT = 0.5
N = int(SR * DURATION)
RNG = np.random.default_rng(7)  # fixed seed: deterministic output

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
FFMPEG = os.environ.get("FFMPEG", shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def tvec(dur):
    return np.arange(int(dur * SR)) / SR


def adsr(n, a, d, s, r, sustain_len=None):
    """Piecewise-linear envelope of n samples (times in seconds)."""
    a, d, r = int(a * SR), int(d * SR), int(r * SR)
    hold = max(0, n - a - d - r) if sustain_len is None else int(sustain_len * SR)
    env = np.concatenate([
        np.linspace(0, 1, a, endpoint=False),
        np.linspace(1, s, d, endpoint=False),
        np.full(hold, s),
        np.linspace(s, 0, r),
    ])
    return np.pad(env, (0, max(0, n - len(env))))[:n]


def add(buf, sig, at):
    i = int(round(at * SR))
    if i >= len(buf):
        return
    sig = sig[: len(buf) - i]
    buf[i: i + len(sig)] += sig


def onepole_lp(x, cutoff):
    """One-pole low-pass; cutoff may be a scalar or a per-sample array."""
    c = np.broadcast_to(np.asarray(cutoff, dtype=float), x.shape)
    a = np.exp(-2 * np.pi * c / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):  # short signals only (sfx)
        acc = (1 - a[i]) * x[i] + a[i] * acc
        y[i] = acc
    return y


def fft_lowpass(x, cutoff, slope=2.0):
    """Gentle zero-phase low-pass in the frequency domain (fast for long signals)."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X /= np.sqrt(1 + (f / cutoff) ** (2 * slope))
    return np.fft.irfft(X, len(x))


def fft_highpass(x, cutoff, slope=2.0):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR) + 1e-9
    X /= np.sqrt(1 + (cutoff / f) ** (2 * slope))
    return np.fft.irfft(X, len(x))


def reverb(x, seconds=1.8, predelay=0.012, seed=3):
    """Convolution with a synthetic, darkened exponentially-decaying noise tail."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-6.9 * t / seconds)
    ir = fft_lowpass(ir, 4500)
    ir = np.concatenate([np.zeros(int(predelay * SR)), ir])
    ir /= np.sqrt(np.sum(ir ** 2))
    size = 1 << int(np.ceil(np.log2(len(x) + len(ir))))
    y = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)
    return y[: len(x)]


# ---------------- instruments ----------------

def warm_tone(freq, dur, harmonics=9, detune_cents=(-7, 0, 7), bright=1.6):
    """Band-limited saw-ish tone: additive harmonics with rolled-off amplitude, detuned voices."""
    t = tvec(dur)
    out = np.zeros_like(t)
    for c in detune_cents:
        f = freq * 2 ** (c / 1200)
        ph = RNG.uniform(0, 2 * np.pi)
        for k in range(1, harmonics + 1):
            if f * k > SR / 2.2:
                break
            out += np.sin(2 * np.pi * f * k * t + ph * k) / k ** bright
    return out / len(detune_cents)


def pad_chord(notes, dur):
    n = int(dur * SR)
    env = adsr(n, 0.35, 0.4, 0.8, 0.9)
    left = sum(warm_tone(hz(m), dur, detune_cents=(-9, 3)) for m in notes)
    right = sum(warm_tone(hz(m), dur, detune_cents=(-3, 9)) for m in notes)
    return left * env / len(notes), right * env / len(notes)


def bass_note(midi, dur):
    t = tvec(dur)
    f = hz(midi)
    sig = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) + 0.12 * np.sin(6 * np.pi * f * t)
    return np.tanh(1.4 * sig) * adsr(len(t), 0.008, 0.25, 0.55, 0.12)


def kick():
    t = tvec(0.42)
    f = 46 + 80 * np.exp(-t / 0.035)
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t / 0.16)
    click = RNG.standard_normal(len(t)) * np.exp(-t / 0.0025) * 0.25
    return np.tanh(1.5 * (body + click))


def hat(open_=False):
    t = tvec(0.25 if open_ else 0.06)
    noise = fft_highpass(RNG.standard_normal(len(t)), 7000)
    return noise * np.exp(-t / (0.06 if open_ else 0.014))


def clap():
    t = tvec(0.28)
    noise = RNG.standard_normal(len(t))
    band = fft_highpass(fft_lowpass(noise, 3500), 900)
    env = np.exp(-t / 0.07)
    for off in (0.0, 0.011, 0.022):  # three smeared hits, like hand claps
        env += 0.6 * np.exp(-np.maximum(t - off, 0) / 0.006) * (t >= off)
    return band * env * 0.5


def bell(midi, dur=1.2, index=1.6, ratio=2.0, decay=0.45):
    """Soft FM electric-piano/bell pluck."""
    t = tvec(dur)
    f = hz(midi)
    env = np.exp(-t / decay) * np.minimum(1, t / 0.004)
    mod = index * np.exp(-t / 0.18) * np.sin(2 * np.pi * f * ratio * t)
    return (np.sin(2 * np.pi * f * t + mod) + 0.15 * np.sin(4 * np.pi * f * t)) * env


# ---------------- arrangement ----------------
# Sections (seconds): intro 0-3 | groove-in 3-6 | hover 6-11 | switch 11-15.5 |
# drag 15.5-19 | tools 19-23 | outro 23-27.
CHORDS = {  # IV - V - iii - vi in C, one chord per 2 s bar
    "F": ([53, 57, 60, 64], 41),
    "G": ([55, 59, 62, 64], 43),
    "Em": ([52, 55, 59, 62], 40),
    "Am": ([57, 60, 64, 67], 45),
    "C": ([48, 52, 55, 59, 62], 36),
}
CYCLE = ["F", "G", "Em", "Am"]
OUTRO = 23.0
SWING = 0.035  # off-beat eighths lag a little for a lo-fi feel


def chord_at(t):
    if t >= OUTRO:
        return "C"
    if t >= 22.0:
        return "G"  # half-bar dominant leading into the outro chord
    return CYCLE[int(t // 2.0) % 4]


def section(t):
    for name, end in (("intro", 3.0), ("groove", 6.0), ("hover", 11.0), ("switch", 15.5),
                      ("drag", 19.0), ("tools", 23.0)):
        if t < end:
            return name
    return "outro"


MELODY = [  # (time, midi, velocity)
    # intro: two soft notes under the title card
    (0.4, 76, .55), (1.4, 79, .5), (2.4, 81, .45),
    # hover: first phrase
    (6.0, 76, 1), (6.5, 79, .8), (7.0, 81, 1), (7.75, 79, .7), (8.0, 76, .9), (8.5, 74, .7),
    (9.0, 72, .9), (10.0, 74, .7), (10.5, 76, .8),
    # switch: answer phrase, a little higher
    (11.0, 79, 1), (11.5, 81, .8), (12.0, 84, 1), (13.0, 81, .8), (13.5, 79, .7), (14.0, 76, .9),
    (14.5, 79, .7), (15.0, 74, .8),
    # drag: sparse
    (16.0, 76, .6), (17.0, 72, .55), (18.0, 74, .6),
    # tools: rising run into the outro
    (20.5, 76, .7), (21.0, 79, .75), (21.5, 81, .8), (22.0, 84, .85), (22.5, 86, .9),
]


def music():
    L = np.zeros(N)
    R = np.zeros(N)
    pad_l, pad_r = np.zeros(N), np.zeros(N)
    bass = np.zeros(N)
    drums = np.zeros(N)
    hats_bus = np.zeros(N)
    keys_l, keys_r = np.zeros(N), np.zeros(N)

    # Pad: one chord per bar (the G at 22 s is a half bar), the outro chord rings out.
    starts = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, OUTRO]
    for i, s in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else DURATION
        notes, _ = CHORDS[chord_at(s)]
        dur = (end - s) + (0.9 if s < OUTRO else 0)
        l, r = pad_chord(notes, dur)
        add(pad_l, l, s)
        add(pad_r, r, s)

    # Eighth-note grid for bass and drums.
    for step in range(int(DURATION / (BEAT / 2))):
        t = step * BEAT / 2
        sec = section(t)
        pos = step % 8  # position within the bar in eighths
        swing = SWING if step % 2 else 0.0
        if sec in ("intro", "outro"):
            continue
        root = CHORDS[chord_at(t)][1]
        if sec != "drag" and pos in (0, 3, 4):
            add(bass, bass_note(root, 0.8 if pos != 3 else 0.3), t + swing)
        elif sec == "drag" and pos == 0:
            add(bass, bass_note(root, 1.8), t)

        if pos in (0, 3) and sec != "drag" or (sec == "drag" and pos == 0):
            add(drums, kick() * (0.8 if sec == "groove" else 1.0), t + swing)
        if pos in (2, 6) and sec in ("hover", "switch", "tools"):
            add(drums, clap() * 0.8, t)
        hat_gain = {"groove": .25, "hover": .35, "switch": .38, "drag": .3, "tools": .4}[sec]
        add(hats_bus, hat(open_=(pos == 7 and sec == "switch")) * hat_gain, t + swing)

    # Build-up: 16th claps swelling in the last half bar before the outro.
    for k in range(8):
        t = 22.0 + k * BEAT / 4
        add(drums, clap() * (0.15 + 0.1 * k), t)
    add(drums, kick() * 0.9, OUTRO)
    add(bass, bass_note(CHORDS["C"][1], 3.0) * adsr(int(3.0 * SR), .01, .3, .6, 1.8), OUTRO)

    for i, (t, m, v) in enumerate(MELODY):
        b = bell(m) * v
        pan = 0.35 if i % 2 else -0.35
        add(keys_l, b * (1 - pan) / 2, t)
        add(keys_r, b * (1 + pan) / 2, t)

    # Intro fade-in on the pad, then a gentle filter opening into the groove.
    t = np.arange(N) / SR
    pad_gain = np.clip(t / 1.8, 0, 1) ** 1.5 * (1 + 1.6 * np.clip((3.5 - t) / 1.0, 0, 1))
    pad_l, pad_r = pad_l * pad_gain, pad_r * pad_gain
    pad_l, pad_r = fft_lowpass(pad_l, 2600), fft_lowpass(pad_r, 2600)
    bass = fft_lowpass(bass, 900)

    dry_l = 0.16 * pad_l + 0.42 * bass + 0.55 * drums + 0.10 * hats_bus * 0.8 + 0.24 * keys_l
    dry_r = 0.16 * pad_r + 0.42 * bass + 0.55 * drums + 0.10 * hats_bus * 1.2 + 0.24 * keys_r
    send_l = 0.16 * pad_l + 0.30 * keys_l + 0.12 * drums
    send_r = 0.16 * pad_r + 0.30 * keys_r + 0.12 * drums
    L = dry_l + 0.35 * reverb(send_l, seed=3)
    R = dry_r + 0.35 * reverb(send_r, seed=4)
    return L, R


# ---------------- UI sound effects ----------------
# Times match promo.js: rail spring 4.2 s, card 6.55 s, segment clicks, drag release,
# tool tiles 19.3 + i * 0.12 s, outro icon 23.2 s.
SFX_WHOOSH = 3.95
SFX_POP = 6.55
SFX_CLICKS = [12.0, 13.0, 14.0, 15.0]
SFX_TICK = 18.25
SFX_TOOLS = [19.3 + i * 0.12 for i in range(5)]
SFX_CHIME = 23.2


def whoosh(dur=0.7):
    t = tvec(dur)
    p = t / dur
    env = np.sin(np.pi * p) ** 2 * np.exp(-1.2 * p)
    cutoff = 350 + 3600 * np.sin(np.pi * np.clip(p * 1.2, 0, 1)) ** 2
    noise = onepole_lp(onepole_lp(RNG.standard_normal(len(t)), cutoff), cutoff)
    sig = noise * env
    return sig / np.max(np.abs(sig)), p  # p drives the pan sweep


def pop():
    t = tvec(0.18)
    f = 380 + 360 * (1 - np.exp(-t / 0.02))
    ph = 2 * np.pi * np.cumsum(f) / SR
    return (np.sin(ph) + 0.2 * np.sin(2 * ph)) * np.exp(-t / 0.045) * np.minimum(1, t / 0.002)


def click():
    t = tvec(0.03)
    noise = fft_highpass(RNG.standard_normal(len(t)), 2500) * np.exp(-t / 0.0018)
    tone = np.sin(2 * np.pi * 2300 * t) * np.exp(-t / 0.004)
    return 0.5 * noise + 0.6 * tone


def tick():
    t = tvec(0.12)
    sig = np.sin(2 * np.pi * 1650 * t) + 0.3 * np.sin(2 * np.pi * 3300 * t)
    return sig * np.exp(-t / 0.028) * np.minimum(1, t / 0.0015)


def sfx():
    L = np.zeros(N)
    R = np.zeros(N)

    def put(sig, at, gain, pan=0.0):
        add(L, sig * gain * (1 - pan) / 2 * 2 ** 0.5, at)
        add(R, sig * gain * (1 + pan) / 2 * 2 ** 0.5, at)

    w, p = whoosh()
    pan = -0.1 + 0.8 * p  # sweeps toward the right edge where the rail appears
    add(L, w * 0.45 * (1 - pan) / 2 * 2 ** 0.5, SFX_WHOOSH)
    add(R, w * 0.45 * (1 + pan) / 2 * 2 ** 0.5, SFX_WHOOSH)
    put(pop(), SFX_POP, 0.30, 0.5)
    for c in SFX_CLICKS:
        put(click(), c, 0.22, 0.4)
    put(tick(), SFX_TICK, 0.22, 0.5)
    for i, (at, m) in enumerate(zip(SFX_TOOLS, [79, 81, 83, 86, 88])):
        put(bell(m, dur=0.5, index=0.8, ratio=3.0, decay=0.12), at, 0.16, -0.6 + 0.3 * i)
    for i, m in enumerate([72, 76, 79, 83, 86]):  # Cmaj9, lightly strummed
        put(bell(m, dur=3.6, index=1.1, ratio=3.5, decay=1.1), SFX_CHIME + i * 0.035, 0.10, -0.4 + 0.2 * i)
    wet_l, wet_r = reverb(L, 1.2, seed=5), reverb(R, 1.2, seed=6)
    return L + 0.25 * wet_l, R + 0.25 * wet_r


# ---------------- mix, loudness, mux ----------------

def mix():
    ml, mr = music()
    peak = max(np.max(np.abs(ml)), np.max(np.abs(mr)))
    ml, mr = ml / peak, mr / peak
    sl, sr = sfx()
    L, R = ml + sl, mr + sr
    t = np.arange(N) / SR
    fade = np.clip((DURATION - t) / 0.5, 0, 1)  # follows the 0.5 s picture fade to black
    L, R = L * fade, R * fade
    peak = max(np.max(np.abs(L)), np.max(np.abs(R)))
    gain = 10 ** (-3 / 20) / peak  # -3 dBFS headroom before loudnorm
    return np.stack([L * gain, R * gain], axis=1)


def write_wav(path, stereo):
    pcm = np.round(np.clip(stereo, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"


def measure(wav):
    err = subprocess.run([FFMPEG, "-hide_banner", "-i", wav, "-af", LOUDNORM + ":print_format=json",
                          "-f", "null", "-"], capture_output=True, text=True).stderr
    return json.loads(err[err.rindex("{"): err.rindex("}") + 1])


def mux(video, wav, out):
    m = measure(wav)
    af = (f"{LOUDNORM}:measured_I={m['input_i']}:measured_TP={m['input_tp']}"
          f":measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}"
          f":offset={m['target_offset']}:linear=true,aresample=48000")
    tmp = out + ".tmp.mp4"
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", video, "-i", wav,
                    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-af", af,
                    "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                    "-t", str(DURATION), "-movflags", "+faststart", tmp], check=True)
    os.replace(tmp, out)


def main():
    default = os.path.join(REPO, "docs/media/nootch-promo.mp4")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", default=default, help="mp4 whose video stream is kept (copied)")
    ap.add_argument("--out", default=default, help="output mp4 (may equal --video)")
    ap.add_argument("--wav-only", metavar="WAV", help="only write the mixed wav")
    args = ap.parse_args()

    stereo = mix()
    if args.wav_only:
        write_wav(args.wav_only, stereo)
        print(args.wav_only)
        return
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "promo-audio.wav")
        write_wav(wav, stereo)
        mux(args.video, wav, args.out)
    print(f"{args.out}  {os.path.getsize(args.out) / 1024 / 1024:.2f} MB")


if __name__ == "__main__":
    sys.exit(main())
