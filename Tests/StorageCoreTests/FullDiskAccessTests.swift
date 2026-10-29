import Testing
import Foundation
@testable import StorageCore

@Suite struct FullDiskAccessTests {
    private func makeHome() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("sl-fda-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Library"), withIntermediateDirectories: true)
        return h
    }

    @Test func grantedWhenSafariOpens() throws {
        let h = try makeHome(); defer { try? FileManager.default.removeItem(at: h) }
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Library/Safari"), withIntermediateDirectories: false)
        #expect(FullDiskAccess.check(home: h) == .granted)
    }

    @Test func grantedViaMailFallback() throws {
        let h = try makeHome(); defer { try? FileManager.default.removeItem(at: h) }
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Library/Mail"), withIntermediateDirectories: false)
        #expect(FullDiskAccess.check(home: h) == .granted)
    }

    @Test func undeterminedWhenNeitherExists() throws {
        let h = try makeHome(); defer { try? FileManager.default.removeItem(at: h) }
        #expect(FullDiskAccess.check(home: h) == .undetermined)
    }

    @Test func deniedWhenSafariUnreadable() throws {
        let h = try makeHome()
        let safari = h.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: false)
        chmod(safari.path, 0o000)
        defer { chmod(safari.path, 0o755); try? FileManager.default.removeItem(at: h) }
        #expect(FullDiskAccess.check(home: h) == .denied)
    }
}
