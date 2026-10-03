import AppKit
import Charts
import SwiftUI

struct DestinationDetailView: View {
    let row: DestinationRow?
    /// Every app that talks to the same address, on any port.
    let usedBy: [AppGroup]

    var body: some View {
        if let row {
            ScrollView {
                content(row)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No destination selected", systemImage: "globe",
                                   description: Text("Pick a line on the map or a row in the list."))
        }
    }

    @ViewBuilder
    private func content(_ row: DestinationRow) -> some View {
        let destination = row.destination
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Destination")
                Text(destination.title)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(destination.key.address.description) · \(destination.key.portLabel)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                StatusBadge(destination: destination)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                detail("Location") {
                    if destination.isLocal {
                        Text("Local network")
                    } else {
                        CountryBadge(code: destination.country)
                    }
                }
                detail("Reverse DNS") { Text(destination.hostname ?? "None").textSelection(.enabled) }
                detail("First seen") { Text(destination.firstSeen, format: .dateTime.hour().minute().second()) }
                detail("Last activity") {
                    if destination.isLive {
                        Text("Now")
                    } else {
                        Text(destination.lastSeen, format: .relative(presentation: .named))
                    }
                }
                detail("Connections") {
                    Text(destination.tcpStates.isEmpty
                         ? "\(destination.liveConnections)"
                         : "\(destination.liveConnections) · \(Set(destination.tcpStates).sorted().joined(separator: ", "))")
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle("Activity")
                    Spacer()
                    Text("last \(ConnectionMonitor.historyLength) s").font(.caption).foregroundStyle(.secondary)
                }
                // Newest sample on the right edge, like the sidebar sparklines.
                let offset = ConnectionMonitor.historyLength - destination.activity.count
                Chart(Array(destination.activity.enumerated()), id: \.offset) { sample in
                    BarMark(x: .value("Second", offset + sample.offset), y: .value("Connections", sample.element), width: .fixed(3))
                        .foregroundStyle(Color.netbiteAccent)
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: -0.5...(Double(ConnectionMonitor.historyLength) - 0.5))
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) }
                .frame(height: 70)
                .accessibilityLabel("Live connections over the last minute")
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Used by")
                ForEach(usedBy) { app in
                    HStack(spacing: 10) {
                        AppIcon(app: app, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).fontWeight(.medium)
                            Text(app.identityLabel)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {} label: {
                    Label("Block this destination", systemImage: "nosign").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(true)
                if let country = destination.country {
                    Button {} label: {
                        Label("Block all of \(Countries.name(country))", systemImage: "flag").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(true)
                }
                Text("Blocking arrives with the privileged helper in Netbite 0.3. Until then, `netbite rules render` shows what a blocklist would apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy IP") { copy(destination.key.address.description) }
                    if let hostname = destination.hostname {
                        Button("Copy host") { copy(hostname) }
                    }
                }
            }
        }
    }

    private func detail<Content: View>(_ label: String, @ViewBuilder _ value: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
