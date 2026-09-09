# OBD2Dash for iPad

A native SwiftUI dashboard for the BLE stream in this repository. Requires iPadOS 17 or newer. No third-party app dependencies.

## Build with GitHub and install from Windows (free Apple account)

1. Open [the iPad app workflow](https://github.com/EthanPope07/obd2dash/actions/workflows/ipad.yml). Builds run automatically when app code changes. To rebuild manually, sign in as a repository collaborator, choose **Run workflow**, and select `main`.
2. Open a successful run. Under **Artifacts**, download **OBD2Dash-iPad-unsigned** (GitHub sign-in required), then extract the downloaded ZIP to get `OBD2Dash-unsigned.ipa`. Artifacts expire after 30 days; run the workflow again if needed.
3. Install [Sideloadly for Windows](https://sideloadly.io/) and its required Apple device components using its current official instructions. Connect your iPad by USB, unlock it, and trust the computer.
4. Select the iPad and drag the `.ipa` into Sideloadly. Use **Apple ID Sideload** with your own free Apple account and start installation. Enter account credentials only in the local signing tool, never in this repository or GitHub Actions.
5. If prompted, trust your developer profile under **Settings > General > VPN & Device Management**. Enable **Settings > Privacy & Security > Developer Mode** and restart if requested.
6. Open OBD2Dash and allow Bluetooth access. Power on the scanner with this repository's firmware; the foreground app connects automatically.

Free-account signing lasts seven days. Refresh or reinstall with Sideloadly using the same account and bundle identifier; see its [FAQ](https://sideloadly.io/faq) for automatic refresh and account limits. No paid developer membership or personally owned Mac is needed for this workflow. The iPad must run iPadOS 17 or newer.

GitHub tests the protocol core, builds the simulator app, and builds an unsigned Release app for physical ARM64 iPads. It checks the device platform and architecture, packages `Payload/OBD2Dash.app` as an IPA, and supplies `SHA256SUMS.txt`. The IPA cannot be installed directly until Sideloadly signs it. No Apple credentials or signing certificates are used by CI. A successful build does not verify physical installation or BLE behavior; those still require an iPad and scanner.

## Run on an iPad with Xcode

1. Clone the repository on a Mac with Xcode 15 or newer (Xcode 16 recommended).
2. Open ipad/OBD2Dash.xcodeproj.
3. In the OBD2Dash target's Signing & Capabilities, select your development team. Change the bundle identifier if your account requires it.
4. Select your attached iPad as the run destination and run the app. Enable Developer Mode on the iPad if requested.
5. Allow Bluetooth access when prompted, then power on the scanner running this repository's firmware.

The app scans for the service UUID, connects, discovers the notify characteristic and subscribes automatically. It remembers the first successfully subscribed scanner. Use the connection menu to reconnect or forget that scanner. It will not silently switch to a different remembered device.

Automatic connection/reconnection is foreground-only. Backgrounding the app stops scanning and disconnects; returning to the foreground reconnects. Bluetooth permission and a powered-on radio are required. It does not pair through the iPad Settings screen.

## Dashboard

- Three large gauges: RPM, speed in km/h, and coolant temperature in Celsius.
- A gauge ECU selector keeps values from different ECUs separate.
- A searchable list includes every PID advertised in support maps or observed in samples, keyed by ECU and PID.
- Common scalar PIDs show numeric values and units. Unknown/encoded PIDs remain visible as raw data; expand any row to inspect the bytes and device timestamp.
- Support-map rows start as awaiting a first sample. Timeouts and ECU errors never become zero-valued readings.
- Gauges blank when disconnected or when the latest successful sample is over 15 seconds old. Old list values remain marked stale.
- The app may wait until the next support sweep to learn all supported PIDs. It never invents unsupported rows.

The firmware polls broadly, so vehicles with many PIDs may not refresh gauges quickly. A priority polling mode can be added to the firmware later; it is not implied by this UI.

## Preview without a scanner

In Xcode, Edit Scheme -> Run -> Arguments, add --demo. This uses clearly labeled simulated readings and does not start Bluetooth. Remove the argument for real telemetry. Simulator previews are not hardware validation.

## Protocol and testing

The app shares a Foundation-only parser/model source with the OBDCore Swift package. It matches docs/BLE.md, checks packet bounds and identity, discards gaps and incomplete records, and expires partial reassembly after 15 seconds. Device milliseconds are uptime, not calendar time.

Run on macOS:

    swift test --package-path ipad/OBDCore
    xcodebuild -project ipad/OBD2Dash.xcodeproj -scheme OBD2Dash -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

The GitHub workflow runs these checks on macOS. The development host used to add this app was Windows, so native iPad UI rendering and physical CoreBluetooth behavior must still be verified on an iPad.

Numeric decoding is intentionally limited to implemented scalar definitions with exact expected byte counts. Other PIDs preserve their complete raw readings. Decoder reference: https://www.csselectronics.com/pages/obd2-pid-table-on-board-diagnostics-j1979

## Files

- OBD2Dash/DashboardModel.swift: foreground connection lifecycle and notification handling
- OBD2Dash/DashboardView.swift: gauges and searchable PID list
- OBDCore/Sources/OBDCore/Telemetry.swift: reassembly, support maps, scalar decoding and freshness
- OBDCore/Tests: regression tests

No firmware modifications are needed. No vehicle-write control is exposed by the app.
