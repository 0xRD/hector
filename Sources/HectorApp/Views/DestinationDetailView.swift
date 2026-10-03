import AppKit
import Charts
import SwiftUI

struct DestinationDetailView: View {
    @Environment(BlockingController.self) private var blocking
    @Environment(ConnectionMonitor.self) private var monitor
    let row: DestinationRow?
    /// Every app that talks to the same address, on any port.
    let usedBy: [AppGroup]

    var body: some View {
        if let row {
            ScrollView {
                content(row)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .canvasBackground()
        } else {
            EmptyStateView(
                "Pick a destination",
                systemImage: "scope",
                message: "Click a line on the map or a row in the list to see where it goes, which apps use it, and to block it.",
                tint: .hectorOK,
                hector: .left
            )
            .canvasBackground()
        }
    }

    private func content(_ row: DestinationRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            DestinationHero(row: row)
            detailsCard(row.destination)
            activityCard(row.destination)
            usedByCard
            actionsCard(row)
        }
    }

    // MARK: - Cards

    private func detailsCard(_ destination: Destination) -> some View {
        Card(spacing: 9) {
            SectionHeader("Details", style: .eyebrow)
            DetailRow("Location") {
                if destination.isLocal {
                    Text("Local network")
                } else {
                    CountryBadge(code: destination.country)
                }
            }
            DetailRow("Network") { networkValue(destination) }
            DetailRow("Reverse DNS", value: destination.hostname ?? "None")
            DetailRow("First seen") {
                Text(destination.firstSeen, format: .dateTime.hour().minute().second())
            }
            DetailRow("Last activity") {
                if destination.isLive {
                    Text("Now")
                } else {
                    Text(destination.lastSeen, format: .relative(presentation: .named))
                }
            }
            DetailRow("Connections", value: connectionsText(destination))
            if destination.network != nil {
                // CC BY 4.0 asks for attribution where the data is shown.
                Text("Network names by DB-IP.com, CC BY 4.0")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The autonomous system that owns the address, or what to do to see it.
    @ViewBuilder
    private func networkValue(_ destination: Destination) -> some View {
        if let network = destination.network {
            DetailValueText(text: network.label, monospaced: false)
        } else if destination.isLocal {
            Text("Local network")
        } else {
            switch monitor.networkNamesStatus {
            case .ready:
                Text("Unknown").foregroundStyle(.secondary)
            case .loading:
                Text("Loading…").foregroundStyle(.secondary)
            case .downloading:
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading…").foregroundStyle(.secondary)
                }
            case .missing:
                Button("Download Network Names") {
                    Task { await monitor.downloadNetworkNames() }
                }
                .controlSize(.small)
                .help("Downloads the free DB-IP Lite ASN database (monthly, CC BY 4.0). Every lookup stays on this Mac.")
            case .failed(let message):
                Button("Download Network Names Again") {
                    Task { await monitor.downloadNetworkNames() }
                }
                .controlSize(.small)
                .help(message)
            }
        }
    }

    private func connectionsText(_ destination: Destination) -> String {
        guard !destination.tcpStates.isEmpty else { return "\(destination.liveConnections)" }
        let states = Set(destination.tcpStates).sorted().joined(separator: ", ")
        return "\(destination.liveConnections) · \(states)"
    }

    private func activityCard(_ destination: Destination) -> some View {
        Card(spacing: Spacing.sm) {
            SectionHeader("Activity", style: .eyebrow) {
                Text("last \(ConnectionMonitor.historyLength) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ActivityChart(activity: destination.activity)
        }
    }

    private var usedByCard: some View {
        Card(spacing: Spacing.sm) {
            SectionHeader("Used by", style: .eyebrow)
            ForEach(usedBy) { app in
                HStack(spacing: 10) {
                    AppIcon(app: app, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).fontWeight(.medium)
                        Text(app.identityLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func actionsCard(_ row: DestinationRow) -> some View {
        Card(spacing: Spacing.md) {
            SectionHeader("Actions", style: .eyebrow)
            actions(row)
        }
    }

    @ViewBuilder
    private func actions(_ row: DestinationRow) -> some View {
        let destination = row.destination
        let address = destination.key.address
        let addressRule = blocking.addressRule(address)
        if destination.isLocal {
            Label("Local and private addresses are never blocked: it would cut this Mac off its own network.",
                  systemImage: "house")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button {
                blocking.toggleAddress(address, note: "\(row.app.name) · \(destination.title)")
            } label: {
                Label(addressRule == nil ? "Block This Destination" : "Unblock This Destination",
                      systemImage: addressRule == nil ? "nosign" : "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(addressRule == nil ? Color.hectorDangerTint : nil)
            .buttonStyle(.borderedProminent)
            .help("Adds \(address.description) to your blocklist. Nothing changes until you apply.")
            if let country = destination.country {
                let blocked = blocking.isCountryBlocked(country)
                Button {
                    blocking.setCountry(country, blocked: !blocked)
                } label: {
                    Label(blocked ? "Unblock \(Countries.name(country))" : "Block All of \(Countries.name(country))", systemImage: "flag")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            if blocking.pendingChanges > 0 {
                PendingBar(compact: true)
            }
            Text("Blocking applies to every app on this Mac: \(address.description) goes to the pf table, a country to its own table." as String)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Copy IP") { copy(address.description) }
                .help("Copy \(address.description)")
            if let hostname = destination.hostname {
                Button("Copy Host") { copy(hostname) }
                    .help("Copy \(hostname)")
            }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        // Legacy name: the small uppercase heading of a group in an inspector.
        SectionHeader(title, style: .eyebrow)
    }
}

/// Name, address and verdict of the selected destination.
private struct DestinationHero: View {
    let row: DestinationRow

    var body: some View {
        let destination = row.destination
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                SymbolTile(symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(destination.title)
                        .font(.system(.title2, design: .serif, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(destination.key.address.description) · \(destination.key.portLabel)")
                        .font(.dataMonoCallout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            StatusBadge(destination: destination, blockReason: row.blockReason)
        }
    }

    private var symbol: String {
        if row.isBlocked { return "nosign" }
        return row.destination.isLocal ? "house" : "globe"
    }

    private var tint: Color {
        if row.isBlocked { return .hectorDanger }
        return row.destination.isLive ? .hectorOK : .hectorNeutral
    }
}

/// Live connections per second over the last minute, newest on the right.
private struct ActivityChart: View {
    let activity: [Int]

    var body: some View {
        // Newest sample on the right edge, like the sidebar sparklines.
        let offset = ConnectionMonitor.historyLength - activity.count
        let upper = Double(ConnectionMonitor.historyLength) - 0.5
        Chart(Array(activity.enumerated()), id: \.offset) { sample in
            BarMark(x: .value("Second", offset + sample.offset), y: .value("Connections", sample.element), width: .fixed(3))
                .foregroundStyle(Color.hectorOK)
                .cornerRadius(1.5)
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: -0.5...upper)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) }
        .frame(height: 70)
        .accessibilityLabel("Live connections over the last minute")
    }
}
