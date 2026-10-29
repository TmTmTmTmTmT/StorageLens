import Foundation

/// iCloud 컨테이너 한 개 (`~/Library/Mobile Documents` 직속 자식).
public struct ICloudContainer: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var folderName: String
    public var displayName: String
    public var bundleID: String?
    public var path: String
    /// 로컬에 실제 저장된 크기 (할당 크기 합).
    public var localBytes: Int64
    /// 클라우드 전용(dataless) 파일 수.
    public var cloudOnlyFileCount: Int
    public var fileCount: Int
}

public struct ICloudFolder: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var localBytes: Int64
}

/// iCloud 로컬 사본 인벤토리 (PLAN §16.4).
public struct ICloudInventory: Sendable, Equatable {
    public var containers: [ICloudContainer]
    public var totalLocalBytes: Int64 { containers.reduce(0) { $0 + $1.localBytes } }
    public var totalCloudOnly: Int { containers.reduce(0) { $0 + $1.cloudOnlyFileCount } }
    public var totalFileCount: Int { containers.reduce(0) { $0 + $1.fileCount } }

    static let driveFolder = "com~apple~CloudDocs"

    static func build(outcome: ScanOutcome) -> ICloudInventory {
        build(root: outcome.root, logicalRootPath: outcome.logicalRootPath, home: outcome.matcher.homePath,
              appIndex: outcome.appIndex)
    }

    static func build(root: Node, logicalRootPath: String, home: String, appIndex: (any AppIndex)?) -> ICloudInventory {
        let dir = home + "/Library/Mobile Documents"
        guard let md = ScanOutcome.find(root: root, rootPath: logicalRootPath, path: dir) else {
            return ICloudInventory(containers: [])
        }
        var list: [ICloudContainer] = md.children.filter(\.isDirectory).map { c in
            var files = 0, cloud = 0
            count(c, files: &files, cloud: &cloud)
            let (name, bid) = displayName(folderName: c.name, appIndex: appIndex)
            return ICloudContainer(folderName: c.name, displayName: name, bundleID: bid, path: dir + "/" + c.name,
                                   localBytes: c.allocatedSize, cloudOnlyFileCount: cloud, fileCount: files)
        }
        list.sort { $0.localBytes != $1.localBytes ? $0.localBytes > $1.localBytes : $0.displayName < $1.displayName }
        return ICloudInventory(containers: list)
    }

    private static func count(_ n: Node, files: inout Int, cloud: inout Int) {
        if n.isDirectory {
            files += n.omittedFileCount
            for c in n.children { count(c, files: &files, cloud: &cloud) }
        } else {
            files += 1
            if n.isDataless { cloud += 1 }
        }
    }

    /// 컨테이너 폴더 이름 -> (표시 이름, 번들 ID).
    static func displayName(folderName: String, appIndex: (any AppIndex)?) -> (String, String?) {
        if folderName == driveFolder { return ("iCloud Drive", nil) }
        var raw = folderName
        if raw.hasPrefix("iCloud~") { raw = String(raw.dropFirst("iCloud~".count)) }
        let bundleID = raw.replacingOccurrences(of: "~", with: ".")
        if let app = appIndex?.app(bundleID: bundleID) { return (app.displayName, bundleID) }
        let last = raw.split(separator: "~").last.map(String.init) ?? folderName
        return (last, bundleID)
    }

    /// 컨테이너 직속 하위 폴더 (로컬 크기 내림차순).
    public func subfolders(ofContainer path: String, in outcome: ScanOutcome) -> [ICloudFolder] {
        guard let n = outcome.node(at: path) else { return [] }
        return n.children.filter(\.isDirectory)
            .map { ICloudFolder(name: $0.name, path: path + "/" + $0.name, localBytes: $0.allocatedSize) }
            .sorted { $0.localBytes != $1.localBytes ? $0.localBytes > $1.localBytes : $0.name < $1.name }
    }

    // MARK: - 업로드 대기 (지연 조회)

    /// 컨테이너 안에서 아직 업로드되지 않은(또는 업로드 중인) 파일 수. dataless 파일은 건너뛰고 내용은 읽지 않는다.
    /// 백그라운드 스레드에서 실행하며 Task 취소를 지원한다. 취소 시 그때까지의 부분 결과를 truncated=true로 반환.
    public static func pendingUploads(containerPath: String, limit: Int = 20000)
        async -> (pending: Int, checked: Int, truncated: Bool) {
        let work = Task.detached(priority: .utility) {
            scanPending(containerPath: containerPath, limit: limit)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    static func scanPending(containerPath: String, limit: Int) -> (pending: Int, checked: Int, truncated: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: containerPath, isDirectory: true),
                                                      includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return (0, 0, false) }
        var pending = 0, checked = 0
        while let obj = en.nextObject() {
            if Task.isCancelled { return (pending, checked, true) }
            guard let url = obj as? URL else { continue }
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if st.st_flags & 0x4000_0000 != 0 { continue }   // SF_DATALESS: 클라우드 전용
            if checked >= limit { return (pending, checked, true) }
            checked += 1
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.ubiquitousItemIsUploaded == false || v.ubiquitousItemIsUploading == true { pending += 1 }
        }
        return (pending, checked, false)
    }
}
