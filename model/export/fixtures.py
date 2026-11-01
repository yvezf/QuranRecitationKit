"""Deterministic, non-speech diagnostic inputs. No recitation audio is used."""
import numpy as np


def named_signals():
    for samples in (16000, 32000, 48000, 192000):
        t = np.arange(samples, dtype=np.float32) / 16000
        for frequency in (110, 220, 440):
            yield f"tone-{samples}-{frequency}", {
                "audio_signal": (0.02 * np.sin(2 * np.pi * frequency * t)).astype(np.float32)[None, :],
                "length": np.array([samples], np.int64),
            }


def signals():
    for _, sample in named_signals():
        yield sample
