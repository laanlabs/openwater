# A quiet, royalty-free bed: a slow four-chord pad under shaped brown noise that breathes like surf.
import numpy as np, wave, struct
SR, DUR = 48000, 152.0
t = np.arange(int(SR * DUR)) / SR
rng = np.random.default_rng(7)

def note(n):  # MIDI -> Hz
    return 440.0 * 2 ** ((n - 69) / 12)
chords = [[50, 54, 57, 61], [47, 50, 54, 57], [43, 47, 50, 54], [45, 49, 52, 55]]  # Dmaj7 Bm7 Gmaj7 A7
pad = np.zeros_like(t)
CH = 10.0
for i, ch in enumerate(chords * int(DUR / (CH * 4) + 2)):
    start = i * CH
    if start >= DUR: break
    seg = (t >= start) & (t < start + CH + 3.0)
    tt = t[seg] - start
    env = np.clip(tt / 3.0, 0, 1) * np.clip((CH + 3.0 - tt) / 3.0, 0, 1)
    env = env ** 1.5
    for n in ch:
        f = note(n)
        for det in (-0.004, 0.0, 0.004):
            pad[seg] += env * np.sin(2 * np.pi * f * (1 + det) * tt + rng.uniform(0, 6.28)) * 0.012
        pad[seg] += env * np.sin(2 * np.pi * f * 2.0 * tt) * 0.003
# surf: brown noise, dulled, swelling every ~9 s
white = rng.standard_normal(len(t))
brown = np.cumsum(white); brown -= np.convolve(brown, np.ones(4800) / 4800, mode="same")
brown /= np.abs(brown).max()
k = 160; brown = np.convolve(brown, np.ones(k) / k, mode="same")
swell = 0.35 + 0.65 * (0.5 - 0.5 * np.cos(2 * np.pi * t / 9.0)) ** 2
surf = brown * swell * 0.16
mix = pad + surf
fade = np.minimum(1, t / 2.5) * np.minimum(1, (DUR - t) / 5.0)
mix *= fade
mix /= np.abs(mix).max() / 0.5
# gentle stereo: surf wider than pad
left = np.clip(mix + surf * 0.05, -1, 1); right = np.clip(mix - surf * 0.05, -1, 1)
pcm = np.empty(len(t) * 2, dtype=np.int16); pcm[0::2] = (left * 32767).astype(np.int16); pcm[1::2] = (right * 32767).astype(np.int16)
with wave.open("bed.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print("bed.wav", DUR, "s")
