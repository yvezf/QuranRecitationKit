import os, unittest
from quranrecitationkit import Recognizer, version
class BindingTests(unittest.TestCase):
    def test_version(self): self.assertEqual(version(), "0.3.0")
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

class SpotTests(unittest.TestCase):
    def test_model_free_ambiguity(self):
        from quranrecitationkit import match_text
        result=match_text('الذين آمنوا')
        self.assertFalse(result['verified']);self.assertTrue(result['ambiguous'])
        self.assertGreaterEqual(len(result['candidates']),2)
        self.assertTrue(all(c['confidence']<=0.5 for c in result['candidates']))
        self.assertEqual(match_text('The teacher explains the timetable')['candidates'],[])
    def test_invalid_spotter_model(self):
        from quranrecitationkit import Spotter
        with self.assertRaises(RuntimeError):Spotter('/model-does-not-exist')
    @unittest.skipUnless(os.environ.get('QRK_MODEL_DIR'),'set QRK_MODEL_DIR for inference')
    def test_spotter_silence(self):
        from quranrecitationkit import Spotter
        r=Spotter(os.environ['QRK_MODEL_DIR']);r.feed([0.0]*32000)
        self.assertEqual(r.stop()['quotes'],[]);r.reset()
