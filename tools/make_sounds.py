# SPDX-FileCopyrightText: Iridesium
# SPDX-License-Identifier: GPL-3.0-only
"""Generates the weather sounds for mods/tiamat_weather/sounds.

Placeholders, synthesised from filtered noise and written with the standard
library's `wave` module, so each file is exactly one `fmt ` chunk and one
`data` chunk, which is what the engine's strict WAV reader wants.

- rain.wav     a seamless loop: pink-ish hiss with scattered drops
- wind.wav     a seamless loop: low noise swelling in slow gusts
- thunder.wav  a one-shot: a crack, then a long low rumble
- fire.wav     a seamless loop: a low rumble under sparse sharp pops
- douse.wav    a one-shot: a hiss dying over a second, a soft thud under it

The loops are seamless because the last half second is cross-faded into the
first. Run from the repository root:

    python tools/make_sounds.py
"""
import math
import random
import struct
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "mods" / "tiamat_weather" / "sounds"
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


def flutter(rng, n, rate):
    """A smooth random envelope in [0, 1], wandering about `rate` times a
    second: what makes a flame's roar and a jet of steam uneven rather than a
    steady hiss. Low-passed noise, brought back up to a unit peak."""
    rough = lowpass(lowpass([rng.uniform(-1, 1) for _ in range(n)], rate), rate)
    peak = max(1e-9, max(abs(s) for s in rough))
    return [0.5 + 0.5 * s / peak for s in rough]


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


def fire(rng, length=6.0):
    """A blaze heard from a few blocks off: a bed of low rumble with the
    uneven roar of flame over it, and pops on top — sparse, sharp, none of
    them alike, which is what says "burning wood" rather than "static"."""
    n = int(RATE * length) + int(RATE * 0.5)
    white = [rng.uniform(-1, 1) for _ in range(n)]
    # Two poles at 300 Hz make a rumble rather than a hiss; it breathes on two
    # slow cycles that never line up, so the bed does not audibly repeat.
    rumble = lowpass(lowpass(white, 300), 300)
    # The roar of the flames themselves sits in the low mids and gutters —
    # a random flutter a few times a second, not a steady tone.
    roar = highpass(lowpass(white, 1500), 400)
    gutter = flutter(rng, n, 4.0)
    # The bed is kept well under the pops — `write` normalises to the peak,
    # and if the rumble's own peaks set it the crackle is buried in it.
    out = []
    for i in range(n):
        t = i / RATE
        breath = 0.75 + 0.25 * math.sin(2 * math.pi * t / 1.9) * math.sin(2 * math.pi * t / 3.1 + 0.7)
        out.append(rumble[i] * breath * 2.5 + roar[i] * (0.3 + 0.7 * gutter[i]) * 0.1)
    # Pops: six to twelve a second with uneven gaps, each a few milliseconds
    # of high-passed noise with a hard start and a fast decay. The gain curve
    # leans low so most pops are small and a few crack out over the rest, but
    # its floor keeps every one audible over the bed; about a third ring at a
    # woody pitch, which is the snap of a knot going.
    at = 0
    while True:
        at += int(RATE * rng.uniform(1 / 12, 1 / 6))
        decay = rng.uniform(12.0, 60.0)              # samples: half a millisecond to three
        span = int(decay * 6)
        if at + span >= n:
            break
        u = rng.uniform(0.0, 1.0)
        gain = 0.3 + 0.7 * u * u
        rings = rng.random() < 0.35
        freq = rng.uniform(1500, 4500)
        burst = highpass([rng.uniform(-1, 1) for _ in range(span)], 2500)
        for k in range(span):
            v = burst[k] * math.exp(-k / decay)
            if rings:
                v += 0.6 * math.exp(-k / (decay * 2.5)) * math.sin(2 * math.pi * freq * k / RATE)
            out[at + k] += gain * v * 2.4
    return loop(out)


def douse(rng, length=1.2):
    """Water meeting fire, once: a jet of steam that starts at full and dies
    away over a second, sputtering as it goes, with a soft low thud under its
    first instant — the splash, felt more than heard."""
    n = int(RATE * length)
    white = [rng.uniform(-1, 1) for _ in range(n)]
    hiss = highpass(lowpass(white, 6000), 1500)
    puff = lowpass(lowpass(white, 90), 90)
    sputter = flutter(rng, n, 25.0)
    out = []
    for i in range(n):
        t = i / RATE
        attack = min(1.0, t / 0.012)
        tail = min(1.0, (n - i) / (RATE * 0.05))      # so the file ends on silence, not a click
        h = hiss[i] * attack * math.exp(-t / 0.32) * (0.7 + 0.3 * sputter[i]) * 0.8
        # Soft means under the hiss: the steam is the sound, the thud its weight.
        thud = (math.sin(2 * math.pi * 65.0 * t) * math.exp(-t / 0.07) * 0.25
                + puff[i] * math.exp(-t / 0.1) * 4.0)
        out.append((h + thud) * tail)
    return out


def main():
    rng = random.Random(20260916)
    write("rain", rain(rng))
    write("wind", wind(rng))
    write("thunder", thunder(rng))
    # The fire sounds came a week later and draw from a stream of their own,
    # so adding them changed no byte of the three above.
    fire_rng = random.Random(20260923)
    write("fire", fire(fire_rng))
    write("douse", douse(fire_rng))


if __name__ == "__main__":
    main()
