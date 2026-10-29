import Testing
import Foundation
@testable import StorageCore

@Suite struct CatalogTests {
    static let home = "/Users/tester"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func loadCatalog() throws -> Catalog {
        return try TestSupport.loadCatalog()
    }

    static func matcher(tools: Set<String> = ["uv", "xcrun"]) throws -> CatalogMatcher {
        CatalogMatcher(catalog: try loadCatalog(), home: home, clock: FixedClock(now: now),
                       toolResolver: { tools.contains($0) ? URL(fileURLWithPath: "/fake/bin/\($0)") : nil })
    }

    @Test func loadsEighteenEntries() throws {
        let c = try Self.loadCatalog()
        #expect(c.entries.count == 18)
        #expect(c.entry(id: "downloads-old")?.minAgeDays == 90)
        #expect(c.entry(id: "uv")?.command == CatalogCommand(tool: "uv", args: ["cache", "clean"]))
        #expect(c.entry(id: "xcode-sim-unavailable")?.pathPatterns.isEmpty == true)
        #expect(c.entry(id: "huggingface")?.safety == .discouraged)
        #expect(c.virtualEntries.map(\.id) == ["xcode-sim-unavailable"])
    }

    @Test func specificPatternWins() throws {
        let m = try Self.matcher()
        #expect(try #require(m.match(path: "\(Self.home)/Library/Caches/pip")).entry.id == "pip")
        #expect(try #require(m.match(path: "\(Self.home)/Library/Caches/Foo")).entry.id == "user-caches")
        let hb = try #require(m.match(path: "\(Self.home)/Library/Caches/Homebrew/downloads/x.tar/inner"))
        #expect(hb.entry.id == "homebrew")
        #expect(hb.matchedRoot == "\(Self.home)/Library/Caches/Homebrew/downloads/x.tar")
    }

    @Test func appleCachesExcludedFromUserCaches() throws {
        let m = try Self.matcher()
        #expect(try #require(m.match(path: "\(Self.home)/Library/Caches/com.apple.Safari")).entry.id == "apple-caches")
    }

    @Test func descendantBelongsToMatchedRoot() throws {
        let m = try Self.matcher()
        let r = try #require(m.match(path: "\(Self.home)/Library/Caches/Foo/a/b.bin"))
        #expect(r.entry.id == "user-caches")
        #expect(r.matchedRoot == "\(Self.home)/Library/Caches/Foo")
        #expect(m.match(path: "\(Self.home)/Library/Caches") == nil)
        #expect(m.match(path: "\(Self.home)/Documents/x")?.entry.id == "personal-files")
        let icloud = try #require(m.match(path: "\(Self.home)/Library/Mobile Documents/com~apple~CloudDocs/f.txt"))
        #expect(icloud.entry.id == "icloud-local" && icloud.effectiveMethod == .icloudEvict)
    }

    @Test func v11Entries() throws {
        let c = try Self.loadCatalog()
        for id in ["huggingface", "app-support", "containers", "app-preferences", "personal-files"] {
            #expect(c.entry(id: id)?.safety == .discouraged && c.entry(id: id)?.method == .trash, "\(id)")
        }
        #expect(c.entry(id: "saved-state")?.safety == .safe)
        #expect(c.entry(id: "app-support")?.title == "앱 데이터 (Application Support)")
        #expect(!c.entries.contains { $0.method == .none })
        let m = try Self.matcher()
        #expect(m.match(path: "\(Self.home)/Library/Preferences/com.foo.plist")?.entry.id == "app-preferences")
        #expect(m.match(path: "\(Self.home)/Library/Preferences/com.apple.finder.plist") == nil)
        #expect(m.match(path: "\(Self.home)/Library/Saved Application State/com.foo.savedState")?.entry.id == "saved-state")
        for d in ["Documents", "Desktop", "Pictures", "Movies", "Music"] {
            #expect(m.match(path: "\(Self.home)/\(d)/a/b")?.entry.id == "personal-files", "\(d)")
        }
    }

    @Test func legacyNeverDecodesAsDiscouraged() throws {
        let json = #"[{"id":"x","title":"t","pathPatterns":["~/x"],"safety":"never","method":"none"}]"#
        let c = try Catalog.load(from: Data(json.utf8))
        #expect(c.entries[0].safety == .discouraged)
        let bad = #"[{"id":"x","title":"t","safety":"bogus","method":"none"}]"#
        #expect(throws: (any Error).self) { try Catalog.load(from: Data(bad.utf8)) }
    }

    @Test func personalFolderFallbackForUnclassified() throws {
        let m = CatalogMatcher(catalog: Catalog(entries: []), home: Self.home, toolResolver: { _ in nil })
        #expect(m.isUnderPersonalFolder("\(Self.home)/Documents/a"))
        #expect(m.isUnderPersonalFolder("\(Self.home)/documents/a"))
        #expect(!m.isUnderPersonalFolder("\(Self.home)/Documents"))
        #expect(!m.isUnderPersonalFolder("\(Self.home)/Projects/a"))
        let av = CleanupAvailability.from(match: nil, path: "p", inPersonalFolder: true)
        #expect(av.enabled && av.safety == .discouraged && av.isDiscouraged && !av.isBatchable)
    }

    @Test func orphanBeatsNever() throws {
        let m = try Self.matcher()
        let p = "\(Self.home)/Library/Application Support/Gone"
        #expect(try #require(m.match(path: p)).entry.id == "app-support")
        let orphan = Attribution(appName: "x", confidence: .inferred, rule: "r", isOrphanSuspect: true)
        let r = try #require(m.match(path: p, attribution: orphan))
        #expect(r.entry.id == "orphan" && r.effectiveMethod == .trash)
    }

    @Test func minAgeDaysFilter() throws {
        let m = try Self.matcher()
        let p = "\(Self.home)/Downloads/big.dmg"
        let old = Self.now.addingTimeInterval(-91 * 86400), young = Self.now.addingTimeInterval(-10 * 86400)
        #expect(m.match(path: p, modified: { _ in old })?.entry.id == "downloads-old")
        #expect(m.match(path: p, modified: { _ in young }) == nil)
        #expect(m.match(path: p) == nil)
    }

    @Test func missingToolMeansNone() throws {
        let p = "\(Self.home)/.cache/uv"
        let ok = try #require(try Self.matcher().match(path: p))
        #expect(ok.effectiveMethod == .command && ok.toolURL?.path == "/fake/bin/uv")
        let no = try #require(try Self.matcher(tools: []).match(path: p))
        #expect(no.effectiveMethod == .none && no.unavailableReason == "도구 없음")
        let m = try Self.matcher(tools: [])
        let sim = m.resolve(try #require(m.catalog.entry(id: "xcode-sim-unavailable")))
        #expect(sim.effectiveMethod == .none)
    }

    @Test func huggingFaceInventory() throws {
        #expect(HuggingFaceInventory.displayName("models--a--b", prefix: "models--") == "a/b")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = root.appendingPathComponent("hub")
        for d in ["models--org--m1", "datasets--org--d1", "blobs", "other"] {
            try FileManager.default.createDirectory(at: hub.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let l = HuggingFaceInventory.list(cacheRoot: root)
        #expect(l.items.map(\.name) == ["org/d1", "org/m1"])
        #expect(l.items.map(\.kind) == [.dataset, .model])
        #expect(l.blobsExists && l.blobsPath.lastPathComponent == "blobs")
        let empty = HuggingFaceInventory.list(cacheRoot: root.appendingPathComponent("none"))
        #expect(empty.items.isEmpty && !empty.blobsExists)
    }
}
