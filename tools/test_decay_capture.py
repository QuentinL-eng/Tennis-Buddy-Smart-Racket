"""Host checks for extended recordings: python -m unittest discover -s tools -p test_decay_capture.py"""
from pathlib import Path
import queue
import sys
import tempfile
import threading
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ml"))
from train import load_real
from collect_session import serial_reader
from listen_clip import tail_start
from session_timing import impact_time


class DecayCaptureTests(unittest.TestCase):
    def test_new_contact_time_does_not_depend_on_payload_arrival(self):
        self.assertEqual(impact_time({"t_s": "12.5", "impact_t_s": "10.0"}), 10.0)

    def test_legacy_and_blank_contact_time(self):
        self.assertAlmostEqual(impact_time({"t_s": "1.0"}), 0.92)
        self.assertAlmostEqual(impact_time({"t_s": "1.0", "impact_t_s": ""}), 0.92)

    def test_tail_follows_last_clipped_sample_including_negative_full_scale(self):
        clip = np.zeros(4096, dtype=np.int16)
        clip[100] = 30000
        clip[900] = -32768
        self.assertEqual(tail_start(clip), 901)

    def test_unclipped_tail_starts_at_trigger(self):
        self.assertEqual(tail_start(np.zeros(2113, dtype=np.int16)), 64)

    def test_serial_audio_survives_read_timeouts(self):
        stop = threading.Event()
        chunks = iter([b"CLIP_META,samples=2,trigger_age_us=1000\n", b"CLIP,", b"0001", b"ffff\n"])

        class Serial:
            def readline(self):
                try:
                    return next(chunks)
                except StopIteration:
                    stop.set()
                    return b""

        output = queue.Queue()
        serial_reader(Serial(), output, stop)
        self.assertEqual(output.get()[1], "CLIP_META,samples=2,trigger_age_us=1000")
        self.assertEqual(output.get()[1], "CLIP,0001ffff")
        self.assertTrue(output.empty())

    def test_training_accepts_old_and_extended_clips_without_changing_model_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            old = np.arange(512, dtype="<i2")
            new = np.arange(4096, dtype="<i2")
            old.tofile(folder / "old.i16")
            new.tofile(folder / "new.i16")
            (folder / "labels.csv").write_text("file,dist_cm\nold.i16,1\nnew.i16,6\n")
            clips, distances = load_real(folder)
            self.assertEqual(clips.shape, (2, 512))
            np.testing.assert_array_equal(clips[1], new[:512])
            np.testing.assert_array_equal(distances, [1, 6])
            self.assertEqual((folder / "new.i16").stat().st_size, 8192)

    def test_short_training_clip_fails_instead_of_silently_disappearing(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            np.zeros(10, dtype="<i2").tofile(folder / "short.i16")
            (folder / "labels.csv").write_text("file,dist_cm\nshort.i16,1\n")
            with self.assertRaises(ValueError):
                load_real(folder)


if __name__ == "__main__":
    unittest.main()
