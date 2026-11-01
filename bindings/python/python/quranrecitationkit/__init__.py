"""Expected-text recitation tracking. PCM never leaves this machine."""
import json
from threading import RLock
from ._native import NativeRecognizer, version, model_fetch
__all__ = ["Recognizer", "version", "model_fetch"]

class Recognizer:
    """Serialize calls per session. feed() returns events; on_event optionally receives each.

    Callbacks execute synchronously on the calling thread. Model inference releases the GIL.
    Do not call mutating session methods from inside a callback; handle returned events instead.
    """
    def __init__(self, model_dir, configuration=None, on_event=None):
        self._native = NativeRecognizer(str(model_dir), json.dumps(configuration or {}))
        self._lock = RLock()
        self._dispatching = False
        self.on_event = on_event

    def _guard(self):
        if self._dispatching:
            raise RuntimeError("session mutation inside an event callback is not supported")

    def _events(self, events):
        if self.on_event:
            self._dispatching = True
            try:
                for event in events:
                    self.on_event(event)
            finally:
                self._dispatching = False
        return events

    def set_expected(self, target):
        """{'surah':112}, inclusive ayahs, or zero-based half-open words."""
        with self._lock:
            self._guard()
            self._native.set_expected(json.dumps(target))

    def feed(self, pcm16k):
        with self._lock:
            self._guard()
            return self._events(json.loads(self._native.feed(list(pcm16k))))

    def stop(self):
        with self._lock:
            self._guard()
            summary = json.loads(self._native.stop())
            self._events(summary["events"])
            return summary

    def reset(self):
        with self._lock:
            self._guard()
            self._native.reset()
