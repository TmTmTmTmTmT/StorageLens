import Foundation

private struct NoInUse: InUseQuery {
    func processes(usingPathPrefix path: String) -> [String] { [] }
}

/// iCloud 파일의 업로드 상태 (evict 전 확인).
public enum ICloudUploadState: Sendable, Equatable {
    case uploaded
    /// 업로드 중/대기/확인 불가. 내리지 않고 건너뛴다 (fail-closed). 값은 사유.
    case notUploaded(String)
}
public typealias ICloudUploadChecker = @Sendable (URL) -> ICloudUploadState

/// 정리 코어 (PLAN §8). 실제 파일을 지우는 유일한 경로이므로 안전 규칙(§8.1)을 완화하지 않는다.
/// 삭제 수단은 `FileSystem.trashItem`(= `FileManager.trashItem`)뿐이며, 앱은 휴지통을 비우지 않는다.
public struct Cleaner: Sendable {
    public static let trashNotice = "휴지통을 비워야 공간이 확보됩니다"
    public static let commandTimeout: TimeInterval = 600
    /// 결과에 담는 개별 실패/건너뜀 목록 상한. 초과분은 `omitted…Count`로만 표시.
    public static let maxListedFailures = 100

    private let home: URL
    private let fs: any FileSystem
    private let clock: any Clock
    private let toolLocator: ToolLocator
    private let inUse: any InUseQuery
    public let journal: Journal
    private let timeout: TimeInterval
    private let safety: PathSafety
    private let matcher: CatalogMatcher
    private let attributionLookup: @Sendable (String) -> Attribution?
    /// 매처 홈이 realpath(홈)과 다르면 discouraged 판정 누락 위험이 있으므로 모든 정리를 거부한다 (실패 시 닫힘).
    private let homeMismatch: Bool
    private static let mismatchReason = "카탈로그 홈 불일치(안전상 정리 불가)"
    /// 카탈로그가 비었으면 discouraged 보호가 사라지므로 모든 정리를 거부한다 (실패 시 닫힘).
    private let catalogEmpty: Bool
    private static let emptyCatalogReason = "카탈로그를 불러오지 못해 안전 판정 불가"
    private let uploadChecker: ICloudUploadChecker

    private var blockedReason: String? {
        if homeMismatch { return Self.mismatchReason }
        if catalogEmpty { return Self.emptyCatalogReason }
        return nil
    }

    /// 기본 업로드 확인: 업로드 완료(ubiquitousItemIsUploaded)이고 업로드 중이 아닐 때만 uploaded.
    public static let systemUploadChecker: ICloudUploadChecker = { url in
        guard let v = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey]) else {
            return .notUploaded("업로드 상태를 확인할 수 없음")
        }
        if v.ubiquitousItemIsUploading == true { return .notUploaded("업로드 중") }
        if v.ubiquitousItemIsUploaded == true { return .uploaded }
        return .notUploaded("업로드 대기 또는 확인 불가")
    }

    /// - Parameters:
    ///   - matcher: 카탈로그 매처. 안전 판정(discouraged/none)은 호출자 제공 매치가 아니라 이 매처로 Cleaner가 직접 계산한다.
    ///   - attributionLookup: 경로 -> 귀속 (고아 판정용). 기본은 항상 nil.
    public init(home: URL,
                matcher: CatalogMatcher,
                attributionLookup: @escaping @Sendable (String) -> Attribution? = { _ in nil },
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any Clock = SystemClock(),
                toolLocator: ToolLocator? = nil,
                inUse: (any InUseQuery)? = nil,
                journal: Journal,
                commandTimeout: TimeInterval = Cleaner.commandTimeout,
                uploadChecker: @escaping ICloudUploadChecker = Cleaner.systemUploadChecker) {
        self.uploadChecker = uploadChecker
        self.catalogEmpty = matcher.catalog.entries.isEmpty
        self.home = home
        self.matcher = matcher
        self.attributionLookup = attributionLookup
        self.fs = fileSystem
        self.clock = clock
        self.toolLocator = toolLocator ?? ToolLocator(home: home)
        self.inUse = inUse ?? NoInUse()
        self.journal = journal
        self.timeout = commandTimeout
        self.safety = PathSafety(home: home, fs: fileSystem)
        if let real = try? fileSystem.realPath(of: home).path {
            let realNorm = "/" + real.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
            self.homeMismatch = realNorm != matcher.homePath
        } else {
            self.homeMismatch = true
        }
    }

    // MARK: - plan

    /// - Parameter progress: 항목별 순회 진행 콜백 (기본 nil). 순회 중 `Task.isCancelled`를 확인하며,
    ///   취소되면 남은 선택은 "취소됨"으로 거부한다.
    public func plan(_ selections: [CleanupSelection], progress: CleanupProgressHandler? = nil) -> CleanupPlan {
        var items: [CleanupPlanItem] = []
        var rejected: [CleanupRejection] = []
        for (idx, sel) in selections.enumerated() {
            let label = sel.path ?? "(가상) \(sel.match?.entry.id ?? "?")"
            if let why = blockedReason {
                rejected.append(CleanupRejection(path: label, reason: why))
                continue
            }
            if Task.isCancelled {
                rejected.append(CleanupRejection(path: label, reason: "취소됨"))
                continue
            }
            let visit = Self.visitor(progress, index: idx, count: selections.count)
            do {
                items.append(try planItem(sel, onVisit: visit))
            } catch let r as PathRejection {
                rejected.append(CleanupRejection(path: label, reason: r.reason))
            } catch {
                rejected.append(CleanupRejection(path: label, reason: error.localizedDescription))
            }
        }
        return CleanupPlan(createdAt: clock.now, items: items, rejected: rejected)
    }

    private static func visitor(_ progress: CleanupProgressHandler?, index: Int, count: Int)
        -> (@Sendable (Int, String) -> Void)? {
        guard let progress else { return nil }
        return { n, path in
            progress(CleanupProgress(processedCount: n, currentPath: path, itemIndex: index, itemCount: count))
        }
    }

    /// 경로에 대한 카탈로그 매칭을 Cleaner가 직접 계산 (호출자 제공 값 무시).
    private func matchPath(_ path: String) -> CatalogMatch? {
        let fsys = fs
        return matcher.match(path: path, attribution: attributionLookup(path),
                             modified: { p in (try? fsys.attributes(at: URL(fileURLWithPath: p)))?.modified })
    }

    private func rejectIfForbidden(_ m: CatalogMatch?) throws {
        guard let m else { return }
        if m.effectiveMethod == .none || m.entry.method == .none {
            throw PathRejection(reason: m.unavailableReason ?? "정리 방법 없음")
        }
    }

    private struct Classified {
        var match: CatalogMatch?; var verified: VerifiedPath; var method: CleanupMethod
        /// 입력 경로·정규 경로 양쪽 판정 중 더 엄격한 등급.
        var level: Safety
    }

    /// 카탈로그 매치가 없으면 개인 폴더 하위는 discouraged, 그 밖은 review.
    private func level(_ m: CatalogMatch?, _ path: String) -> Safety {
        if let m { return m.entry.safety }
        return matcher.isUnderPersonalFolder(path) ? .discouraged : .review
    }

    /// 입력 경로와 정규화(realpath) 경로 양쪽을 매칭해 더 엄격한 쪽을 따른다. plan/execute 공용.
    private func classify(_ path: String, onVisit: (@Sendable (Int, String) -> Void)? = nil) throws -> Classified {
        let m1 = matchPath(path)
        try rejectIfForbidden(m1)
        var method = m1?.effectiveMethod ?? .trash
        var v = try safety.verify(path, method: method, onVisit: onVisit)
        var match = m1
        var lvl = level(m1, path)
        if v.path != path {
            let m2 = matchPath(v.path)
            try rejectIfForbidden(m2)
            let l2 = level(m2, v.path)
            if l2.strictness > lvl.strictness { lvl = l2 }
            if let a = m1, let b = m2, a.effectiveMethod != b.effectiveMethod {
                throw PathRejection(reason: "카탈로그 매칭 불일치")
            }
            if m1 == nil, let b = m2 {
                match = b; method = b.effectiveMethod
                v = try safety.verify(path, method: method, onVisit: onVisit)
            } else if let a = m1, let b = m2, a.entry.safety.strictness < b.entry.safety.strictness {
                match = b
            }
        }
        return Classified(match: match, verified: v, method: method, level: lvl)
    }

    private func planItem(_ sel: CleanupSelection, onVisit: (@Sendable (Int, String) -> Void)? = nil) throws -> CleanupPlanItem {
        var method: CleanupMethod = .trash
        var entry: CatalogEntry?
        var classified: Classified?

        if let path = sel.path {
            let c = try classify(path, onVisit: onVisit)
            classified = c
            entry = c.match?.entry
            method = c.method
        } else {
            // 가상 항목: 카탈로그에 같은 id가 있고 pathPatterns가 비어 있어야 하며, 매칭은 Cleaner가 다시 해석.
            guard let id = sel.match?.entry.id, let e = matcher.catalog.entry(id: id),
                  e.pathPatterns.isEmpty, e.id != Catalog.orphanID else {
                throw PathRejection(reason: "카탈로그에 없는 가상 항목")
            }
            let m = matcher.resolve(e)
            try rejectIfForbidden(m)
            entry = e
            method = m.effectiveMethod
        }
        let safetyLevel: Safety = classified?.level ?? entry?.safety ?? .review

        var toolName: String?, toolPath: String?, args: [String] = []
        if method == .command {
            guard let cmd = entry?.command else { throw PathRejection(reason: "command 정의 없음") }
            guard let located = toolLocator.locate(cmd.tool) else { throw PathRejection(reason: "도구 없음") }
            toolName = cmd.tool; toolPath = located; args = cmd.args
        }

        var warnings: [String] = []
        if safetyLevel == .discouraged {
            warnings.append(entry == nil ? "정리 비권장: 개인 폴더의 파일입니다. 내용을 직접 확인하세요."
                                         : "정리 비권장 항목입니다: \(entry!.note)")
        } else if safetyLevel == .review {
            warnings.append(entry == nil ? "카탈로그에 없는 항목입니다. 내용을 직접 확인하세요."
                                         : "검토가 필요한 항목입니다: \(entry!.note)")
        }

        guard let c = classified else {
            guard method == .command, let e = entry else {
                throw PathRejection(reason: "가상 항목은 command 방식만 허용")
            }
            return CleanupPlanItem(path: "virtual:\(e.id)", sizeBytes: 0, method: .command, inode: 0, devID: 0,
                                   warnings: warnings, entryID: e.id, title: e.title,
                                   toolName: toolName, toolPath: toolPath, commandArguments: args, isVirtual: true,
                                   isDiscouraged: safetyLevel == .discouraged)
        }

        let v = c.verified
        guard let attr = v.entry else { throw PathRejection(reason: "대상이 존재하지 않음") }
        let size = v.measuredSize
        if method == .trash { warnings.append(Self.trashNotice) }
        let procs = inUse.processes(usingPathPrefix: v.path)
        if !procs.isEmpty {
            warnings.append("사용 중인 프로세스: \(procs.joined(separator: ", ")). 앱 종료 후 정리를 권장합니다.")
        }
        return CleanupPlanItem(path: v.path, sizeBytes: size, method: method, inode: attr.inode, devID: attr.devID,
                               warnings: warnings, entryID: entry?.id, title: entry?.title,
                               toolName: toolName, toolPath: toolPath, commandArguments: args,
                               isDiscouraged: safetyLevel == .discouraged, unmeasuredCount: v.unmeasuredCount)
    }

    // MARK: - execute

    /// - Parameter acknowledgedDiscouraged: 사용자가 "비권장 항목임을 이해했습니다"를 확인했는가.
    ///   false면 discouraged 항목은 건너뛴다 (UI와 별개로 코어에서 강제).
    public func execute(_ plan: CleanupPlan, acknowledgedDiscouraged: Bool = false,
                        progress: CleanupProgressHandler? = nil) async -> CleanupResult {
        if plan.isExpired(at: clock.now) {
            let outs = plan.items.map {
                outcome($0, .skipped, reason: "계획이 만료되었습니다 (10분). 다시 계획을 만드세요.")
            }
            return CleanupResult(planExpired: true, outcomes: outs)
        }
        var outs: [CleanupItemOutcome] = []
        for (idx, item) in plan.items.enumerated() {
            if Task.isCancelled {
                // 남은 항목은 건너뜀으로 결과·저널에 기록.
                let o = outcome(item, .skipped, reason: Self.cancelledReason)
                let jerr = record(JournalEntry(timestamp: clock.now, originalPath: item.path, trashPath: nil,
                                               sizeBytes: item.sizeBytes, method: item.method.rawValue,
                                               result: "skipped", detail: Self.cancelledReason))
                outs.append(withJournalError(o, jerr))
                continue
            }
            let visit = Self.visitor(progress, index: idx, count: plan.items.count)
            outs.append(await executeItem(item, acknowledgedDiscouraged: acknowledgedDiscouraged, onVisit: visit))
        }
        return CleanupResult(planExpired: false, outcomes: outs)
    }

    private static let cancelledReason = "취소됨"

    private func withJournalError(_ o: CleanupItemOutcome, _ jerr: String?) -> CleanupItemOutcome {
        guard let jerr else { return o }
        var n = CleanupItemOutcome(path: o.path, method: o.method, status: o.status, reason: o.reason,
                                   trashedPath: o.trashedPath, sizeBytes: o.sizeBytes, sizeAfterBytes: o.sizeAfterBytes,
                                   freedBytes: o.freedBytes, failures: o.failures, journalError: jerr)
        n.skippedFiles = o.skippedFiles; n.omittedFailureCount = o.omittedFailureCount
        n.omittedSkippedCount = o.omittedSkippedCount; n.notUploadedCount = o.notUploadedCount
        n.unmeasuredCount = o.unmeasuredCount
        return n
    }

    private func outcome(_ item: CleanupPlanItem, _ status: CleanupStatus, reason: String? = nil,
                         trashed: String? = nil, after: Int64? = nil, freed: Int64 = 0,
                         failures: [CleanupFailure] = [], journalError: String? = nil) -> CleanupItemOutcome {
        CleanupItemOutcome(path: item.path, method: item.method, status: status, reason: reason,
                           trashedPath: trashed, sizeBytes: item.sizeBytes, sizeAfterBytes: after,
                           freedBytes: freed, failures: failures, journalError: journalError)
    }

    private static let notAcknowledgedReason = "비권장 항목 확인 안 됨"

    private func executeItem(_ item: CleanupPlanItem, acknowledgedDiscouraged: Bool,
                             onVisit: (@Sendable (Int, String) -> Void)?) async -> CleanupItemOutcome {
        if let why = blockedReason { return outcome(item, .skipped, reason: why) }
        if item.method == .none { return outcome(item, .skipped, reason: "정리 방법 없음") }
        if item.isDiscouraged, !acknowledgedDiscouraged { return outcome(item, .skipped, reason: Self.notAcknowledgedReason) }
        // 실행 직전 재검증: 안전 규칙 재통과 + 같은 (dev, inode).
        var verifiedSize: Int64 = 0
        var verifiedUnmeasured = 0
        if !item.isVirtual {
            do {
                // 다시 매칭해 none이면 건너뜀 (minAgeDays·고아 판정도 현재 상태로 재계산).
                let c = try classify(item.path, onVisit: onVisit)
                verifiedSize = c.verified.measuredSize
                verifiedUnmeasured = c.verified.unmeasuredCount
                guard c.method == item.method else {
                    return outcome(item, .skipped, reason: "재검증 실패: 정리 방법이 계획과 다릅니다")
                }
                // 재계산한 등급이 discouraged인데 확인이 없으면 건너뜀 (계획 값을 믿지 않음).
                if c.level == .discouraged, !acknowledgedDiscouraged {
                    return outcome(item, .skipped, reason: Self.notAcknowledgedReason)
                }
                guard let e = c.verified.entry, e.devID == item.devID, e.inode == item.inode else {
                    return outcome(item, .skipped, reason: "계획 이후 대상이 바뀌었습니다 (inode 불일치)")
                }
            } catch let r as PathRejection {
                return outcome(item, .skipped, reason: "재검증 실패: \(r.reason)")
            } catch {
                return outcome(item, .skipped, reason: "재검증 실패: \(error.localizedDescription)")
            }
        } else if item.method != .command {
            return outcome(item, .skipped, reason: "가상 항목은 command만 허용")
        }

        switch item.method {
        case .trash: return runTrash(item)
        case .command: return await runCommandItem(item, before: verifiedSize, onVisit: onVisit)
        case .icloudEvict: return runEvict(item, before: verifiedSize, unmeasured: verifiedUnmeasured, onVisit: onVisit)
        case .none: return outcome(item, .skipped, reason: "정리 방법 없음")
        }
    }

    private func record(_ e: JournalEntry) -> String? {
        do { try journal.append(e); return nil } catch { return "저널 기록 실패: \(error.localizedDescription)" }
    }

    private func runTrash(_ item: CleanupPlanItem) -> CleanupItemOutcome {
        do {
            let result = try fs.trashItem(at: URL(fileURLWithPath: item.path))
            // 휴지통 항목의 (dev, inode, size)를 기록해 되돌리기 때 동일성을 확인한다.
            let tattr = result.flatMap { try? fs.attributes(at: $0) }
            let jerr = record(JournalEntry(timestamp: clock.now, originalPath: item.path, trashPath: result?.path,
                                           sizeBytes: item.sizeBytes, method: "trash", result: "success",
                                           trashDev: tattr?.devID, trashInode: tattr?.inode, trashSize: tattr?.logicalSize))
            return outcome(item, .succeeded, trashed: result?.path, journalError: jerr)
        } catch {
            let jerr = record(JournalEntry(timestamp: clock.now, originalPath: item.path, trashPath: nil,
                                           sizeBytes: item.sizeBytes, method: "trash", result: "failed",
                                           detail: error.localizedDescription))
            return outcome(item, .failed, reason: error.localizedDescription, journalError: jerr)
        }
    }

    private func runCommandItem(_ item: CleanupPlanItem, before verifiedBefore: Int64,
                                onVisit: (@Sendable (Int, String) -> Void)?) async -> CleanupItemOutcome {
        guard let name = item.toolName, let planned = item.toolPath, toolLocator.locate(name) == planned else {
            return outcome(item, .skipped, reason: "도구 경로가 계획 이후 바뀌었거나 없습니다")
        }
        // 실행 전 크기는 직전 재검증 순회 결과를 재사용 (추가 순회 없음).
        let before: Int64 = item.isVirtual ? 0 : verifiedBefore
        let run = await Self.runProcess(path: planned, args: item.commandArguments, home: home, timeout: timeout)
        var unmeasured = 0
        let after: Int64? = item.isVirtual ? nil : {
            let m = measureCounting(URL(fileURLWithPath: item.path), onVisit: onVisit)
            unmeasured = m.unmeasured
            return m.size
        }()
        let freed = after.map { max(0, before - $0) } ?? 0
        var status = CleanupStatus.succeeded
        var reason: String?
        if let le = run.launchError { status = .failed; reason = "실행 실패: \(le)" }
        else if run.timedOut { status = .failed; reason = "시간 초과 (\(Int(timeout))초)로 중단" }
        else if let code = run.exitCode, code != 0 { status = .failed; reason = "종료 코드 \(code)" }
        let jerr = record(JournalEntry(timestamp: clock.now, originalPath: item.path, trashPath: nil,
                                       sizeBytes: freed, method: "command",
                                       result: status == .succeeded ? "success" : "failed", detail: reason))
        var o = outcome(item, status, reason: reason, after: after, freed: freed, journalError: jerr)
        o.unmeasuredCount = unmeasured
        return o
    }

    private struct EvictState {
        var evicted = 0
        var failures: [CleanupFailure] = []
        var omittedFailures = 0
        var skipped: [CleanupFailure] = []
        var omittedSkipped = 0
        var notUploaded = 0
        var visited = 0
        var cancelled = false
        mutating func fail(_ f: CleanupFailure) {
            if failures.count < Cleaner.maxListedFailures { failures.append(f) } else { omittedFailures += 1 }
        }
        mutating func skip(_ f: CleanupFailure) {
            notUploaded += 1
            if skipped.count < Cleaner.maxListedFailures { skipped.append(f) } else { omittedSkipped += 1 }
        }
    }

    private func runEvict(_ item: CleanupPlanItem, before: Int64, unmeasured: Int,
                          onVisit: (@Sendable (Int, String) -> Void)?) -> CleanupItemOutcome {
        let root = URL(fileURLWithPath: item.path)
        var st = EvictState()
        evictWalk(root, state: &st, onVisit: onVisit)
        let m = measureCounting(root, onVisit: onVisit)
        let after = m.size
        let freed = max(0, before - after)
        let failTotal = st.failures.count + st.omittedFailures
        let status: CleanupStatus
        if failTotal == 0 && st.notUploaded == 0 && !st.cancelled { status = .succeeded }
        else if st.evicted > 0 { status = .partial }
        else if failTotal == 0 { status = .skipped }
        else { status = .failed }
        var parts: [String] = []
        if failTotal > 0 { parts.append("\(failTotal)개 파일 실패 (업로드 대기)") }
        if st.notUploaded > 0 { parts.append("업로드가 끝나지 않은 \(st.notUploaded)개 파일은 내리지 않음") }
        if st.cancelled { parts.append(Self.cancelledReason) }
        let reason = parts.isEmpty ? nil : parts.joined(separator: " · ")
        let jresult: String
        switch status {
        case .succeeded: jresult = "success"
        case .partial: jresult = "partial"
        case .skipped: jresult = "skipped"
        case .failed: jresult = "failed"
        }
        let jerr = record(JournalEntry(timestamp: clock.now, originalPath: item.path, trashPath: nil,
                                       sizeBytes: freed, method: "icloudEvict", result: jresult, detail: reason))
        var o = outcome(item, status, reason: reason, after: after, freed: freed, failures: st.failures, journalError: jerr)
        o.skippedFiles = st.skipped
        o.omittedFailureCount = st.omittedFailures
        o.omittedSkippedCount = st.omittedSkipped
        o.notUploadedCount = st.notUploaded
        o.unmeasuredCount = unmeasured + m.unmeasured
        return o
    }

    private func evictWalk(_ url: URL, state st: inout EvictState, onVisit: (@Sendable (Int, String) -> Void)?) {
        if st.cancelled { return }
        if Task.isCancelled { st.cancelled = true; return }
        st.visited += 1
        if st.visited & 0x3F == 0 { onVisit?(st.visited, url.path) }
        let attr: FileEntry
        do { attr = try fs.attributes(at: url) } catch {
            st.fail(CleanupFailure(path: url.path, reason: "확인 불가: \(error.localizedDescription)")); return
        }
        if attr.isSymlink { return }   // 링크는 따라가지 않음
        if attr.isDirectory {
            do {
                for child in try fs.entries(in: url) {
                    evictWalk(url.appendingPathComponent(child.name), state: &st, onVisit: onVisit)
                    if st.cancelled { return }
                }
            } catch {
                st.fail(CleanupFailure(path: url.path, reason: "폴더를 읽을 수 없음: \(error.localizedDescription)"))
            }
            return
        }
        if attr.isDataless { return }   // 이미 로컬 사본 없음
        // 업로드가 끝난 파일만 내린다 (클라우드에 없는 유일한 사본 보호, fail-closed).
        if case .notUploaded(let why) = uploadChecker(url) {
            st.skip(CleanupFailure(path: url.path, reason: "업로드 미완료로 내리지 않음: \(why)"))
            return
        }
        do { try fs.evictUbiquitousItem(at: url); st.evicted += 1 }
        catch { st.fail(CleanupFailure(path: url.path, reason: "업로드 대기: \(error.localizedDescription)")) }
    }

    // MARK: - undo

    /// 휴지통으로 허용되는 접두: 홈 `~/.Trash/` 또는 볼륨 `/.Trashes/`, `/Volumes/<이름>/.Trashes/`.
    private func allowedTrashPrefixes() -> [String] {
        var homes: Set<String> = [home.path, NSHomeDirectory()]
        for h in Array(homes) { if let r = try? fs.realPath(of: URL(fileURLWithPath: h)).path { homes.insert(r) } }
        return homes.map { $0 + "/.Trash/" }
    }

    private func isAllowedTrashLocation(_ path: String) -> Bool {
        let comps = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.hasPrefix("/") == false || comps.contains("..") || comps.contains(".") { return false }
        if allowedTrashPrefixes().contains(where: { path.hasPrefix($0) && path.count > $0.count }) { return true }
        if path.hasPrefix("/.Trashes/") { return true }
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count >= 4 && parts[2] == ".Trashes"
        }
        return false
    }

    public func canUndo(_ entry: JournalEntry) -> (Bool, String?) {
        guard entry.method == "trash", entry.result == "success" else { return (false, "되돌릴 수 없는 기록입니다 (휴지통 이동 기록이 아님)") }
        guard let trash = entry.trashPath, !trash.isEmpty else { return (false, "휴지통 경로가 기록되지 않았습니다") }
        guard isAllowedTrashLocation(trash) else { return (false, "휴지통 경로가 아닙니다") }
        let tURL = URL(fileURLWithPath: trash)
        let tattr: FileEntry
        do { tattr = try fs.attributes(at: tURL) } catch let e as NSError {
            if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) { return (false, "휴지통에 항목이 더 이상 없습니다") }
            return (false, "휴지통 항목을 확인할 수 없습니다: \(e.localizedDescription)")
        }
        if tattr.isSymlink { return (false, "휴지통 경로가 심볼릭 링크라 되돌릴 수 없습니다") }
        guard let rp = try? fs.realPath(of: tURL).path, rp == trash else {
            return (false, "휴지통 경로가 정규 경로가 아닙니다 (링크 포함)")
        }
        // 동일성: 기록한 (dev, inode, size)와 지금 휴지통 항목이 같아야 한다. 구기록은 확인 수단이 없어 거부.
        guard let d = entry.trashDev, let i = entry.trashInode, let sz = entry.trashSize else {
            return (false, "구버전 기록이라 휴지통 항목의 동일성을 확인할 수 없어 되돌릴 수 없습니다 (Finder에서 직접 복원하세요)")
        }
        guard tattr.devID == d, tattr.inode == i, tattr.logicalSize == sz else {
            return (false, "휴지통의 항목이 기록과 다릅니다 (같은 이름의 다른 파일일 수 있음)")
        }
        let orig = URL(fileURLWithPath: entry.originalPath)
        if fs.fileExists(at: orig) { return (false, "원래 위치에 이미 다른 항목이 있습니다") }
        let parent = orig.deletingLastPathComponent()
        guard let pa = try? fs.attributes(at: parent), pa.isDirectory, !pa.isSymlink else {
            return (false, "원래 폴더가 없습니다")
        }
        do { _ = try safety.verify(entry.originalPath, method: .trash, mustExist: false) }
        catch let r as PathRejection { return (false, "안전 규칙 위반: \(r.reason)") }
        catch { return (false, error.localizedDescription) }
        return (true, nil)
    }

    public func undo(_ entry: JournalEntry) -> UndoResult {
        let (ok, reason) = canUndo(entry)
        guard ok, let trash = entry.trashPath else { return UndoResult(success: false, reason: reason) }
        do {
            try fs.moveItem(at: URL(fileURLWithPath: trash), to: URL(fileURLWithPath: entry.originalPath))
            let jerr = record(JournalEntry(timestamp: clock.now, originalPath: entry.originalPath, trashPath: trash,
                                           sizeBytes: entry.sizeBytes, method: "undo", result: "success"))
            return UndoResult(success: true, reason: nil, journalError: jerr)
        } catch {
            let jerr = record(JournalEntry(timestamp: clock.now, originalPath: entry.originalPath, trashPath: trash,
                                           sizeBytes: entry.sizeBytes, method: "undo", result: "failed",
                                           detail: error.localizedDescription))
            return UndoResult(success: false, reason: error.localizedDescription, journalError: jerr)
        }
    }

    // MARK: - 크기 측정

    /// 할당 크기 합 (링크 미추적, 하드링크 1회). 읽지 못한 항목 수를 함께 돌려준다 (취소는 무시하고 끝까지 측정).
    func measureCounting(_ url: URL, onVisit: (@Sendable (Int, String) -> Void)? = nil) -> (size: Int64, unmeasured: Int) {
        guard let a = try? fs.attributes(at: url) else { return (0, 1) }
        var w = TreeWalker(fs: fs, detectPhotos: false, stopOnUnreadable: false, onVisit: onVisit)
        w.honorCancellation = false
        guard let r = try? w.walk(root: url, rootEntry: a) else { return (0, 1) }
        return (r.size, r.unmeasured)
    }

    func measure(_ url: URL) -> Int64 { measureCounting(url).size }

    // MARK: - 프로세스 실행 (셸 사용 안 함)

    struct RunResult: Sendable { var exitCode: Int32?; var timedOut: Bool; var launchError: String? }

    private final class RunState: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var _timedOut = false
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
        func markTimedOut() { lock.lock(); _timedOut = true; lock.unlock() }
    }

    static func runProcess(path: String, args: [String], home: URL, timeout: TimeInterval) async -> RunResult {
        let state = RunState()
        let p = state.process
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        p.environment = env
        return await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                state.markTimedOut()
                state.process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if state.process.isRunning { kill(state.process.processIdentifier, SIGKILL) }
                }
            }
            p.terminationHandler = { proc in
                timer.cancel()
                cont.resume(returning: RunResult(exitCode: proc.terminationStatus, timedOut: state.timedOut, launchError: nil))
            }
            timer.resume()
            do { try p.run() } catch {
                timer.cancel()
                cont.resume(returning: RunResult(exitCode: nil, timedOut: false, launchError: error.localizedDescription))
            }
        }
    }
}
