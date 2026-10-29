import Testing
import Foundation
@testable import StorageCore

@Suite struct OutsideHomeAvailabilityTests {
    private static let home = AppDataTests.home
    private func outcome() throws -> ScanOutcome { try AppDataTests.outcome(tree: AppDataTests.tree()) }

    @Test func outsideHomeDisabled() throws {
        let a = try outcome().cleanupAvailability(forPath: "/Library/Application Support/TeamViewer")
        #expect(!a.enabled)
        #expect(a.isOutsideHome)
        #expect(a.reason == CleanupAvailability.outsideHomeReason)
        #expect(a.reason?.contains("Finder") == true)
    }

    @Test func prefixSiblingIsOutside() throws {
        #expect(try outcome().cleanupAvailability(forPath: Self.home + "x/foo").isOutsideHome)
    }

    @Test func insideHomeUnchanged() throws {
        let a = try outcome().cleanupAvailability(forPath: Self.home + "/Documents/foo")
        #expect(!a.isOutsideHome)
        #expect(a.enabled)
    }

    @Test func dataVolumePrefixInsideHome() throws {
        let a = try outcome().cleanupAvailability(forPath: "/System/Volumes/Data" + Self.home + "/Library/Caches/com.foo.Alpha")
        #expect(!a.isOutsideHome)
    }

    @Test func dataVolumePrefixOutside() throws {
        #expect(try outcome().cleanupAvailability(forPath: "/System/Volumes/Data/Library/Foo").isOutsideHome)
    }

    @Test func homeItselfNotFlagged() throws {
        #expect(!(try outcome().cleanupAvailability(forPath: Self.home).isOutsideHome))
    }
}
