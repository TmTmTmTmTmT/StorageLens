import Foundation

/// `ToolLocator`가 찾은 도구. `isNonStandard`는 표준 시스템/패키지 관리자 디렉터리 밖(예: `~/.local/bin`, `~/.cargo/bin`)에서 찾았다는 뜻.
public struct LocatedTool: Sendable, Equatable {
    public let path: String
    public let isNonStandard: Bool
    public init(path: String, isNonStandard: Bool) { self.path = path; self.isNonStandard = isNonStandard }
}

/// CLI 도구의 실행 파일 절대 경로 탐색 (PLAN §8.3, §17 safety-1). GUI 앱은 셸 PATH를 상속하지 않으므로 고정 후보 디렉터리만 본다.
/// - 시스템 도구(`systemTools`)는 후보 탐색 없이 `systemToolDirectory`(기본 `/usr/bin`)의 절대 경로만 쓴다.
/// - 그 외 도구는 파일 소유자가 root 또는 현재 사용자이고, 파일과 그 디렉터리가 그룹·타인 쓰기 불가일 때만 채택한다.
/// 홈·후보 디렉터리를 주입할 수 있어 테스트에서 임시 디렉터리를 쓴다. M3 정리 기능도 재사용한다.
public struct ToolLocator: Sendable {
    public let candidateDirectories: [String]
    public let systemToolDirectory: String

    /// 후보 탐색을 하지 않고 `systemToolDirectory`에서만 찾는 시스템 도구 이름.
    public static let systemTools: Set<String> = ["xcrun", "xcodebuild", "xcode-select"]
    /// 비표준 경로로 보지 않는 디렉터리.
    public static let standardDirectories: Set<String> = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// §8.3 순서: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `/usr/bin`.
    public static func defaultCandidateDirectories(home: URL) -> [String] {
        let h = home.standardizedFileURL.path
        return [h + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", h + "/.cargo/bin", "/usr/bin"]
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                candidateDirectories: [String]? = nil,
                systemToolDirectory: String = "/usr/bin") {
        self.candidateDirectories = candidateDirectories ?? Self.defaultCandidateDirectories(home: home)
        self.systemToolDirectory = systemToolDirectory
    }

    /// 실행 가능한 일반 파일의 절대 경로. 없거나 신뢰 규칙 위반이면 nil. 경로 구분자가 든 이름은 거부(탐색 탈출 방지).
    public func locate(_ tool: String) -> String? { locateDetailed(tool)?.path }

    /// `locate` + 비표준 경로 여부.
    public func locateDetailed(_ tool: String) -> LocatedTool? {
        guard !tool.isEmpty, !tool.contains("/"), tool != ".", tool != ".." else { return nil }
        if Self.systemTools.contains(tool) {
            let path = systemToolDirectory + "/" + tool
            return isExecutableFile(path) ? LocatedTool(path: path, isNonStandard: false) : nil
        }
        let myUID = getuid()
        for dir in candidateDirectories {
            let path = dir + "/" + tool
            guard isExecutableFile(path) else { continue }
            // 파일은 링크를 해석한 실파일 기준(그룹·타인 쓰기 불가), 후보 디렉터리는 Homebrew 표준 위치에 한해 admin 그룹 쓰기 허용.
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let realDir = (real as NSString).deletingLastPathComponent
            let dirOK = isTrusted(dir, uid: myUID, allowAdminGroupWrite: Self.adminGroupWriteDirectories.contains(dir))
            let realDirOK = realDir == dir || isTrusted(realDir, uid: myUID, allowAdminGroupWrite: false)
            guard isTrusted(real, uid: myUID, allowAdminGroupWrite: false), dirOK, realDirOK else { continue }
            return LocatedTool(path: path, isNonStandard: !Self.standardDirectories.contains(dir))
        }
        return nil
    }

    /// 소유자가 현재 사용자 또는 root 인 Homebrew 표준 디렉터리에서만 admin(gid 80) 그룹 쓰기를 허용한다.
    public static let adminGroupWriteDirectories: Set<String> = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let adminGID: gid_t = 80

    /// 신뢰 판정(순수 함수): 소유자 root/본인, 타인 쓰기 불가, 그룹 쓰기는 (허용 시 gid 80 에 한해) 허용.
    static func isTrustedMode(owner: uid_t, group: gid_t, mode: mode_t, currentUID: uid_t,
                              allowAdminGroupWrite: Bool) -> Bool {
        guard owner == 0 || owner == currentUID else { return false }
        if mode & S_IWOTH != 0 { return false }
        if mode & S_IWGRP != 0 { return allowAdminGroupWrite && group == adminGID }
        return true
    }

    private func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// 심볼릭 링크를 따라간 대상 기준.
    private func isTrusted(_ path: String, uid: uid_t, allowAdminGroupWrite: Bool) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return Self.isTrustedMode(owner: st.st_uid, group: st.st_gid, mode: st.st_mode, currentUID: uid,
                                  allowAdminGroupWrite: allowAdminGroupWrite)
    }
}
