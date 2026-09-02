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
    // Audition is not a destination — it is an action on the list you are
    // looking at (UX addendum §30). Collections are a single destination; the
    // content column lists them, the detail column opens one.
    case collections                   // UX addendum §26
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
    let audition = AuditionModel()
    /// Spoken notes taken DURING an audition (docs/voice-notes.md). Opt-in,
    /// default off, and inert until an audition arms it: constructing it
    /// touches no microphone and no audio session.
    ///
    /// On the SIMULATOR and in #Previews it is built over `ScriptedTranscriber`
    /// — the same substitution `SimulatedMicroFreak` makes for a synth that is
    /// not attached. `SpeechTranscriber` is hardware-gated and
    /// `isAvailable` is false in the Simulator, so without this every voice
    /// surface (the toggle, the readiness rows, the live transcript, the
    /// listening pill, the ghosted chips) collapsed to one dead-end line and
    /// could not be seen, laid out or reviewed anywhere. The panel says the
    /// speech is scripted so nothing here can be mistaken for a real capture.
    let voiceNotes: VoiceNoteModel
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
    var sendPlanRun: BatchRunState?
    var restoreRun: BatchRunState?
    var slotPickerRequest: SlotPickerRequest?
    /// "MicroFreak detected — Connect?" (hot-plug; never auto-connects, UX §12).
    var hotPlugBanner: String?
    /// A borrowed audition slot whose original was never written back (the app
    /// was terminated mid-session, or the user gave up on restoring it now).
    /// Loaded from disk at launch; the passive banner offers to put it back.
    /// Written only by the loan helpers in AppModelAudition.swift.
    var pendingAuditionLoan: AuditionLoan?

    /// The Sync screen's chosen comparison baseline — a collection id. Sync
    /// compares the device against ONE named arrangement, never against the
    /// flat catalog (which has no slot opinion). App-layer only: persisted in
    /// UserDefaults per device identity, no core or on-disk format change.
    var syncBaselineID: String? {
        didSet {
            guard oldValue != syncBaselineID else { return }
            let key = Self.syncBaselineKey(deviceIdentity)
            if let syncBaselineID {
                UserDefaults.standard.set(syncBaselineID, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            recomputeSync()
        }
    }

    static func syncBaselineKey(_ identity: DeviceIdentity) -> String {
        "MFSyncBaseline.\(identity.stamp)"
    }

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

    /// `ScriptedTranscriber` where the real one cannot exist, nil on device.
    @MainActor
    static func defaultVoiceTranscriber() -> (any VoiceNoteTranscribing)? {
        #if targetEnvironment(simulator)
        return ScriptedTranscriber()
        #else
        return nil
        #endif
    }

    init(paths: AppPaths = .documents(), seedFromBundle: Bool = true,
         voiceTranscriber: (any VoiceNoteTranscribing)? =
            AppModel.defaultVoiceTranscriber()) {
        self.paths = paths
        self.voiceNotes = VoiceNoteModel(transcriber: voiceTranscriber)
        self.fastPracticeTiming = UserDefaults.standard
            .bool(forKey: "MFFastPracticeTiming")
        self.history = SlotHistoryStore(url: paths.historyURL)
        // A record here means a previous run borrowed a slot and never got it
        // back — the app owes the user that preset before anything else.
        self.pendingAuditionLoan = AuditionLoanStore.load(paths.auditionLoanURL)
        try? FileManager.default.createDirectory(
            at: paths.backupsRoot, withIntermediateDirectories: true)
        libraryModel = LibraryModel(root: paths.libraryRoot,
                                    seedFromBundle: seedFromBundle)
        backups = BackupsModel(root: paths.backupsRoot)
        libraryModel.onChange = { [weak self] in
            self?.recomputeSync()
        }
        libraryModel.openOrCreate()
        // Fold the bundled seed into an existing library once (fresh installs
        // already got it via the copy path), then mirror collections. Runs off
        // the init path because the merge needs the open Library actor.
        Task { [seedFromBundle] in
            if seedFromBundle, let lib = libraryModel.library {
                let merged = await SeedInstaller.mergeIfNeeded(into: lib)
                // One-time repair for installs merged before dedup shipped.
                await SeedInstaller.dedupeIfNeeded(lib)
                // Order matters: dedupe first (merged duplicates collapse and
                // their claims merge), THEN de-pollute the slot claims every
                // pre-fix bank import stamped onto the flat catalog. The
                // repair only runs once the merge has actually landed the
                // collections that explain those claims — otherwise it would
                // mark itself done over a library that has none of them.
                await SeedInstaller.repairSlotClaimsIfNeeded(lib,
                                                             seedMerged: merged)
                await libraryModel.refresh()
            }
            await collectionsModel.refresh(from: libraryModel.library)
        }
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
        // Deliberately dropping the device out from under a borrowed slot is
        // refused while that slot can still be put back through it.
        if device != nil, let reason = audition.blockReason {
            toasts.show(reason, isError: true)
            return
        }
        teardownDevice()
        connection = .noDevice(banner: nil)
    }

    /// Switching devices mid-operation is refused (UX §11, §12) — and so is
    /// switching while an audition still has one of the user's slots on loan
    /// AND a device to put it back through.
    ///
    /// The "and a device" half is load-bearing. Blocking unconditionally was a
    /// trap with no exit: a transport loss mid-audition cleared `device`, so
    /// Stop refused ("reconnect first") while every reconnect route refused
    /// ("stop the audition first"), and the only copy of the user's preset
    /// lived in memory. With no device attached there is nothing to protect
    /// here — reconnecting IS the route back, and the session (plus its
    /// on-disk loan record) survives the switch untouched.
    func canSwitchDevice() -> Bool {
        guard operations.active.isEmpty else {
            toasts.show("Finish or cancel the running operation before "
                + "switching devices.", isError: true)
            return false
        }
        if device != nil, let reason = audition.blockReason {
            toasts.show(reason, isError: true)
            return false
        }
        return true
    }

    private func adoptIdentity(_ identity: DeviceIdentity) {
        deviceIdentity = identity
        freshness.adoptIdentity(identity)
        freshness.noteBackups(backups.items, identity: identity)
        // The sync baseline is per identity: the collection you last compared
        // (or applied) on this device.
        syncBaselineID = UserDefaults.standard
            .string(forKey: Self.syncBaselineKey(identity))
    }

    private func teardownDevice() {
        if let old = device {
            Task { await old.close() }
        }
        device = nil
        pacer = nil
        deviceIdentity = .none
        // Identity switch drops the slot cache, the diff and its baseline; the
        // library and backups are device-independent and kept (UX §11). The
        // baseline is re-read from defaults when an identity is adopted again.
        slots.reset()
        syncBaselineID = nil
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
        // A live audition keeps its session (and `needsRestore`) across the
        // loss — restoring is impossible NOW, not forever. The banner stays up
        // and Stop works again once a device is back.
        audition.deviceLost()
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
