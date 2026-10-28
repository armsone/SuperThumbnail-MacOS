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


def verify(src_pts, out_pts, src_stream=None, last=0.001, out_last=1 / 29.97):
    s, o = probe(src_pts, last), probe(out_pts, out_last)
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


class WholeStreamTailCadence(unittest.TestCase):
    """Real WMV tail pattern: ~33 ms cadence, a few genuine long gaps, the LAST two intervals long (1.468 s, 3.003 s)."""
    base = [round(i * 0.033, 3) for i in range(1000)]
    mid = base[:400] + [t + 2.0 for t in base[400:]]  # one genuine long gap in the middle
    pts = mid + [mid[-1] + 1.468, mid[-1] + 1.468 + 3.003]

    def test_real_tail_gap_pattern_passes_when_everything_is_matched(self):
        self.assertIsNone(verify(self.pts, list(self.pts)))

    def test_fixture_really_defeats_the_last_ten_cadence(self):
        gaps = [b - a for a, b in zip(self.pts[-10:], self.pts[-9:])]
        self.assertGreater(max(gaps), 3.0)

    def test_missing_frame_is_rejected(self):
        self.assertIn("프레임 수 불일치", verify(self.pts, self.pts[:-1]))
        self.assertIn("프레임 수 불일치", verify(self.pts, self.pts[:200] + self.pts[201:]))

    def test_changed_pts_is_rejected(self):
        moved_last = list(self.pts[:-1]) + [self.pts[-1] - 0.5]
        self.assertIn("표시 시각 오차", verify(self.pts, moved_last))
        moved_gap = list(self.pts)
        moved_gap[-2] += 0.05  # a genuine long gap must be retained frame-for-frame
        self.assertIn("표시 시각 오차", verify(self.pts, moved_gap))

    def test_abnormal_output_last_duration_is_rejected(self):
        for out_last in (0.5, 3.0, 0.02):
            self.assertIn("종료 표시 시점", verify(self.pts, list(self.pts), out_last=out_last) or "")

    def test_genuine_long_source_tail_duration_is_never_overwritten(self):
        # same nominal-tick metadata, but the source itself declares a long last frame: truncated output (1 cadence) must be rejected
        self.assertIn("종료 표시 시점", verify(self.pts, list(self.pts), last=3.0, out_last=0.033) or "")

    def test_no_dominant_cadence_keeps_strict_tolerance(self):
        irregular = [0.0]
        for i in range(1, 1000):
            irregular.append(irregular[-1] + (0.033 if i % 2 else 0.2))
        irregular += [irregular[-1] + 1.468, irregular[-1] + 4.471]
        self.assertIn("종료 표시 시점", verify(irregular, list(irregular)) or "")

    def test_too_few_intervals_is_no_cadence_evidence(self):
        short = self.pts[:50] + [self.pts[49] + 1.468, self.pts[49] + 4.471]
        self.assertIn("종료 표시 시점", verify(short, list(short)) or "")

    def test_tolerance_is_not_widened_for_a_wrong_cadence_end(self):
        # output last frame is cadence-like (0.045 = +36%) but not the measured cadence: still rejected
        self.assertIn("종료 표시 시점", verify(self.pts, list(self.pts), out_last=0.045) or "")


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
