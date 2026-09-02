// SidebarView.swift — destinations only: DEVICE / LIBRARY / COLLECTIONS,
// SYNC, BACKUPS (UX §3, revised).
//
// The Device section leads with the connection status row — the state that
// used to live in the global bottom bar, plus every connection verb (connect,
// switch profile, leave practice, disconnect). The idle route into the
// device-activity history hangs off the footer's settings menu, which is
// present in every connection state (the failures you most need to read are
// the ones that leave you disconnected).
//
// Bank rows are GONE: they were a scroll command filed as a destination. Bank
// reachability lives where it acts, in the slot list's "Jump to Bank" toolbar
// menu, next to the sticky bank headers it scrolls to.
//
// Individual collections are GONE too: the content column already lists them,
// and listing them twice made the sidebar a duplicate of the screen beside it.

import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showActivity = false

    var body: some View {
        List {
            Section("Device") {
                DeviceStatusRow(showActivity: $showActivity)
                sidebarRow(.device, label: "All Slots",
                           systemImage: "pianokeys")
            }
            Section("Library") {
                sidebarRow(.library(tag: nil), label: "All Presets",
                           systemImage: "books.vertical")
                sidebarRow(.favorites, label: "Favorites",
                           systemImage: "heart")
                ForEach(model.libraryModel.allTagNames, id: \.self) { tag in
                    sidebarRow(.library(tag: tag), label: tag,
                               systemImage: "tag")
                }
            }
            Section {
                sidebarRow(.collections, label: "Collections",
                           systemImage: "square.stack.3d.up")
                sidebarRow(.sync, label: "Sync",
                           systemImage: "arrow.triangle.2.circlepath")
                sidebarRow(.backups, label: "Backups",
                           systemImage: "externaldrive")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Freak Librarian")
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    @ViewBuilder
    private func sidebarRow(_ selection: SidebarSelection, label: String,
                            systemImage: String) -> some View {
        Button {
            model.sidebar = selection
        } label: {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                if model.sidebar == selection {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Sidebar footer: backup freshness (UX §4) + the one true preference.
    /// The connection verbs that used to hide under this gear now live on the
    /// device status row, with the state they act on.
    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.freshness.dialogLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                Toggle("Fast practice timing (20×)", isOn: Binding(
                    get: { model.fastPracticeTiming },
                    set: { model.fastPracticeTiming = $0 }))
                Divider()
                // The idle route into the operations history, from EVERY
                // connection state. It used to live only inside the connected
                // device menu, so a transport loss — the one failure whose
                // message you most need to read — took its own explanation
                // with it: not busy any more, and not connected either.
                Button("Device Activity…") { showActivity = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

// ========================================================== connection state

/// Connection state as a sidebar row (was the bottom bar's capsule). Never a
/// navigation destination — it never sets `model.sidebar`, so it never draws
/// the selection checkmark.
struct DeviceStatusRow: View {
    @Environment(AppModel.self) private var model
    @Binding var showActivity: Bool

    var body: some View {
        Group {
            if model.connection.hasDevice {
                Menu {
                    connectedMenu
                } label: {
                    rowLabel(trailing: "ellipsis.circle")
                }
            } else if case .connecting = model.connection {
                HStack(spacing: 8) {
                    dot
                    Text(text).font(.subheadline)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                .frame(minHeight: 44)
            } else {
                Button {
                    model.showConnectSheet = true
                } label: {
                    rowLabel(trailing: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Connection: \(text)")
        .popover(isPresented: $showActivity) {
            OperationsPopover()
        }
    }

    private var dot: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private func rowLabel(trailing: String) -> some View {
        HStack(spacing: 8) {
            dot
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // "Device disconnected — showing last known state": the
                // difference between "never connected" and "the cable came
                // out mid-session" is only visible on the Device screen's own
                // stale banner otherwise.
                if let detail = subtext {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var subtext: String? {
        if case .noDevice(let banner) = model.connection { return banner }
        return nil
    }

    @ViewBuilder
    private var connectedMenu: some View {
        if model.connection.isPractice {
            Menu("Practice profile") {
                ForEach(PracticeProfile.allCases) { profile in
                    Button(profile.title) { model.startPractice(profile) }
                }
            }
            Button("Leave Practice Mode") { model.disconnect() }
        } else {
            Button("Disconnect") { model.disconnect() }
        }
        Button("Connect a different device…") {
            model.showConnectSheet = true
        }
        Divider()
        Button("Device Activity…") { showActivity = true }
    }

    private var text: String {
        switch model.connection {
        case .noDevice: return "Not connected — Connect…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .hardware(let name): return "\(name) · Connected"
        case .practice(let profile): return "Practice · \(profile.title)"
        }
    }

    private var color: Color {
        switch model.connection {
        case .noDevice: return .secondary
        case .connecting: return .orange
        case .hardware: return .green
        case .practice: return .purple   // the reserved practice tint (§11)
        }
    }
}

#Preview("Sidebar") {
    PreviewHost { _ in
        NavigationSplitView {
            SidebarView()
        } detail: {
            Text("Detail")
        }
    }
}
