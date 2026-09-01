// SidebarView.swift — sections DEVICE / LIBRARY / SYNC / BACKUPS (UX §3).
//
// Bank rows are JUMP TARGETS, not filters: they scroll the always-complete
// slot list to that section. Library tags are sidebar children filtering the
// library list. The footer carries the backup-freshness line and the small
// settings menu (fast practice timing).

import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Device") {
                sidebarRow(.device, label: "All Slots",
                           systemImage: "pianokeys")
                ForEach(0..<SlotID.Layout.banks, id: \.self) { bank in
                    Button {
                        model.sidebar = .device
                        model.bankJumpRequest = bank
                    } label: {
                        Label(SlotID.bankLabel(bank),
                              systemImage: "square.grid.4x3.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Library") {
                sidebarRow(.library(tag: nil), label: "All Presets",
                           systemImage: "books.vertical")
                ForEach(model.libraryModel.tags, id: \.self) { tag in
                    sidebarRow(.library(tag: tag), label: tag,
                               systemImage: "tag")
                }
            }
            Section {
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

    /// Sidebar footer: backup freshness (UX §4) + settings menu.
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
                if model.connection.isPractice {
                    Menu("Practice profile") {
                        ForEach(PracticeProfile.allCases) { profile in
                            Button(profile.title) {
                                model.startPractice(profile)
                            }
                        }
                    }
                    Button("Leave Practice Mode") { model.disconnect() }
                } else if model.connection.hasDevice {
                    Button("Disconnect") { model.disconnect() }
                }
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

#Preview("Sidebar") {
    PreviewHost { _ in
        NavigationSplitView {
            SidebarView()
        } detail: {
            Text("Detail")
        }
    }
}
