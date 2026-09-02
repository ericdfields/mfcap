// AppModel.swift — @MainActor @Observable root model (UX §18.2).
//
// Owns: the connection state machine, the single device-operation queue,
// device identity, the slot-history journal, and the wiring of every child
// model. Holds the device ONLY as `any FreakDeviceProtocol` (architecture
// spec §14) — the app layer never touches frames or bytes; the sole file
// that knows the practice device is simulated is PracticeDevice.swift.

import Foundation
import FreakCore
import SwiftUI

enum ConnectionState: Equatable {
    case noDevice(banner: String?)
    case connecting(endpointName: String)
    case hardware(name: String)
    case practice(PracticeProfile)

    var isPractice: Bool {
        if case .practice = self { return true }
        return false
    }

    var hasDevice: Bool {
        switch self {
        case .hardware, .practice: return true
        default: return false
        }
    }

    var practiceProfile: PracticeProfile? {
        if case .practice(let profile) = self { return profile }
        return nil
    }
}

enum SidebarSelection: Hashable {
    case device
    case library(tag: String?)
    case favorites                     // UX addendum §24.3
    case collections                   // UX addendum §26 (section / All Collections)
    case collection(id: String)        // UX addendum §26 (one collection child)
    case sync
    case backups
}

enum DetailSelection: Hashable {
    case slot(SlotID)
    case libraryEntry(String)
    case syncSlot(SlotID)
    case backup(String)
    case collection(id: String)        // UX addendum §26.4
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let plan: OverwritePlan
    /// The on-screen slot row a popover-severity confirmation anchors to.
    /// Set ONLY by flows initiated at a visible SlotRowView (drop, row
    /// paste); nil means no row is guaranteed on screen, so RootView
    /// presents the confirmation as a dialog instead (Library/Sync sends,
    /// the slot picker).
    var anchor: SlotID? = nil
    let confirm: @MainActor () -> Void
}

struct DeviceAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var primaryLabel: String? = nil
    var primary: (@MainActor () -> Void)? = nil
    var secondaryLabel: String? = nil
    var secondary: (@MainActor () -> Void)? = nil
}

/// The §14 VerifyMismatch moment's payload — modal sheet, never auto-retried.
struct VerifyMismatchPresentation: Identifiable {
    let id = UUID()
    let mismatch: VerifyMismatch
    let slot: SlotID
    /// Batch context line + Retry From Slot N (UX §14) when a batch stopped here.
    var batchContext: String? = nil
    var retryFromLabel: String? = nil
    var retryFrom: (@MainActor () -> Void)? = nil
    let writeAgain: @MainActor () -> Void
}

/// Per-row execution state for bulk applies and restores (plan sheets).
@MainActor @Observable
final class BatchRunState {
    enum RowState: Equatable { case pending, running, done, failed(String), skipped }

    let plan: OverwritePlan
    private(set) var rows: [Int: RowState]     // keyed by SlotID.raw
    var failure: (slot: SlotID, message: String)?
    var remaining: [SlotID] = []
    var finished = false
    var cancelled = false

    init(plan: OverwritePlan) {
        self.plan = plan
        rows = Dictionary(uniqueKeysWithValues: plan.items.map {
            ($0.target.raw,
             $0.disabledReason == nil ? RowState.pending : .skipped)
        })
    }

    var doneCount: Int { rows.values.filter { $0 == .done }.count }

    func state(_ slot: SlotID) -> RowState { rows[slot.raw] ?? .pending }
    func markRunning(_ slot: SlotID) { rows[slot.raw] = .running }
    func markDone(_ slot: SlotID) { rows[slot.raw] = .done }
    func markFailed(_ slot: SlotID, _ message: String) {
        rows[slot.raw] = .failed(message)
        failure = (slot, message)
        remaining = plan.items
            .filter { rows[$0.target.raw] == .pending }
            .map(\.target)
    }
}

@MainActor @Observable
final class AppModel {
    let paths: AppPaths
    let operations = DeviceOperationQueue()
    let toasts = ToastCenter()
    let undoStack = UndoStack()
    let freshness = FreshnessModel()
    let slots = SlotBrowserModel()
    let sync = SyncModel()
    let history: SlotHistoryStore
    var libraryModel: LibraryModel
    var backups: BackupsModel
    let collectionsModel = CollectionsModel()

    private(set) var connection: ConnectionState = .noDevice(banner: nil)
    private(set) var device: (any FreakDeviceProtocol)?
    private(set) var deviceIdentity = DeviceIdentity.none
    private var pacer: PacedTransport?

    // Navigation (restored via SceneStorage in RootView — selection only,
    // never a resumed device operation).
    var sidebar: SidebarSelection? = .device
    var detail: DetailSelection?
    /// Sidebar bank rows are jump targets, not filters (UX §3).
    var bankJumpRequest: Int?

    // Presentation
    var pendingConfirmation: PendingConfirmation?
    var deviceAlert: DeviceAlert?
    var verifyMismatch: VerifyMismatchPresentation?
    var showConnectSheet = false
    var showBackupProgressSheet = false
    var backupRun: BackupRunState?
    /// "Backup interrupted at slot 342 — Resume?" (UX §16.1).
    var backupInterruptedBanner: String?
    var restorePlanRequest: RestorePlanRequest?
    var bulkApplyPlan: BulkApplyPlan?
    var sendPlanRun: BatchRunState?
    var restoreRun: BatchRunState?
    var slotPickerRequest: SlotPickerRequest?
    /// "MicroFreak detected — Connect?" (hot-plug; never auto-connects, UX §12).
    var hotPlugBanner: String?

    // Collections (UX addendum §26, §27).
    /// The create-from-device name prompt (NewCollectionSheet).
    var newCollectionRequest: NewCollectionRequest?
    /// The Apply/Switch pre-flight (CollectionApplyPlanSheet).
    var collectionApplyRequest: CollectionApplyPlan?
    /// Per-slot execution ticks for a running Apply (mirrors restoreRun).
    var collectionRun: BatchRunState?

    // Copy / paste — paste goes through the identical guard rails (UX §5).
    var copyBuffer: PresetTransfer?

    var fastPracticeTiming: Bool {
        didSet {
            UserDefaults.standard.set(fastPracticeTiming,
                                      forKey: "MFFastPracticeTiming")
            if let pacer {
                let value = fastPracticeTiming
                Task { await pacer.setFast(value) }
            }
        }
    }

    init(paths: AppPaths = .documents(), seedFromBundle: Bool = true) {
        self.paths = paths
        self.fastPracticeTiming = UserDefaults.standard
            .bool(forKey: "MFFastPracticeTiming")
        self.history = SlotHistoryStore(url: paths.historyURL)
        try? FileManager.default.createDirectory(
            at: paths.backupsRoot, withIntermediateDirectories: true)
        libraryModel = LibraryModel(root: paths.libraryRoot,
                                    seedFromBundle: seedFromBundle)
        backups = BackupsModel(root: paths.backupsRoot)
        libraryModel.onChange = { [weak self] in
            self?.recomputeSync()
        }
        libraryModel.openOrCreate()
        // Collections live in the library folder (data-model spec §4) — mirror
        // them once the library is open; refreshed again after any mutation.
        Task { await collectionsModel.refresh(from: libraryModel.library) }
        // Drag-out .mfpreset export resolves bytes through this model.
        PresetTransferExporter.model = self
        Task {
            await backups.refresh()
            freshness.noteBackups(backups.items, identity: deviceIdentity)
        }
        // Development / UI-test hook: launch straight into practice mode.
        if UserDefaults.standard.bool(forKey: "MFPracticeMode")
            || ProcessInfo.processInfo.arguments.contains("-MFPracticeMode") {
            startPractice(.factoryFresh)
        }
    }

    // ================================================= connection (UX §12)

    /// Practice Mode entry — a first-class device, honestly paced by default.
    /// Previews/tests pass paced: false for instant wire timing.
    func startPractice(_ profile: PracticeProfile, paced: Bool = true) {
        guard canSwitchDevice() else { return }
        teardownDevice()
        let made = PracticeDevice.make(profile: profile, paced: paced,
                                       fast: fastPracticeTiming)
        device = made.device
        pacer = made.pacer
        connection = .practice(profile)
        adoptIdentity(profile.identity)
        refreshNames()
    }

    /// Hardware connect. nil endpoint = the likely match via discovery.
    func connectHardware(_ endpoint: HardwareEndpoint?) {
        guard canSwitchDevice() else { return }
        let name = endpoint?.name ?? "MicroFreak"
        // The prior device (practice sim, or nothing) stays fully attached
        // until the new transport actually opens — so a failed connect must
        // restore the prior connection state, never report .noDevice while
        // `device` still holds a live practice device.
        let previous = connection
        connection = .connecting(endpointName: name)
        do {
            let opened = try HardwareTransportProvider.openDevice(endpoint)
            teardownDevice()
            device = opened
            connection = .hardware(name: name)
            adoptIdentity(.hardware)
            hotPlugBanner = nil
            refreshNames()
        } catch let error as FreakError {
            connection = previous
            connectFailure = error
        } catch {
            connection = previous
            toasts.show("Couldn't connect: \(String(describing: error))",
                        isError: true)
        }
    }

    /// The connect screen's inline failure (DeviceNotFound lists endpoints).
    var connectFailure: FreakError?

    func disconnect() {
        teardownDevice()
        connection = .noDevice(banner: nil)
    }

    /// Switching devices mid-operation is refused (UX §11, §12).
    func canSwitchDevice() -> Bool {
        guard operations.active.isEmpty else {
            toasts.show("Finish or cancel the running operation before "
                + "switching devices.", isError: true)
            return false
        }
        return true
    }

    private func adoptIdentity(_ identity: DeviceIdentity) {
        deviceIdentity = identity
        freshness.adoptIdentity(identity)
        freshness.noteBackups(backups.items, identity: identity)
    }

    private func teardownDevice() {
        if let old = device {
            Task { await old.close() }
        }
        device = nil
        pacer = nil
        deviceIdentity = .none
        // Identity switch drops the slot cache and diff; the library and
        // backups are device-independent and kept (UX §11).
        slots.reset()
        sync.reset()
        undoStack.reset()
        freshness.reset()
    }

    /// Periodic hot-plug scan (never auto-connects; passive banner only).
    func startHotPlugScan() async {
        guard HardwareTransportProvider.isAvailable else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let visible = HardwareTransportProvider.microFreakVisible()
            switch connection {
            case .practice where visible:
                hotPlugBanner = "MicroFreak detected — Switch?"
            case .noDevice where visible:
                hotPlugBanner = "MicroFreak detected — Connect?"
            case .hardware, .connecting:
                hotPlugBanner = nil
            default:
                if !visible { hotPlugBanner = nil }
            }
        }
    }

    // ================================================= names / reads (UX §4)

    /// Names-only snapshot — the ONLY device operation ever started without
    /// an explicit user action (on connect). Names stream into rows.
    @discardableResult
    func refreshNames() -> Task<DeviceSnapshot, Error>? {
        guard let device else { return nil }
        slots.refreshingNames = true
        slots.namesError = nil
        let options: SnapshotOptions = {
            var o = SnapshotOptions()
            o.readBlobs = false
            return o
        }()
        let task = operations.enqueue(
            "Reading names", kind: .quick,
            onProgress: { [weak self] event in
                self?.slots.applyStreamedName(SlotID(event.slot),
                                              name: event.name)
            }
        ) { progress in
            try await device.snapshot(options: options, progress: progress)
        }
        Task { @MainActor in
            defer { self.slots.refreshingNames = false }
            do {
                let snapshot = try await task.value
                self.slots.applySnapshot(snapshot, hashed: false,
                                         provenance: nil)
                self.freshness.namesAsOf = self.slots.namesAsOf
                self.recordSnapshotObservations(snapshot)
                // Names known → restore the hashed tier from the latest
                // same-identity backup, marked with its age (UX §18.3).
                self.adoptHashedTierFromLatestBackup()
                self.recomputeSync()
            } catch let error as FreakError {
                self.slots.namesError =
                    "Couldn't read names: \(error.userMessage)"
                self.surfaceQuickError(error, slot: nil)
            } catch {
                self.slots.namesError =
                    "Couldn't read names: \(String(describing: error))"
            }
        }
        return task
    }

    /// Read one slot now (~1 s, the lazy-blob trigger, UX §5, §7.5).
    @discardableResult
    func readSlot(_ slot: SlotID) -> Task<Preset, Error>? {
        guard let device else { return nil }
        slots.setBusy(slot, true)
        let raw = slot.raw
        let task = operations.enqueue("Reading slot \(slot.display)",
                                      kind: .quick, slot: slot) { _ in
            try await device.read(slot: raw)
        }
        Task { @MainActor in
            defer { self.slots.setBusy(slot, false) }
            do {
                let preset = try await task.value
                self.slots.applyRead(slot, preset: preset)
                self.history.record(.observed, slot: slot,
                                    identity: self.deviceIdentity,
                                    summary: "Read '\(preset.name)'",
                                    sha256: preset.sha256)
                self.recomputeSync()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
        return task
    }

    /// Retry a failed name read (row context menu / detail, UX §5).
    func retryName(_ slot: SlotID) {
        guard let device else { return }
        slots.setBusy(slot, true)
        let raw = slot.raw
        let task = operations.enqueue("Reading name \(slot.display)",
                                      kind: .quick, slot: slot) { _ in
            try await device.name(slot: raw)
        }
        Task { @MainActor in
            defer { self.slots.setBusy(slot, false) }
            do {
                let name = try await task.value
                self.slots.applyStreamedName(slot, name: name)
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    private func recordSnapshotObservations(_ snapshot: DeviceSnapshot) {
        // One journal line per observed rename-from-panel would be noise;
        // observations are recorded per-read in detail flows instead.
        _ = snapshot
    }

    // ================================================ quick-op error surface

    /// UX §14 mapping for quick (toast-grade) failures.
    func surfaceQuickError(_ error: FreakError, slot: SlotID?) {
        switch error {
        case .deviceTimeout(let stage, _):
            var message = "Device stopped responding"
            if let slot {
                message += " (slot \(slot.display), \(stage.rawValue))"
            }
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= 2 {
                message += " — check the cable and the synth's power."
            }
            toasts.show(message, isError: true)
        case .replyMismatch:
            // The lag defense already retried 3×; surfacing means something
            // is genuinely wrong (UX §14).
            toasts.show("Device is answering for the wrong slot — "
                + "unplug/replug and retry.", isError: true)
        case .transport, .transportUnavailable:
            handleTransportLoss(error)
        case .operationCancelled:
            break  // expected path, never a red surface (UX §14)
        case .invalidName:
            toasts.show(NameRules.ruleCopy, isError: true)
        default:
            consecutiveTimeouts = 0
            toasts.show(error.userMessage, isError: true)
        }
    }

    private var consecutiveTimeouts = 0

    /// Unplug / transport failure mid-op: state → noDevice, cache kept and
    /// marked stale; a resumable backup shows Resume on reconnect (UX §14).
    func handleTransportLoss(_ error: FreakError) {
        toasts.show(error.userMessage, isError: true)
        if let old = device {
            Task { await old.close() }
        }
        device = nil
        pacer = nil
        connection = .noDevice(banner: "Device disconnected — showing last "
            + "known state")
        slots.markStale()
    }
}
