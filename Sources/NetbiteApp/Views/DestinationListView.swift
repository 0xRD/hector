import SwiftUI

struct DestinationGroup: Identifiable {
    let app: AppGroup
    let rows: [DestinationRow]
    var id: AppGroup.ID { app.id }
}

/// The process → destination tree. Hovering a row lights up its arc on the map.
struct DestinationListView: View {
    let groups: [DestinationGroup]
    @Binding var selection: DestinationRef?
    @Binding var hovered: DestinationRef?

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader()
            Divider()
            if groups.isEmpty {
                ContentUnavailableView("No destination", systemImage: "network.slash",
                                       description: Text("Nothing matches the current filter."))
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                DestinationRowView(row: row)
                                    .tag(row.id)
                                    .listRowBackground(hovered == row.id ? Color.netbiteAccent.opacity(0.10) : nil)
                                    .onHover { inside in
                                        if inside {
                                            hovered = row.id
                                        } else if hovered == row.id {
                                            hovered = nil
                                        }
                                    }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                AppIcon(app: group.app, size: 18)
                                Text(group.app.name).font(.headline)
                                Text(group.app.identityLabel)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(group.rows.count == 1 ? "1 destination" : "\(group.rows.count) destinations")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
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
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(destination.key.portLabel)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Column.port, alignment: .leading)
            Group {
                if destination.isLocal {
                    Text("Local network").foregroundStyle(.secondary)
                } else {
                    CountryBadge(code: destination.country)
                }
            }
            .frame(width: Column.location, alignment: .leading)
            StatusBadge(destination: destination)
                .frame(width: Column.status, alignment: .leading)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let destination = row.destination
        if destination.hostname != nil { return destination.key.address.description }
        return destination.isLocal ? "private address" : "no reverse DNS"
    }
}
