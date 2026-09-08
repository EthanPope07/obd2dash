# BLE protocol v1

Advertised name: OBD2Dash. Discover by service UUID, not name alone.

| Attribute | UUID | Properties |
|---|---|---|
| Service | 973a0001-6f8a-4db7-a735-79d348be7341 | Primary |
| Stream | 973a0002-6f8a-4db7-a735-79d348be7341 | Notify |
| Info | 973a0003-6f8a-4db7-a735-79d348be7341 | Read |

Subscribe to Stream using CoreBluetooth setNotifyValue(true, for:). The firmware does not require a larger MTU: every notification is 20 bytes, fitting the default 23-byte ATT MTU. The only writable attribute is the notification subscription descriptor. There is no CAN-command characteristic.

## Packet

All multi-byte fields are unsigned little-endian. Serialization is explicit; no compiler-dependent packed C struct is transmitted.

| Offset | Bytes | Meaning |
|---|---:|---|
| 0 | 1 | Version in high nibble (1); kind in low nibble |
| 1 | 1 | Requested PID, or support-page base |
| 2 | 2 | ECU response CAN ID (7E8–7EF) |
| 4 | 2 | Sample sequence, wraps at 65536 |
| 6 | 2 | Offset into the logical payload |
| 8 | 2 | Total logical payload length |
| 10 | 1 | Status |
| 11 | 1 | Fragment payload bytes (1–8) |
| 12 | 8 | Fragment bytes; unused trailing bytes zero-filled |

Kinds: 1 = PID sample, 2 = discovery support-page result.
Statuses: 0 = valid; 1 = timeout; 2 = negative ECU reply; 3 = malformed response; 4 = transport failure; 5 = bus unavailable/recovering.

The logical payload begins with milliseconds since boot (uint32 LE), then:
- Valid PID: raw data bytes after the 41/PID response prefix.
- Valid support page: four bitmap bytes in original ECU order (big-endian bit map).
- Negative response: one NRC byte.
- Other failures: no additional bytes. Never reuse previous sensor bytes as a new successful reading.

For bitmap base B, the most significant bit represents B+1; the least significant bit represents B+32. Continuation PIDs 20,40,...,E0 are support pages, not gauge values.

Example: sequence 0, ECU 7E8, PID 0C, timestamp 0, raw 1A F8:
    11 0c e8 07 00 00 00 00 06 00 00 06 00 00 00 00 1a f8 00 00
RPM is (0x1AF8)/4 = 1726 RPM. Other PIDs can contain multiple values and flags; retain their raw bytes.

## Reassembly

Start at offset zero. Require the same version/kind, ECU, PID, sequence, total length and status for all fragments, and exactly contiguous offsets. Emit a sample only when all total bytes are received. Reject out-of-range lengths, gaps, duplicate or reordered fragments. Clear partial state on disconnect and expire incomplete records. Sequence numbers and timestamps reset on reboot and wrap; they are not wall-clock time.

Notifications are best effort. The 15 ms fragment pacing reduces congestion but does not acknowledge delivery. Use timestamps to mark readings stale. A sequence gap can also reflect samples produced before subscription. Discovery repeats periodically, so a client subscribing late may wait until the next support sweep for all bitmap pages.

A Python reference reassembler is in tools/decode_ble.py; feed one notification hex string per line. The iPad app source was not supplied, so no existing app compatibility is claimed.

## Access

This prototype does not enable pairing or encryption. Nearby clients can subscribe to telemetry. Do not transmit identity/location data through this interface without designing appropriate access control.
