// PresetTransfer.swift — the one Transferable type every drag, drop, copy
// and paste moves through (UX §5.6), plus the .mfpreset file format.
//
// .mfpreset is JSON: {"name", "meta_hex", "blob_hex"} — self-contained and
// portable (blob 4672 bytes, meta 9 bytes, both 7-bit clean, enforced by
// Preset.init on decode).
//
// Two representations (UX §8.1): in-app drags move a lightweight REFERENCE
// (library id / device slot / backup slot) under a private UTType; drags
// leaving the app lazily export a real, self-contained .mfpreset file —
// resolved through the same cheapest-honest-source path as any send — so a
// file dropped in Files always re-imports (here or in the Python tooling).
// Dropped .mfpreset files import as a self-contained `.file` transfer.

import CoreTransferable
import Foundation
import FreakCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let mfPreset = UTType(exportedAs: "com.ericbrookfield.mfpreset")
    /// In-app drag payload — a reference, never preset content. Kept
    /// distinct from .mfPreset so a drag to Files can never write reference
    /// JSON under the .mfpreset extension.
    static let mfPresetRef =
        UTType(exportedAs: "com.ericbrookfield.freaklibrarian.presetref")
}

struct PresetTransfer: Transferable, Codable, Sendable, Hashable {
    enum Source: Codable, Sendable, Hashable {
        case library(entryID: String)
        case deviceSlot(SlotID)          // blob may need a read on drop
        case backup(path: String, slot: SlotID)
        case file(MFPresetFile)          // imported .mfpreset content
    }

    let source: Source
    let displayName: String

    static var transferRepresentation: some TransferRepresentation {
        // In-app drops (slot rows, library list) load the reference.
        CodableRepresentation(contentType: .mfPresetRef)
        // Drags leaving the app export the real preset file, lazily.
        FileRepresentation(exportedContentType: .mfPreset) { transfer in
            SentTransferredFile(
                try await PresetTransferExporter.exportFile(transfer),
                allowAccessingOriginalFile: false)
        }
        // .mfpreset files (or raw 4672-byte blobs) dropped into the app.
        DataRepresentation(importedContentType: .mfPreset) { data in
            let preset = try MFPresetFile.decode(data: data,
                                                 filename: "Imported")
            return PresetTransfer(source: .file(MFPresetFile(preset)),
                                  displayName: preset.name)
        }
    }
}

/// Resolves a transfer to real bytes for drag-out export. The AppModel
/// registers itself at init; resolution runs the same
/// cheapest-honest-source path as a send (library/backup from disk, device
/// slots one ~400 ms read).
@MainActor
enum PresetTransferExporter {
    static weak var model: AppModel?

    static func exportFile(_ transfer: PresetTransfer) async throws -> URL {
        guard let model else {
            throw FreakError.transport(detail: "app not ready to export")
        }
        let preset = try await model.resolveTransfer(transfer)
        let data = try JSONEncoder().encode(MFPresetFile(preset))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfpreset-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let stem = preset.name.isEmpty ? "Preset" : preset.name
        let url = dir.appendingPathComponent(stem)
            .appendingPathExtension("mfpreset")
        try data.write(to: url)
        return url
    }
}

// ------------------------------------------------------- .mfpreset on disk

struct MFPresetFile: Codable, Sendable, Hashable {
    let name: String
    let meta_hex: String
    let blob_hex: String

    init(_ preset: Preset) {
        name = preset.name
        meta_hex = preset.meta.map { String(format: "%02x", $0) }.joined()
        blob_hex = preset.blob.map { String(format: "%02x", $0) }.joined()
    }

    func preset() throws -> Preset {
        guard let meta = Self.data(hex: meta_hex),
              let blob = Self.data(hex: blob_hex) else {
            throw FreakError.integrity(path: "mfpreset",
                                       detail: "unparseable hex payload")
        }
        return try Preset(name: name, blob: blob, meta: meta)
    }

    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var iterator = hex.makeIterator()
        while let hi = iterator.next() {
            guard let lo = iterator.next(),
                  let byte = UInt8("\(hi)\(lo)", radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// Decode an imported file: .mfpreset JSON, or a raw 4672-byte blob
    /// (which carries no name/meta — the filename becomes the name, meta is
    /// neutral zeros; the write path recomputes the positional bytes).
    ///
    /// CAUTION on the zero meta: core-api.md treats meta as opaque
    /// bookkeeping round-tripped verbatim into long-0x52 bytes 4..7, and
    /// every hardware-captured write carried real device-read values — an
    /// all-zero meta is a combination never observed on hardware. It is
    /// accepted here so raw blobs remain importable at all, but a preset
    /// from a real read (or .mfpreset JSON) is always preferable.
    static func decode(data: Data, filename: String) throws -> Preset {
        if let file = try? JSONDecoder().decode(MFPresetFile.self, from: data) {
            return try file.preset()
        }
        guard data.count == SlotID.Layout.blobBytes else {
            throw FreakError.blobSize(expected: SlotID.Layout.blobBytes,
                                      actual: data.count)
        }
        let stem = (filename as NSString).deletingPathExtension
        let cleaned = String(stem.unicodeScalars
            .filter { NameRules.isAllowedScalar($0) }
            .prefix(NameRules.maxLength))
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Imported" : cleaned
        return try Preset(name: name, blob: data, meta: Data(count: 9))
    }
}

/// FileDocument for .fileExporter (Export as .mfpreset).
struct MFPresetDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.mfPreset, .json]

    let preset: Preset

    init(preset: Preset) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        preset = try MFPresetFile.decode(data: data, filename: "Imported")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(MFPresetFile(preset))
        return FileWrapper(regularFileWithContents: data)
    }
}
