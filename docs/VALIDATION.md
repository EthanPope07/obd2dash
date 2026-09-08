# Integration validation

The host tests cover parsing and serialization. They do not exercise TWAI hardware, BLE delivery, ECU timing or the iPad UI.

Before calling this revision deployed:

1. Compile for the installed ESP32-S3 target. Confirm module flash settings match the actual module.
2. On a CAN simulator or stationary vehicle with the appropriate wiring, observe requests 7E0–7E7 and match replies 7E8–7EF. Verify bitrate first.
3. Compare each reported support map with a trusted scan tool. Include a vehicle or simulator advertising a continuation page above 20.
4. Test two ECUs supporting different PID sets. Confirm the dashboard does not combine their values under one key.
5. Simulate multi-frame replies, wrong consecutive-frame sequence, missing frames, negative replies and response-pending. A failure must never become a successful stale value.
6. Subscribe using a BLE inspector at the default MTU. Decode complete notification records using tools/decode_ble.py.
7. Disconnect during a fragmented record, reconnect and resubscribe. Discard the incomplete record. Wait for the next support-page sweep if needed.
8. Unplug the CAN source and restore it. Verify timeouts/recovery, rediscovery and continued BLE service.
9. Measure a full sweep with the actual supported-PID count. Coverage-oriented polling is not a guaranteed high-rate dashboard schedule.
10. Review the PCB's existing electrical findings separately before fabrication or vehicle-powered testing.

Example conversions after successful reassembly:
- 0C, two bytes A/B: RPM = (256*A+B)/4.
- 0D, one byte A: speed = A km/h.
- 05, one byte A: coolant = A-40 degrees C.

Validate byte count before applying a formula. Do not apply these scalar formulas to other PIDs or treat status failures as zero.
