"""Reference decoder for OBD2Dash v1 notification hex lines; Python stdlib only."""
import json
import struct
import sys

class Decoder:
    def __init__(self):
        self.current = None

    def feed(self, packet):
        if len(packet) != 20:
            self.current = None
            raise ValueError("Expected 20-byte notification")
        vk, pid, ecu, seq, offset, total, status, count = struct.unpack("<BBHHHHBB", packet[:12])
        if vk >> 4 != 1 or vk & 15 not in (1, 2) or status > 5:
            self.current = None
            raise ValueError("Unknown protocol version, kind or status")
        if not 4 <= total <= 4099 or not 1 <= count <= 8 or offset + count > total:
            self.current = None
            raise ValueError("Invalid fragment bounds")
        key = (vk, pid, ecu, seq, total, status)
        if offset == 0:
            self.current = (key, bytearray())
        if self.current is None or self.current[0] != key or len(self.current[1]) != offset:
            self.current = None
            raise ValueError("Missing, duplicate or out-of-order fragment; discard sample")
        payload = self.current[1]
        payload.extend(packet[12:12+count])
        if len(payload) != total:
            return None
        self.current = None
        return {
            "kind": "sample" if vk & 15 == 1 else "support",
            "ecu": ecu, "pid": pid, "sequence": seq, "status": status,
            "timestamp_ms": int.from_bytes(payload[:4], "little"),
            "data_hex": payload[4:].hex()
        }

if __name__ == "__main__":
    decoder = Decoder()
    for line in sys.stdin:
        try:
            item = decoder.feed(bytes.fromhex(line.strip()))
            if item is not None:
                print(json.dumps(item))
        except ValueError as error:
            print(str(error), file=sys.stderr)
