# A royalty-free electronic beat for the Short: 110 bpm, kick / clap / hats / bass / chord stabs, 31 s with a final hit.
import numpy as np, wave
SR, BPM = 48000, 110.0
beat = 60.0 / BPM; bar = 4 * beat
DUR = 14 * bar + 1.5
n = int(SR * DUR); t = np.arange(n) / SR
mix = np.zeros(n)
rng = np.random.default_rng(3)
def add(start, sig):
    i = int(start * SR); j = min(n, i + len(sig))
    if i < n: mix[i:j] += sig[:j - i]
def kick():
    tt = np.arange(int(0.28 * SR)) / SR
    f = 42 + 110 * np.exp(-tt * 28)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 9) * 0.9
def clap():
    tt = np.arange(int(0.18 * SR)) / SR
    noise = rng.standard_normal(len(tt))
    env = (np.exp(-tt * 30) + 0.6 * np.exp(-(tt - 0.012) * 30) * (tt > 0.012) + 0.4 * np.exp(-(tt - 0.024) * 30) * (tt > 0.024))
    k = 12; noise = np.convolve(noise, np.ones(k) / k, mode="same") - np.convolve(noise, np.ones(60) / 60, mode="same")
    return noise * env * 0.55
def hat(open_=False):
    L = int((0.16 if open_ else 0.045) * SR); tt = np.arange(L) / SR
    noise = rng.standard_normal(L); noise = noise - np.convolve(noise, np.ones(8) / 8, mode="same")
    return noise * np.exp(-tt * (12 if open_ else 70)) * (0.22 if open_ else 0.16)
def bass(freq, length):
    tt = np.arange(int(length * SR)) / SR
    env = np.minimum(1, tt / 0.01) * np.exp(-tt * 2.2)
    sig = np.sign(np.sin(2 * np.pi * freq * tt)) * 0.3 + np.sin(2 * np.pi * freq * tt) * 0.7
    k = 40; sig = np.convolve(sig, np.ones(k) / k, mode="same")
    return sig * env * 0.5
def stab(freqs, length):
    tt = np.arange(int(length * SR)) / SR
    env = np.minimum(1, tt / 0.02) * np.exp(-tt * 3.5)
    sig = sum(np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * f * 2 * tt) for f in freqs) / len(freqs)
    return sig * env * 0.22
# D minor-ish progression per bar: Dm, Bb, F, C (bass roots) and stabs
roots = [73.42, 58.27, 87.31, 65.41]
chords = [[293.7, 349.2, 440.0], [233.1, 293.7, 349.2], [349.2, 440.0, 523.3], [261.6, 329.6, 392.0]]
for b in range(14):
    t0 = b * bar
    root = roots[b % 4]; ch = chords[b % 4]
    for q in range(4):
        add(t0 + q * beat, kick())
        if q in (1, 3): add(t0 + q * beat, clap())
        for e in range(2):
            add(t0 + q * beat + e * beat / 2, hat(open_=(q == 3 and e == 1)))
    for i, frac in enumerate([0, 0.5, 0.75, 1.5, 2, 2.5, 2.75, 3.5]):
        f = root * (2 if i % 4 == 3 else 1)
        add(t0 + frac * beat, bass(f, 0.35))
    add(t0, stab(ch, 1.2)); add(t0 + 2.5 * beat, stab(ch, 0.6))
    if b in (5, 11):  # a fill before the drops
        for k in range(4): add(t0 + 3 * beat + k * beat / 4, clap() * 0.7)
# final hit on the end card, then ring out
add(14 * bar - bar * 2, kick() * 1.1); add(14 * bar - bar * 2, stab(chords[0], 2.5) * 1.6)
# intro: pull the first bar back (hats + kick only) for a cleaner hook
mix[: int(bar * SR)] *= 0.75
fade = np.minimum(1, (DUR - t) / 1.2); mix *= fade
mix = np.tanh(mix * 1.4) * 0.8
pcm = (mix * 32767).astype(np.int16)
with wave.open("assets/beat.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print("beat.wav", round(DUR, 2), "s; bar", round(bar, 3), "s")
