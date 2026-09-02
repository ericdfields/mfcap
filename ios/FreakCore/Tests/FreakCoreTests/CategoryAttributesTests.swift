// CategoryAttributesTests.swift — the Category device-byte table + slug
// round-trip, and the additive library-index attributes (category/favorite/
// tags) with old-index back-compat and the category census. Expected values
// come from the Python-generated category.json / library_attrs.json vectors.

import Foundation
import Testing
@testable import FreakCore

@Suite("Category & attributes (vectors)")
struct CategoryAttributesTests {

    // ------------------------------------------------------------ category

    @Test func deviceByteDecodeAndSlugRoundTrip() throws {
        let cases = try Vectors.cases("category.json")

        let decode = cases.first { $0["name"] as! String == "device_byte_decode" }!
        for row in decode["decode"] as! [[String: Any]] {
            let byte = UInt8(int(row, "byte"))
            #expect(Category.fromDeviceByte(byte).slug == str(row, "slug"),
                    "byte \(byte)")
        }

        let round = cases.first { $0["name"] as! String == "slug_roundtrip" }!
        for slug in round["slugs"] as! [String] {
            #expect(Category.fromSlug(slug).slug == slug, "slug \(slug) round-trips")
        }
        // an unknown slug loads as uncategorized (forward compat), never a crash
        #expect(Category.fromSlug(str(round, "unknown_slug")).slug
                == str(round, "unknown_expected"))
    }

    // ---------------------------------------------------------- attributes

    /// Round-trip + old-index-defaults cases: write each fixture entry dict as
    /// an index.json, open the library, and assert the parsed category /
    /// favorite / tags match the fixture's expected values (defaults applied
    /// where the keys are absent).
    @Test func libraryEntryAttributeParsingAgainstVectors() async throws {
        let cases = try Vectors.cases("library_attrs.json")
        var seen = 0
        for c in cases {
            let name = c["name"] as! String
            guard name.hasPrefix("roundtrip_") || name == "old_index_defaults" else {
                continue
            }
            seen += 1
            let entryJSON = c["entry_json"] as! [String: Any]
            let expected = c["expected"] as! [String: Any]

            let root = tempDir("attrs-vec-\(name)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
            let index: [String: Any] = ["schema": 1, "entries": [entryJSON]]
            try AtomicFile.write(
                try JSONSerialization.data(withJSONObject: index),
                to: root.appendingPathComponent("index.json"))

            let lib = try Library.open(at: root)
            let e = try await lib.entry(id: entryJSON["id"] as! String)
            #expect(e.category.slug == expected["category"] as! String, "\(name)")
            #expect(e.favorite == expected["favorite"] as! Bool, "\(name)")
            #expect(e.tags == expected["tags"] as! [String], "\(name)")
        }
        #expect(seen == 4, "three round-trip cases + old_index_defaults")
    }

    @Test func categoryCensusAgainstVector() throws {
        let cases = try Vectors.cases("library_attrs.json")
        let c = cases.first { $0["name"] as! String == "category_census" }!
        let entries = (c["entries"] as! [[String: Any]]).enumerated().map { i, d in
            LibraryEntry(id: "c\(i)", name: "N\(i)", sha256: "s\(i)",
                         metaHex: testMeta.hexString, slot: nil,
                         addedAt: "2026-09-01T00:00:00", tags: [],
                         category: Category.fromSlug(str(d, "category")))
        }
        let census = Attributes.categoryCensus(entries)
        let expected = c["expected_census"] as! [String: Any]
        for cat in Category.allCases {
            #expect(census[cat] == (expected[cat.slug] as! NSNumber).intValue,
                    "census[\(cat.slug)]")
        }
    }
}
