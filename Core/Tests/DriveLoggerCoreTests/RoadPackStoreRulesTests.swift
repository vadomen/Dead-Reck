import Foundation
import Testing

@testable import DriveLoggerCore

/// N3.4 item 2: store file names, one active file per pack name, deletion
/// only at launch. Pure: no file system. Synthetic pack names only.
@Suite("Road pack store rules (N3.4 item 2)")
struct RoadPackStoreRulesTests {
    typealias R = RoadPackStoreRules
    typealias F = RoadPackStoreRules.InstalledFile

    static let hashA = "0123456789abcdef"
    static let hashB = "fedcba9876543210"
    static let hashC = "00000000000000ff"

    // MARK: File names

    @Test("fileName: <name>-<16 hex>.roadpack, from text or from the header's UInt64 (zero-padded)")
    func fileNames() {
        #expect(R.fileName(name: "region-a", contentHash: Self.hashA) == "region-a-0123456789abcdef.roadpack")
        #expect(R.fileName(name: "national", contentHash: UInt64(0xff)) == "national-00000000000000ff.roadpack")
        #expect(R.fileName(name: "region_b2", contentHash: UInt64.max) == "region_b2-ffffffffffffffff.roadpack")
        #expect(R.contentHashText(0x1) == "0000000000000001")
    }

    @Test("fileName refuses an invalid name or hash")
    func fileNameRefusals() {
        for name in ["", "Region-a", "region a", "region/a", "../a", ".a", "-a", "a-", "région",
                     String(repeating: "a", count: R.maxNameLength + 1)] {
            #expect(R.fileName(name: name, contentHash: Self.hashA) == nil, "name \(name)")
        }
        #expect(R.fileName(name: String(repeating: "a", count: R.maxNameLength), contentHash: Self.hashA) != nil)
        for hash in ["", "0123456789ABCDEF", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeg", " 123456789abcdef"] {
            #expect(R.fileName(name: "region-a", contentHash: hash) == nil, "hash \(hash)")
        }
    }

    @Test("parseFileName splits on the last '-' and round-trips fileName")
    func parse() throws {
        let parsed = try #require(R.parseFileName("region-a-0123456789abcdef.roadpack"))
        #expect(parsed.name == "region-a" && parsed.contentHash == Self.hashA)
        #expect(parsed.contentHashValue == 0x0123456789abcdef)
        // A name may itself end in something hash-like: only the last part is the hash.
        let nested = try #require(R.parseFileName("a-fedcba9876543210-0123456789abcdef.roadpack"))
        #expect(nested.name == "a-fedcba9876543210" && nested.contentHash == Self.hashA)
        for name in ["national", "region-b", "x_1-2"] {
            for hash in [Self.hashA, Self.hashB, Self.hashC] {
                let file = try #require(R.fileName(name: name, contentHash: hash))
                #expect(R.parseFileName(file) == .init(name: name, contentHash: hash))
            }
        }
    }

    @Test("parseFileName refuses anything fileName would not produce")
    func parseRefusals() {
        for file in [
            "region-a.roadpack",                          // no hash
            "region-a-0123456789abcde.roadpack",          // 15 digits
            "region-a-0123456789ABCDEF.roadpack",         // upper case
            "region-a-0123456789abcdef.roadpack.tmp",     // another extension
            "region-a-0123456789abcdef.ROADPACK",
            "region-a-0123456789abcdef",                  // no extension
            "-0123456789abcdef.roadpack",                 // empty name
            "Region-0123456789abcdef.roadpack",           // unsafe name
            "dir/region-0123456789abcdef.roadpack",       // a path
            "region--0123456789abcdef.roadpack",          // name ends with '-'
            ".install-1234.tmp",
            "",
        ] {
            #expect(R.parseFileName(file) == nil, "\(file)")
        }
    }

    @Test("inboxName: <name>.roadpack and <name>-<hash>.roadpack give <name>; unsafe names are refused")
    func inboxNames() {
        #expect(R.inboxName(fromFileName: "region-a.roadpack") == "region-a")
        #expect(R.inboxName(fromFileName: "national.roadpack") == "national")
        #expect(R.inboxName(fromFileName: "region-b-0123456789abcdef.roadpack") == "region-b")
        // Not a 16-digit hash: the whole stem is the name.
        #expect(R.inboxName(fromFileName: "region-b-12.roadpack") == "region-b-12")
        for file in ["Region-A.roadpack", "region a.roadpack", ".roadpack", "region-a.osm.pbf", "region-a",
                     "-region.roadpack", "region-.roadpack", "région.roadpack"] {
            #expect(R.inboxName(fromFileName: file) == nil, "\(file)")
        }
    }

    @Test("Temporary install files are never store files and are recognised as leftovers")
    func temporaries() {
        let t = R.temporaryFileName(token: "6F1C1D2E-0000-4000-8000-000000000001")
        #expect(R.isTemporaryFileName(t))
        #expect(R.parseFileName(t) == nil && R.inboxName(fromFileName: t) == nil)
        #expect(!R.isTemporaryFileName("region-a-0123456789abcdef.roadpack"))
        #expect(!R.isTemporaryFileName("notes.tmp"))
    }

    // MARK: The active set

    static func file(_ name: String, _ hash: String, osm: Int64, installed: Double, marked: Bool = false) -> F {
        F(fileName: R.fileName(name: name, contentHash: hash)!, name: name, contentHash: hash,
          osmTimestamp: osm, installTime: installed, markedForRemoval: marked)
    }

    @Test("One active file per name: newest osmTimestamp, then install time, then content hash; any listing order")
    func activeChoice() {
        let oldOSM = Self.file("region-a", Self.hashA, osm: 100, installed: 900)
        let newOSM = Self.file("region-a", Self.hashB, osm: 200, installed: 10)
        let other = Self.file("region-b", Self.hashC, osm: 50, installed: 1)
        for files in [[oldOSM, newOSM, other], [other, newOSM, oldOSM], [newOSM, other, oldOSM]] {
            let set = R.activeSet(files)
            #expect(set.active == [newOSM, other])
            #expect(set.superseded == [oldOSM])
            #expect(set.markedForRemoval.isEmpty)
        }
        // Equal osmTimestamp: the later install wins.
        let early = Self.file("region-a", Self.hashB, osm: 100, installed: 10)
        let late = Self.file("region-a", Self.hashA, osm: 100, installed: 20)
        #expect(R.activeSet([early, late]).active == [late])
        #expect(R.activeSet([late, early]).active == [late])
        // Equal osmTimestamp and install time: the greater content hash.
        let tieA = Self.file("region-a", Self.hashA, osm: 100, installed: 10)
        let tieB = Self.file("region-a", Self.hashB, osm: 100, installed: 10)
        #expect(R.activeSet([tieA, tieB]).active == [tieB])
        #expect(R.activeSet([tieB, tieA]).active == [tieB])
        #expect(R.activeSet([tieB, tieA]).superseded == [tieA])
        // An unknown osmTimestamp (0) is older than any known one.
        let unknown = Self.file("region-a", Self.hashC, osm: 0, installed: 1_000)
        #expect(R.activeSet([unknown, tieA]).active == [tieA])
        #expect(R.activeSet([]) == .init(active: [], superseded: [], markedForRemoval: []))
    }

    @Test("Marked files are never active: a name whose only file is marked has none; Remove marks every file of the name")
    func marked() {
        let only = Self.file("region-b", Self.hashC, osm: 300, installed: 5, marked: true)
        let a1 = Self.file("region-a", Self.hashA, osm: 100, installed: 1)
        let a2 = Self.file("region-a", Self.hashB, osm: 200, installed: 2, marked: true)
        let set = R.activeSet([only, a2, a1])
        #expect(set.active == [a1])
        #expect(set.superseded.isEmpty)
        #expect(set.markedForRemoval == [a2, only])
        // Remove marks every file of the name, so no older version comes back.
        let files = [a1, Self.file("region-a", Self.hashB, osm: 200, installed: 2), only]
        let toMark = R.filesToMark(removingName: "region-a", in: files)
        #expect(toMark == [a1.fileName, a2.fileName].sorted())
        let afterRemove = files.map { f -> F in
            var f = f
            if toMark.contains(f.fileName) { f.markedForRemoval = true }
            return f
        }
        #expect(R.activeSet(afterRemove).active.isEmpty)
    }

    @Test("launchCleanup deletes superseded, marked and leftover temporary files only; unknown files stay")
    func launch() {
        let a1 = Self.file("region-a", Self.hashA, osm: 100, installed: 1)
        let a2 = Self.file("region-a", Self.hashB, osm: 200, installed: 2)
        let b = Self.file("region-b", Self.hashC, osm: 50, installed: 3, marked: true)
        let n = Self.file("national", Self.hashA, osm: 10, installed: 4)
        let temp = R.temporaryFileName(token: "abc")
        let plan = R.launchCleanup([n, b, a2, a1], otherFileNames: [temp, "notes.txt", ".DS_Store"])
        #expect(plan.delete == [a1.fileName, b.fileName, temp].sorted())
        #expect(plan.active == [n, a2])
        #expect(plan.active == R.activeSet([a1, a2, b, n]).active)
        // Nothing to do on a clean store.
        #expect(R.launchCleanup([n, a2]).delete.isEmpty)
        // Every listed file is either active or deleted.
        let all = [a1, a2, b, n]
        #expect(Set(plan.delete + plan.active.map(\.fileName)).isSuperset(of: all.map(\.fileName)))
        #expect(Set(plan.delete).isDisjoint(with: plan.active.map(\.fileName)))
    }

    // MARK: Partial downloads (UX-8)

    @Test("Partial download names: .download-<name>-<hash>.part/.json, parsed back; never store or temporary files")
    func partialNames() throws {
        let part = try #require(R.partialFileName(name: "region-a", contentHash: Self.hashA))
        let meta = try #require(R.partialMetadataFileName(name: "region-a", contentHash: Self.hashA))
        #expect(part == ".download-region-a-0123456789abcdef.part")
        #expect(meta == ".download-region-a-0123456789abcdef.json")
        let stored = R.StoredFileName(name: "region-a", contentHash: Self.hashA)
        #expect(R.parseDownloadFileName(part) == .init(kind: .partial, pack: stored))
        #expect(R.parseDownloadFileName(meta) == .init(kind: .metadata, pack: stored))
        let nested = try #require(R.parseDownloadFileName(".download-a-fedcba9876543210-0123456789abcdef.part"))
        #expect(nested.pack == .init(name: "a-fedcba9876543210", contentHash: Self.hashA))
        #expect(R.partialFileName(name: "Region-a", contentHash: Self.hashA) == nil)
        #expect(R.partialMetadataFileName(name: "region-a", contentHash: "0123") == nil)
        for file in [".download-region-a.part", ".download-region-a-0123456789ABCDEF.part",
                     ".download-region-a-0123456789abcdef.tmp", "download-region-a-0123456789abcdef.part",
                     ".download-.part", ".download--0123456789abcdef.json", ".download-region-a-0123456789abcdef.roadpack",
                     "region-a-0123456789abcdef.roadpack", R.temporaryFileName(token: "abc")] {
            #expect(R.parseDownloadFileName(file) == nil, "\(file)")
        }
        for file in [part, meta] {
            #expect(R.parseFileName(file) == nil)
            #expect(F(fileName: file, osmTimestamp: 1, installTime: 1) == nil)
            #expect(R.inboxName(fromFileName: file) == nil)
            #expect(!R.isTemporaryFileName(file))
        }
    }

    @Test("launchCleanup keeps partial downloads and their metadata (they survive an app kill) and never activates them")
    func launchKeepsPartials() throws {
        let a = Self.file("region-a", Self.hashA, osm: 100, installed: 1)
        let part = try #require(R.partialFileName(name: "region-a", contentHash: Self.hashB))
        let meta = try #require(R.partialMetadataFileName(name: "region-a", contentHash: Self.hashB))
        let orphan = try #require(R.partialFileName(name: "zz-01", contentHash: Self.hashC))
        let temp = R.temporaryFileName(token: "abc")
        let plan = R.launchCleanup([a], otherFileNames: [part, meta, orphan, temp])
        #expect(plan.delete == [temp])
        #expect(plan.active == [a])
        #expect(!plan.active.map(\.fileName).contains(part))
        // Listing them as InstalledFiles is impossible: the initialiser refuses them.
        let candidates = [part, meta, orphan].compactMap { F(fileName: $0, osmTimestamp: 1, installTime: 1) }
        #expect(candidates.isEmpty)
    }

    @Test("stalePartials: partial and metadata files whose (name, contentHash) the manifest does not list")
    func stalePartials() throws {
        let url = URL(string: "https://packs.example.test/packs/manifest.json")!
        func pack(_ name: String, _ hash: String) -> PackManifest.Pack {
            PackManifest.Pack(name: name, kind: .region, titleUK: "", titleEN: "Region", bbox: .init(west: 10, south: 20, east: 11, north: 21),
                              url: url, size: 1, sha256: String(repeating: "0", count: 64), contentHash: hash,
                              formatVersion: 1, osmDate: nil, osmTimestamp: 0)
        }
        let manifest = PackManifest(manifestURL: url, generated: "", license: "", licenseURL: "", attribution: "",
                                    packs: [pack("region-a", Self.hashB), pack("national", Self.hashA)])
        let current = try #require(R.partialFileName(name: "region-a", contentHash: Self.hashB))
        let currentMeta = try #require(R.partialMetadataFileName(name: "region-a", contentHash: Self.hashB))
        let oldBuild = try #require(R.partialFileName(name: "region-a", contentHash: Self.hashA))
        let oldMeta = try #require(R.partialMetadataFileName(name: "region-a", contentHash: Self.hashA))
        let withdrawn = try #require(R.partialMetadataFileName(name: "zz-01", contentHash: Self.hashA))
        let national = try #require(R.partialFileName(name: "national", contentHash: Self.hashA))
        let files = [current, currentMeta, oldBuild, oldMeta, withdrawn, national,
                     "region-a-0123456789abcdef.roadpack", R.temporaryFileName(token: "x"), "notes.txt"]
        #expect(R.stalePartials(fileNames: files, manifest: manifest) == [oldMeta, oldBuild, withdrawn].sorted())
        #expect(R.stalePartials(fileNames: [current, national], manifest: manifest).isEmpty)
        let empty = PackManifest(manifestURL: url, generated: "", license: "", licenseURL: "", attribution: "", packs: [])
        #expect(R.stalePartials(fileNames: files, manifest: empty) == [current, currentMeta, oldBuild, oldMeta, withdrawn, national].sorted())
    }

    @Test("InstalledFile from a store file name; nil for anything else")
    func installedFromFileName() throws {
        let f = try #require(F(fileName: "region-a-0123456789abcdef.roadpack", osmTimestamp: 7, installTime: 8))
        #expect(f.name == "region-a" && f.contentHash == Self.hashA && f.osmTimestamp == 7 && f.installTime == 8)
        #expect(!f.markedForRemoval)
        #expect(F(fileName: "region-a.roadpack", osmTimestamp: 7, installTime: 8) == nil)
    }
}
