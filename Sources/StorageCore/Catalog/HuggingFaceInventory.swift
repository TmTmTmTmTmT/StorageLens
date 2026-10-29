import Foundation

/// Hugging Face 캐시 읽기 전용 목록 (PLAN §6.3). 크기는 스캔 결과에서 UI가 채운다.
public enum HuggingFaceInventory {
    public struct Item: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable { case model, dataset }
        public var kind: Kind
        /// `models--a--b` -> `a/b`
        public var name: String
        public var path: URL
        public var modified: Date
    }

    public struct Listing: Sendable, Equatable {
        public var items: [Item]
        public var blobsPath: URL
        public var blobsExists: Bool
        public var blobsModified: Date?
    }

    /// - Parameter cacheRoot: `~/.cache/huggingface` (하위 `hub/`를 읽는다).
    public static func list(cacheRoot: URL, fileSystem: any FileSystem = SystemFileSystem()) -> Listing {
        let hub = cacheRoot.appendingPathComponent("hub")
        let blobs = hub.appendingPathComponent("blobs")
        var items: [Item] = []
        for e in (try? fileSystem.entries(in: hub)) ?? [] where e.isDirectory && !e.isSymlink {
            let kind: Item.Kind, prefix: String
            if e.name.hasPrefix("models--") { kind = .model; prefix = "models--" }
            else if e.name.hasPrefix("datasets--") { kind = .dataset; prefix = "datasets--" }
            else { continue }
            items.append(Item(kind: kind, name: displayName(e.name, prefix: prefix),
                              path: hub.appendingPathComponent(e.name), modified: e.modified))
        }
        items.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        let blobsAttr = try? fileSystem.attributes(at: blobs)
        return Listing(items: items, blobsPath: blobs, blobsExists: blobsAttr != nil,
                       blobsModified: blobsAttr?.modified)
    }

    public static func displayName(_ folder: String, prefix: String) -> String {
        String(folder.dropFirst(prefix.count)).replacingOccurrences(of: "--", with: "/")
    }
}
