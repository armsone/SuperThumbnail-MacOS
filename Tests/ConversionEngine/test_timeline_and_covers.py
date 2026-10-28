import os
import sys
import types
import unittest
from unittest import mock

ENGINE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Resources", "ConversionEngine")
worker = types.ModuleType("worker")  # same pre-seeded library mode engine_cli.py uses
worker.ENGINE_MODE = True
worker.__file__ = os.path.join(ENGINE_DIR, "worker.py")
sys.dont_write_bytecode = True
with open(worker.__file__) as f:
    exec(compile(f.read(), worker.__file__, "exec"), worker.__dict__)


def wmv(avg="0/0"):
    return {"index": 0, "codec_type": "video", "avg_frame_rate": avg, "r_frame_rate": "1000/1", "time_base": "1/1000"}


def mp4():
    return {"index": 0, "codec_type": "video", "avg_frame_rate": "30000/1001", "r_frame_rate": "30000/1001", "time_base": "1/30000"}


def probe(pts, last_dur):
    return {"video_pts": {0: pts}, "video_last_dur": {0: last_dur}, "first_audio_pts": {}}


def verify(src_pts, out_pts, src_stream=None, last=0.001):
    s, o = probe(src_pts, last), probe(out_pts, 1 / 29.97)
    return worker.verify_decoded_presentation_match("s", "o", [src_stream or wmv()], [mp4()], [], [], probes=(s, o))


class TailCadence(unittest.TestCase):
    pts = [i * 0.0334 for i in range(60)]

    def test_nominal_clock_stream_with_matched_frames_passes(self):
        self.assertIsNone(verify(self.pts, list(self.pts)))

    def test_real_frame_count_loss_is_rejected(self):
        self.assertIn("프레임 수 불일치", verify(self.pts, self.pts[:-1]))

    def test_unstable_cadence_keeps_strict_tolerance(self):
        pts = self.pts[:-3] + [self.pts[-4] + 0.2, self.pts[-4] + 0.21, self.pts[-4] + 0.6]
        self.assertIn("종료 표시 시점", verify(pts, list(pts)) or "")

    def test_rate_that_is_not_the_inverse_timebase_keeps_strict_tolerance(self):
        stream = dict(wmv(), time_base="1/90000")
        self.assertIn("종료 표시 시점", verify(self.pts, list(self.pts), stream) or "")


class CoverArt(unittest.TestCase):
    def cover(self, idx=1, codec="mjpeg"):
        return {"index": idx, "codec_type": "video", "codec_name": codec, "width": 600, "height": 600, "disposition": {"attached_pic": 1}}

    def test_cover_is_not_a_video_stream(self):
        self.assertTrue(worker.is_cover_art(self.cover()))
        self.assertFalse(worker.is_cover_art(wmv()))

    def test_matching_cover_hash_passes(self):
        with mock.patch.object(worker, "cover_packet_hash", return_value="a" * 64):
            self.assertIsNone(worker.cover_art_problem("s", "o", [self.cover()], [self.cover(2)]))

    def test_missing_cover_is_rejected(self):
        self.assertIn("수 불일치", worker.cover_art_problem("s", "o", [self.cover()], []))

    def test_changed_cover_bytes_are_rejected(self):
        with mock.patch.object(worker, "cover_packet_hash", side_effect=["a" * 64, "b" * 64]):
            self.assertIn("일치하지 않", worker.cover_art_problem("s", "o", [self.cover()], [self.cover(2)]))

    def test_changed_cover_codec_is_rejected(self):
        self.assertIn("형식·크기", worker.cover_art_problem("s", "o", [self.cover()], [self.cover(2, "png")]))


if __name__ == "__main__":
    unittest.main()
