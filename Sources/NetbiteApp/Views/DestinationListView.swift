import AppKit
import SwiftUI

struct DestinationGroup: Identifiable {
    let app: AppGroup
    let rows: [DestinationRow]
    var id: AppGroup.ID { app.id }
}

/// The process → destination tree. Hovering a row lights up its arc on the map.
struct DestinationListView: View {
    @Environment(BlockingController.self) private var blocking
    let groups: [DestinationGroup]
    @Binding var selection: DestinationRef?
    @Binding var hovered: DestinationRef?

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader()
            if groups.isEmpty {
                EmptyStateView(
                    "No destinations to show",
                    systemImage: "network.slash",
                    message: "Nothing matches the filter or the search. Choose “All” in the toolbar, or clear the search.",
                    tint: .hexNeutral
                )
                .canvasBackground()
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        DestinationRowView(row: row)
                            .tag(row.id)
                            .listRowBackground(hovered == row.id ? Color.hexOKWash : nil)
                            .onHover { inside in
                                if inside {
                                    hovered = row.id
                                } else if hovered == row.id {
                                    hovered = nil
                                }
                            }
                            .contextMenu { menu(for: row) }
                    }
                } header: {
                    GroupHeader(group: group)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .canvasBackground()
    }

    @ViewBuilder
    private func menu(for row: DestinationRow) -> some View {
        let destination = row.destination
        let address = destination.key.address
        if !destination.isLocal {
            let isRuled = blocking.addressRule(address) != nil
            Button(isRuled ? "Unblock This Destination" : "Block This Destination") {
                blocking.toggleAddress(address, note: "\(row.app.name) · \(destination.title)")
            }
            Divider()
        }
        Button("Copy IP Address") { copy(address.description) }
        if let hostname = destination.hostname {
            Button("Copy Host Name") { copy(hostname) }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private enum Column {
    static let port: CGFloat = 86
    static let location: CGFloat = 170
    static let status: CGFloat = 110
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Destination").frame(maxWidth: .infinity, alignment: .leading)
            Text("Port").frame(width: Column.port, alignment: .leading)
            Text("Location").frame(width: Column.location, alignment: .leading)
            Text("Status").frame(width: Column.status, alignment: .leading)
        }
        .font(.eyebrow)
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Color.surfaceCanvas)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityHidden(true)
    }
}

private struct GroupHeader: View {
    let group: DestinationGroup

    var body: some View {
        HStack(spacing: Spacing.sm) {
            AppIcon(app: group.app, size: 18)
            Text(group.app.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(group.app.identityLabel)
                .font(.dataMonoCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(group.rows.count == 1 ? "1 destination" : "\(group.rows.count) destinations")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

struct DestinationRowView: View {
    let row: DestinationRow

    var body: some View {
        let destination = row.destination
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.title)
                    .fontWeight(.medium)
                    .strikethrough(row.isBlocked, color: .hexDanger)
                    .foregroundStyle(row.isBlocked ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.dataMonoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(destination.key.portLabel)
                .font(.dataMonoCallout)
                .foregroundStyle(.secondary)
                .frame(width: Column.port, alignment: .leading)
            Group {
                if destination.isLocal {
                    Label("Local network", systemImage: "house")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    CountryBadge(code: destination.country)
                }
            }
            .frame(width: Column.location, alignment: .leading)
            StatusBadge(destination: destination, blockReason: row.blockReason)
                .frame(width: Column.status, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let destination = row.destination
        if destination.hostname != nil { return destination.key.address.description }
        return destination.isLocal ? "private address" : "no reverse DNS"
    }
}
