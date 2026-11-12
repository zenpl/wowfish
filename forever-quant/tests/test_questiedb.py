import base64
import unittest

from quant import questiedb as q


class TestCbor(unittest.TestCase):
    def test_samples_from_real_toc(self):
        self.assertEqual(q.cbor(base64.b64decode("gYEZMZg=")), [[12696]])
        self.assertEqual(q.cbor(base64.b64decode("gRkY7w==")), [6383])

    def test_types(self):
        self.assertEqual(q.cbor(bytes([0xa2, 0x01, 0x43, 0x61, 0x62, 0x63, 0x18, 0x09, 0x19, 0x01, 0x0b])), {1: b"abc", 9: 267})
        self.assertEqual(q.cbor(bytes([0x82, 0xfb, 0x40, 0x49, 0x50, 0xa3, 0xd7, 0x0a, 0x3d, 0x71, 0x20])), [50.63, -1])
        self.assertEqual(q.cbor(bytes([0x83, 0xf5, 0xf4, 0xf6])), [True, False, None])

    def test_chunked_value(self):
        whole = base64.b64encode(bytes([0x82, 0x01, 0x02])).decode()
        raw = {"Npc-1-7": "~2~", "Npc-1-7-1": whole[:2], "Npc-1-7-2": whole[2:]}
        self.assertEqual(q.value(raw, "Npc-1-7"), [1, 2])
        self.assertIsNone(q.value(raw, "Npc-9-7"))


if __name__ == "__main__":
    unittest.main()
