// RootView.swift — the three-column shell and all global wiring (UX §3, §18.1).
//
// NavigationSplitView (sidebar / content / detail), the practice banner over
// the content column, every sheet and alert, toasts, and passive banners
// (hot-plug, backup interrupted, a minimized audition). Navigation selection
// persists via SceneStorage — selection only, never a resumed device
// operation.
//
// There is NO global bottom bar any more: a safeAreaInset on the split view
// does not propagate into the columns' safe areas, so it painted over
// CollectionDetailView's Apply bar and SlotListView's multi-select bar.
// Connection state moved to the sidebar's Device section; the running
// operation is a transient toolbar item on the content column. Toasts are an
// overlay on the CONTENT COLUMN for the same reason — on the split view they
// re-created the same occlusion over the detail column's Apply bar.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("sidebarSelection") private var storedSidebar = "device"

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } content: {
            contentColumn
                .deviceActivityToolbar()
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if model.connection.isPractice {
                            PracticeBanner()
                        }
                        passiveBanners
                    }
                }
                // Toasts belong to a COLUMN, not to the split view: as an
                // overlay on the split view they painted over (and swallowed
                // taps on) the detail column's own bottom bars — exactly the
                // occlusion that killed CollectionDetailView's Apply button.
                .overlay(alignment: .bottom) {
                    ToastOverlay()
                        .padding(.bottom, 16)
                }
        } detail: {
            detailColumn
                // In a collapsed (compact) layout the content column's top
                // inset is off-screen while a detail screen is pushed, so the
                // loan promise would be invisible on the very screen the
                // audition was started from. It rides the detail column too,
                // there and only there.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if sizeClass == .compact && showLoanBanner {
                        AuditionLoanBanner()
                    }
                }
        }
        // The running audition owns the whole screen — above the split view,
        // so no column bar can clip it, and no navigation can lose it.
        .fullScreenCover(isPresented: Binding(
            get: { model.audition.presented },
            set: { model.audition.presented = $0 })) {
            AuditionSessionView()
                .interactiveDismissDisabled()
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
        .onAppear {
            let selection = Self.sidebar(from: storedSidebar)
            model.sidebar = selection
            setFavoritesOnly(selection == .favorites)
        }
        .onChange(of: model.sidebar) { _, selection in
            storedSidebar = Self.store(selection)
            // Owned here, not by FavoritesListView.onAppear: a body pass runs
            // BEFORE onAppear, so the old wiring built a full 966-row list and
            // threw it away on every entry into Favorites — and could leave the
            // shared flag stuck true for All Presets.
            setFavoritesOnly(selection == .favorites)
        }
    }

    /// Assign only on a real change. `favoritesOnly`'s didSet fires on every
    /// assignment, equal values included, and each one costs a full pass over
    /// the library plus a name sort on the navigation's critical path.
    private func setFavoritesOnly(_ value: Bool) {
        guard model.libraryModel.favoritesOnly != value else { return }
        model.libraryModel.favoritesOnly = value
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
        case .collections:
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

    /// The standing promise that a slot is out on loan. Gated on the session
    /// cover being ACTUALLY on screen, not on the `presented` flag: if the
    /// cover fails to present (it is asked for while the setup popover is
    /// being dismissed), `presented` stays true and the flag-gated banner
    /// vanished — leaving a borrowed slot with no Stop control anywhere.
    private var showLoanBanner: Bool {
        model.audition.needsRestore && !model.audition.coverVisible
    }

    @ViewBuilder
    private var passiveBanners: some View {
        // No dismiss — it goes away when the slot is back, and nothing else
        // does.
        if showLoanBanner {
            AuditionLoanBanner()
        }
        // A loan left over from a previous run (terminated mid-session) or one
        // the user chose to settle later. The saved original is on disk.
        if let loan = model.pendingAuditionLoan, !model.audition.needsRestore {
            AuditionLoanRecoveryBanner(loan: loan)
        }
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
        // Audition is no longer a place; a stored value from an older build
        // lands on the library rather than an empty column.
        case "audition": return .library(tag: nil)
        default: return .device
        }
    }

    private static func store(_ selection: SidebarSelection?) -> String {
        switch selection {
        case .library: return "library"
        case .favorites: return "favorites"
        case .collections: return "collections"
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

/// A minimized audition is still holding one of the user's slots. This banner
/// is the standing promise and the only way back; it has no dismiss control
/// because dismissing it would hide an outstanding loan.
struct AuditionLoanBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle")
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            Button("Resume") { model.audition.presented = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Stop & Restore") { model.audition.stop() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var text: String {
        let slot = SlotID(model.audition.borrowedSlot
                          ?? model.audition.slot).display
        let source = model.audition.sourceLabel
        return source.isEmpty
            ? "Auditioning — slot \(slot) borrowed."
            : "Auditioning \(source) — slot \(slot) borrowed."
    }
}

/// A loan that outlived its session: the app was terminated mid-audition, or
/// the user chose to settle it later. The saved original is on disk, so this
/// banner — not a lost in-memory actor — is the promise.
struct AuditionLoanRecoveryBanner: View {
    @Environment(AppModel.self) private var model
    let loan: AuditionLoan

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Slot \(SlotID(loan.slot).display) still holds an audition "
                 + "preset. Its original '\(loan.name)' is saved.")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Put It Back") { model.restorePendingAuditionLoan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.connection.hasDevice)
            Button("Forget") { model.discardPendingAuditionLoan() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

/// Transient toasts, bottom-anchored (UX §8.2, §9.6).
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
                // A toast with no action is a notice, not a control: it must
                // never eat a tap meant for the list underneath it. Only the
                // Undo toast (which has a button to hit) is hit-testable.
                .allowsHitTesting(toast.actionLabel != nil)
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
