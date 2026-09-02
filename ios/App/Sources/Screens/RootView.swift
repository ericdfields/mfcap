// RootView.swift — the three-column shell and all global wiring (UX §3, §18.1).
//
// NavigationSplitView (sidebar / content / detail), the practice banner over
// the content column, the global status bar as a bottom safeAreaInset, every
// sheet and alert, toasts, and passive banners (hot-plug, backup
// interrupted). Navigation selection persists via SceneStorage — selection
// only, never a resumed device operation.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebarSelection") private var storedSidebar = "device"

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } content: {
            contentColumn
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if model.connection.isPractice {
                            PracticeBanner()
                        }
                        passiveBanners
                    }
                }
        } detail: {
            detailColumn
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
                .padding(.bottom, 64)
        }
        // ------------------------------------------------------- sheets
        .sheet(isPresented: $model.showBackupProgressSheet) {
            BackupProgressSheet()
        }
        .sheet(item: $model.restorePlanRequest) { request in
            RestorePlanSheet(request: request)
        }
        .sheet(item: $model.bulkApplyPlan) { plan in
            BulkApplyPlanSheet(plan: plan)
        }
        .sheet(item: $model.slotPickerRequest) { request in
            SlotPickerSheet(request: request)
        }
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectSheet()
        }
        .sheet(item: $model.verifyMismatch) { presentation in
            VerifyMismatchSheet(presentation: presentation)
        }
        .sheet(item: $model.newCollectionRequest) { request in
            NewCollectionSheet(request: request)
        }
        .sheet(item: $model.collectionApplyRequest) { plan in
            CollectionApplyPlanSheet(plan: plan)
        }
        // ------------------------------- §9 confirmations (dialog + sheet)
        .sheet(item: planSheetConfirmation) { pending in
            SendPlanSheet(pending: pending)
        }
        .sheet(item: dialogConfirmation) { pending in
            OverwriteConfirmationView(pending: pending)
                .presentationDetents([.medium])
        }
        .alert(item: $model.deviceAlert) { alert in
            deviceAlert(alert)
        }
        // ------------------------------------------------------- lifecycle
        .task { await model.startHotPlugScan() }
        .onAppear { model.sidebar = Self.sidebar(from: storedSidebar) }
        .onChange(of: model.sidebar) { _, selection in
            storedSidebar = Self.store(selection)
        }
    }

    // ------------------------------------------------------------- columns

    @ViewBuilder
    private var contentColumn: some View {
        switch model.sidebar ?? .device {
        case .device:
            if model.connection.hasDevice || model.slots.namesAsOf != nil {
                SlotListView()
            } else {
                ConnectView()
            }
        case .library(let tag):
            LibraryListView(tag: tag)
        case .favorites:
            FavoritesListView()
        case .audition:
            AuditionView()
        case .collections, .collection:
            CollectionsListView()
        case .sync:
            SyncListView()
        case .backups:
            BackupListView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch model.detail {
        case .slot(let slot):
            SlotDetailView(slot: slot)
        case .libraryEntry(let id):
            LibraryEntryDetailView(entryID: id)
        case .syncSlot(let slot):
            SyncSlotDetailView(slot: slot)
        case .backup(let folder):
            BackupDetailView(folderName: folder)
        case .collection(let id):
            CollectionDetailView(collectionID: id)
        case nil:
            ContentUnavailableView("Select a slot or preset",
                                   systemImage: "pianokeys")
        }
    }

    // ------------------------------------------------------ passive banners

    @ViewBuilder
    private var passiveBanners: some View {
        if let banner = model.hotPlugBanner {
            PassiveBannerView(text: banner,
                              actionLabel: model.connection.isPractice
                                  ? "Switch" : "Connect") {
                model.connectHardware(nil)
            } dismiss: {
                model.hotPlugBanner = nil
            }
        }
        if let banner = model.backupInterruptedBanner {
            PassiveBannerView(text: banner, actionLabel: "Resume") {
                if let partial = model.backups.resumable.first {
                    model.resumeBackup(partial.folderName)
                }
                model.backupInterruptedBanner = nil
            } dismiss: {
                model.backupInterruptedBanner = nil
            }
        }
    }

    // -------------------------------------------------- confirmation routing

    /// Plan-sheet-severity confirmations (bulk send / bulk sync).
    private var planSheetConfirmation: Binding<PendingConfirmation?> {
        Binding(
            get: {
                guard let pending = model.pendingConfirmation else { return nil }
                switch pending.plan.severity {
                case .planSheet, .planSheetPlusFinalAlert: return pending
                default: return nil
                }
            },
            set: { if $0 == nil { model.pendingConfirmation = nil } })
    }

    /// Dialog-severity confirmations (occupied or unjudged single target).
    /// Popover severity renders at the touched row (SlotRowView, UX §13.2)
    /// when the initiating flow anchored one; unanchored popover-severity
    /// confirmations (Library/Sync sends, the slot picker — no slot row is
    /// on screen) fall back to this dialog so they always surface.
    private var dialogConfirmation: Binding<PendingConfirmation?> {
        Binding(
            get: {
                guard let pending = model.pendingConfirmation else { return nil }
                switch pending.plan.severity {
                case .dialog: return pending
                case .popover where pending.anchor == nil: return pending
                default: return nil
                }
            },
            set: { if $0 == nil { model.pendingConfirmation = nil } })
    }

    private func deviceAlert(_ alert: DeviceAlert) -> Alert {
        if let primaryLabel = alert.primaryLabel {
            if let secondaryLabel = alert.secondaryLabel {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text(primaryLabel)) {
                        alert.primary?()
                    },
                    secondaryButton: .default(Text(secondaryLabel)) {
                        alert.secondary?()
                    })
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(primaryLabel)) {
                    alert.primary?()
                },
                secondaryButton: .cancel(Text("Close")))
        }
        return Alert(title: Text(alert.title), message: Text(alert.message),
                     dismissButton: .default(Text("Close")))
    }

    // ------------------------------------------------------- scene storage

    private static func sidebar(from raw: String) -> SidebarSelection {
        switch raw {
        case "library": return .library(tag: nil)
        case "favorites": return .favorites
        case "collections": return .collections
        case "sync": return .sync
        case "backups": return .backups
        case "audition": return .audition
        default: return .device
        }
    }

    private static func store(_ selection: SidebarSelection?) -> String {
        switch selection {
        case .library: return "library"
        case .favorites: return "favorites"
        case .audition: return "audition"
        // A specific collection restores to the section (never a resumed op).
        case .collections, .collection: return "collections"
        case .sync: return "sync"
        case .backups: return "backups"
        default: return "device"
        }
    }
}

// ------------------------------------------------------------ small pieces

/// Hot-plug / interruption banners: passive, dismissable, never auto-acting.
struct PassiveBannerView: View {
    let text: String
    let actionLabel: String
    let action: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector")
            Text(text).font(.callout)
            Spacer()
            Button(actionLabel, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

/// Transient toasts, bottom-anchored above the status bar (UX §8.2, §9.6).
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts.toasts) { toast in
                HStack(spacing: 12) {
                    if toast.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(toast.message)
                        .font(.callout)
                        .lineLimit(3)
                    if let label = toast.actionLabel {
                        Button(label) {
                            toast.action?()
                            model.toasts.dismiss(toast.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 4)
            }
        }
        .padding(.horizontal, 24)
        .animation(.default, value: model.toasts.toasts)
    }
}

#Preview("Root — practice mode", traits: .landscapeLeft) {
    PreviewHost { _ in
        RootView()
    }
}
