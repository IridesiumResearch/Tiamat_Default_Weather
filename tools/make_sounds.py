# SPDX-License-Identifier: MIT
"""Generates the weather sounds for mods/tiamot_weather/sounds.

Placeholders, synthesised from filtered noise and written with the standard
library's `wave` module, so each file is exactly one `fmt ` chunk and one
`data` chunk, which is what the engine's strict WAV reader wants.

- rain.wav     a seamless loop: pink-ish hiss with scattered drops
- wind.wav     a seamless loop: low noise swelling in slow gusts
- thunder.wav  a one-shot: a crack, then a long low rumble

The loops are seamless because the last half second is cross-faded into the
first. Run from the repository root:

    python tools/make_sounds.py
"""
import math
import random
import struct
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "mods" / "tiamot_weather" / "sounds"
RATE = 22050


def write(name, samples):
    OUT.mkdir(parents=True, exist_ok=True)
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = 0.85 / peak
    with wave.open(str(OUT / f"{name}.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s * scale)) * 32000)) for s in samples))
    print("wrote", name, f"{len(samples) / RATE:.1f}s")


def lowpass(samples, cutoff):
    a = 1.0 - math.exp(-2.0 * math.pi * cutoff / RATE)
    y = 0.0
    out = []
    for s in samples:
        y += a * (s - y)
        out.append(y)
    return out


def highpass(samples, cutoff):
    low = lowpass(samples, cutoff)
    return [s - l for s, l in zip(samples, low)]


def loop(samples, fade_seconds=0.5):
    """Cross-fades the tail into the head, so the file repeats without a seam."""
    n = int(RATE * fade_seconds)
    body = samples[:-n]
    tail = samples[-n:]
    for i in range(n):
        t = i / n
        body[i] = body[i] * t + tail[i] * (1.0 - t)
    return body


def rain(rng, length=8.0):
    n = int(RATE * length) + int(RATE * 0.5)
    white = [rng.uniform(-1, 1) for _ in range(n)]
    hiss = highpass(lowpass(white, 5000), 400)
    out = [s * 0.5 for s in hiss]
    # Drops: short damped clicks, a few hundred a second.
    for _ in range(int(length * 260)):
        at = rng.randrange(n - 400)
        gain = rng.uniform(0.1, 0.5)
        freq = rng.uniform(1800, 4200)
        for k in range(300):
            out[at + k] += gain * math.exp(-k / 40.0) * math.sin(2 * math.pi * freq * k / RATE)
    return loop(out)


def wind(rng, length=10.0):
    n = int(RATE * length) + int(RATE * 0.5)
    white = [rng.uniform(-1, 1) for _ in range(n)]
    body = lowpass(lowpass(white, 500), 700)
    out = []
    for i, s in enumerate(body):
        t = i / RATE
        gust = 0.6 + 0.4 * math.sin(2 * math.pi * t / 3.7) * math.sin(2 * math.pi * t / 5.3 + 1.0)
        out.append(s * gust)
    return loop(out)


def thunder(rng, length=5.0):
    n = int(RATE * length)
    white = [rng.uniform(-1, 1) for _ in range(n)]
    crack = highpass(white, 800)
    rumble = lowpass(lowpass(white, 120), 160)
    out = []
    for i in range(n):
        t = i / RATE
        c = crack[i] * math.exp(-t / 0.06) * 0.8
        swell = min(1.0, t / 0.15) * math.exp(-t / 1.6)
        wobble = 0.7 + 0.3 * math.sin(2 * math.pi * t * 1.3)
        out.append(c + rumble[i] * swell * wobble * 6.0)
    return out


def main():
    rng = random.Random(20260916)
    write("rain", rain(rng))
    write("wind", wind(rng))
    write("thunder", thunder(rng))


if __name__ == "__main__":
    main()
