import os, unittest
from quranrecitationkit import Recognizer, version
class BindingTests(unittest.TestCase):
    def test_version(self): self.assertEqual(version(), "0.1.0")
    def test_invalid_model(self):
        with self.assertRaises(RuntimeError): Recognizer("/model-does-not-exist")
    @unittest.skipUnless(os.environ.get("QRK_MODEL_DIR"), "set QRK_MODEL_DIR for local inference")
    def test_silence(self):
        events=[]
        r=Recognizer(os.environ["QRK_MODEL_DIR"],on_event=events.append)
        r.set_expected({"surah":112}); r.feed([0.0]*16000)
        summary=r.stop()
        self.assertEqual(summary["type"], "summary")
        self.assertEqual(summary["verses"], [])
        self.assertTrue(any(e["type"]=="needs_retry" for e in events))
        r.reset()
