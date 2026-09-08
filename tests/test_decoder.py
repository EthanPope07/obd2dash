import importlib.util
from pathlib import Path
import struct
import unittest
spec = importlib.util.spec_from_file_location("decode_ble", Path(__file__).parents[1]/"tools/decode_ble.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class DecodeTest(unittest.TestCase):
    def fragment(self, off, body, total=11):
        return struct.pack("<BBHHHHBB",0x11,0x78,0x7e8,9,off,total,0,len(body))+body.ljust(8,b"\0")
    def test_reassembly(self):
        d=module.Decoder()
        self.assertIsNone(d.feed(self.fragment(0,bytes([1,0,0,0,4,5,6,7]))))
        value=d.feed(self.fragment(8,bytes([8,9,10])))
        self.assertEqual(value["timestamp_ms"],1)
        self.assertEqual(value["data_hex"],"0405060708090a")
    def test_gap(self):
        with self.assertRaises(ValueError):
            module.Decoder().feed(self.fragment(8,b"abc"))
    def test_new_sample_discards_partial(self):
        d=module.Decoder()
        d.feed(self.fragment(0,b"12345678"))
        self.assertIsNone(d.feed(self.fragment(0,b"abcdefgh")))
    def test_bad_length(self):
        with self.assertRaises(ValueError):
            module.Decoder().feed(b"")
if __name__ == "__main__":
    unittest.main()
