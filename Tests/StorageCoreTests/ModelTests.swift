import Testing
import Foundation
@testable import StorageCore

@Suite struct ModelTests {
    @Test func nodeCodableRoundTrip() throws {
        let child = Node(name: "a.bin", isDirectory: false, allocatedSize: 4096, logicalSize: 10,
                         inode: 7, devID: 1, modified: Date(timeIntervalSince1970: 1000))
        let root = Node(name: "r", isDirectory: true, allocatedSize: 4096, logicalSize: 10,
                        inode: 2, devID: 1, modified: Date(timeIntervalSince1970: 2000), children: [child])
        let data = try JSONEncoder().encode(root)
        #expect(try JSONDecoder().decode(Node.self, from: data) == root)
    }

    @Test func attributionCodableRoundTrip() throws {
        let a = Attribution(appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                            iconSource: .bundleID("com.anthropic.claudefordesktop"),
                            confidence: .inferred, rule: "접두 절단", isOrphanSuspect: false)
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(Attribution.self, from: data) == a)
    }

    @Test func catalogEntryDecodesWithDefaults() throws {
        let json = #"{"id":"pip","title":"pip","pathPatterns":["~/Library/Caches/pip"],"safety":"safe","method":"trash"}"#
        let e = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))
        #expect(e.excludePatterns.isEmpty && e.command == nil && e.safety == .safe && e.method == .trash)
        let back = try JSONDecoder().decode(CatalogEntry.self, from: JSONEncoder().encode(e))
        #expect(back == e)
    }

    @Test func datalessPolicyCallSucceeds() {
        #expect(disableDatalessMaterialization())
    }
}
