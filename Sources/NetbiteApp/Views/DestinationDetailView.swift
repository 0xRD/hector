import AppKit
import Charts
import SwiftUI

struct DestinationDetailView: View {
    @Environment(BlockingController.self) private var blocking
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
                StatusBadge(destination: destination, blockReason: row.blockReason)
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

            actions(row)
        }
    }

    @ViewBuilder
    private func actions(_ row: DestinationRow) -> some View {
        let destination = row.destination
        let address = destination.key.address
        let addressRule = blocking.addressRule(address)
        VStack(alignment: .leading, spacing: 10) {
            if destination.isLocal {
                Text("Local and private addresses are never blocked: it would cut this Mac off its own network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    blocking.toggleAddress(address, note: "\(row.app.name) · \(destination.title)")
                } label: {
                    Label(addressRule == nil ? "Block this destination" : "Unblock this destination",
                          systemImage: addressRule == nil ? "nosign" : "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(addressRule == nil ? .netbiteBlock : nil)
                .buttonStyle(.borderedProminent)
                if let country = destination.country {
                    let blocked = blocking.isCountryBlocked(country)
                    Button {
                        blocking.setCountry(country, blocked: !blocked)
                    } label: {
                        Label(blocked ? "Unblock \(Countries.name(country))" : "Block all of \(Countries.name(country))", systemImage: "flag")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                if blocking.pendingChanges > 0 {
                    PendingBar()
                }
                Text("Blocking applies to every app on this Mac: \(address.description) goes to the pf table, a country to its own table." as String)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy IP") { copy(address.description) }
                if let hostname = destination.hostname {
                    Button("Copy host") { copy(hostname) }
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
