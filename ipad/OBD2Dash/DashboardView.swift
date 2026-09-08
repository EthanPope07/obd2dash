import SwiftUI

private let mint = Color(red: 0.40, green: 0.91, blue: 0.74)
private let panel = Color(red: 0.08, green: 0.10, blue: 0.12)

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        Dial(title: "ENGINE SPEED", reading: model.gauge(0x0c), unit: "rpm",
                             lower: 0, upper: 8000, accent: mint)
                        Dial(title: "VEHICLE SPEED", reading: model.gauge(0x0d), unit: "km/h",
                             lower: 0, upper: 240, accent: .cyan)
                        Dial(title: "COOLANT", reading: model.gauge(0x05), unit: "°C",
                             lower: -40, upper: 160, accent: .orange)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("All PIDs").font(.title2.bold())
                            Text("\(model.rows.count) supported or observed · \(model.received) records")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !model.ecus.isEmpty {
                            Picker("Gauge ECU", selection: $model.selectedECU) {
                                ForEach(model.ecus, id: \.self) { ecu in
                                    Text(String(format: "ECU %03X", Int(ecu))).tag(ecu)
                                }
                            }
                            .pickerStyle(.menu).tint(mint)
                            .accessibilityLabel("ECU used for the large gauges")
                        }
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search PID, name, or ECU", text: $model.query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Clear search").tint(.secondary)
                        }
                    }
                    .padding(14).background(panel, in: RoundedRectangle(cornerRadius: 12))

                    if model.rows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.path").font(.largeTitle).foregroundStyle(mint)
                            Text(model.streaming ? "Waiting for vehicle data" : "Ready when your scanner is")
                                .font(.headline)
                            Text(model.streaming
                                 ? "Supported PIDs appear as support maps and samples arrive. Discovery can take a full sweep."
                                 : "Power on OBD2Dash nearby and allow Bluetooth. The app connects automatically.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(36).background(panel, in: RoundedRectangle(cornerRadius: 16))
                    } else if model.filteredRows.isEmpty {
                        Text("No matching PIDs").foregroundStyle(.secondary).padding()
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(model.filteredRows) { row in
                                PIDRowView(row: row, now: model.now, connected: model.streaming)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.discovery)
                        Text("Readings older than 15 seconds are marked stale. Full-PID polling prioritizes coverage, not a fixed gauge update rate.")
                        if model.dropped > 0 {
                            Text("\(model.dropped) incomplete or invalid records discarded.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(Color(red: 0.035, green: 0.045, blue: 0.055))
            .navigationTitle("OBD2Dash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Reconnect", systemImage: "arrow.clockwise") { model.reconnect() }
                        Button("Forget scanner", systemImage: "antenna.radiowaves.left.and.right.slash") {
                            model.forgetDevice()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(mint)
                    }
                    .accessibilityLabel("Connection options")
                }
            }
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "car.side.fill").font(.title2).foregroundStyle(mint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Vehicle dashboard").font(.largeTitle.bold())
                Text(model.deviceName).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.streaming ? mint : .orange).frame(width: 8, height: 8)
                Text(model.connection).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(panel, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }
}

private struct Dial: View {
    let title: String
    let reading: Reading?
    let unit: String
    let lower: Double
    let upper: Double
    let accent: Color
    private var fraction: Double {
        guard let reading else { return 0 }
        return min(1, max(0, (reading.value-lower)/(upper-lower)))
    }
    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: fraction * 0.75)
                    .stroke(accent, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(135))
                VStack(spacing: 4) {
                    Text(reading.map { String(format: "%.0f", $0.value) } ?? "—")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    Text(unit).font(.subheadline).foregroundStyle(.secondary)
                    if reading == nil { Text("Waiting / stale").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(16)
            }
            .frame(width: 176, height: 176)
            HStack {
                Text(String(format: "%.0f", lower)); Spacer(); Text(String(format: "%.0f", upper))
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(reading?.text ?? "No fresh reading")
    }
}

private struct PIDRowView: View {
    let row: PIDRow
    let now: Date
    let connected: Bool
    private var state: String {
        guard let status = row.status else { return "Awaiting first sample" }
        if status != 0 { return PIDCatalog.status(status, bytes: row.bytes) }
        return connected && row.isFresh(at: now) ? "Fresh" : "Stale"
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Raw bytes: " + (row.raw.isEmpty ? "—" : row.raw))
                    .font(.caption.monospaced()).textSelection(.enabled)
                if let timestamp = row.deviceTimestamp {
                    Text("Device uptime: \(timestamp) ms").font(.caption).foregroundStyle(.secondary)
                }
                if row.status == 0 && row.reading == nil {
                    Text("No numeric decoder for this PID or payload length. Raw data is preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("0x\(row.key.code)").font(.system(.body, design: .monospaced).weight(.semibold))
                    Text("ECU \(row.key.ecuLabel)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }.frame(width: 76, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(PIDCatalog.name(row.key.pid)).font(.body.weight(.medium))
                    Text(state).font(.caption).foregroundStyle(state == "Fresh" ? mint : .secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(row.reading?.text ?? (row.status == 0 ? "Raw data" : "—"))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    if let received = row.receivedAt {
                        Text("\(max(0, Int(now.timeIntervalSince(received))))s ago")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .tint(mint).padding(16).background(panel)
    }
}
