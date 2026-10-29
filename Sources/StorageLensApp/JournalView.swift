import SwiftUI
import StorageCore

/// 정리 기록 화면 (PLAN §3-6). 날짜별 그룹, 결과 필터, 검색, 되돌리기.
struct JournalView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var resultFilter: ResultFilter = .all

    enum ResultFilter: String, CaseIterable, Identifiable {
        case all, success, partial, failed, skipped
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "모든 결과"
            case .success: "성공"
            case .partial: "일부 성공"
            case .failed: "실패"
            case .skipped: "건너뜀"
            }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let rows: [JournalRow]
        var id: Date { day }
    }

    /// 필터·검색 적용 후 날짜별로 묶는다 (최신순 유지). body에서 1회만 호출.
    private func grouped() -> [DayGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [JournalRow]] = [:]
        for row in model.journalRows {
            if resultFilter != .all, row.entry.result != resultFilter.rawValue { continue }
            if !q.isEmpty,
               !row.entry.originalPath.localizedCaseInsensitiveContains(q),
               !(row.entry.detail?.localizedCaseInsensitiveContains(q) ?? false) { continue }
            let day = cal.startOfDay(for: row.entry.timestamp)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(row)
        }
        return order.map { DayGroup(day: $0, rows: buckets[$0] ?? []) }
    }

    var body: some View {
        let groups = grouped()
        VStack(spacing: 0) {
            if let m = model.undoMessage {
                FloatingBanner(.info, text: m) {
                    Button("닫기") { model.undoMessage = nil }
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            }
            if model.journalRows.isEmpty {
                Text(model.journalLoading ? "불러오는 중…" : "정리 기록이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                Text("조건에 맞는 기록이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { g in
                        Section(g.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(g.rows) { row in
                                JournalRowView(row: row,
                                               feedback: model.lastUndo?.rowID == row.id ? model.lastUndo?.message : nil,
                                               isUndoing: model.undoingRowIDs.contains(row.id)) {
                                    model.undo(row)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("정리 기록")
        .searchable(text: $search, prompt: "경로·내용 검색")
        .toolbar {
            ToolbarItem {
                Picker("결과", selection: $resultFilter) {
                    ForEach(ResultFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Button { model.loadJournal() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                    .help("정리 기록 새로고침")
            }
        }
        .onAppear { model.loadJournal() }
    }
}

struct JournalRowView: View {
    let row: JournalRow
    var feedback: String?
    var isUndoing: Bool = false
    let onUndo: () -> Void

    private var methodText: String {
        switch row.entry.method {
        case "trash": "휴지통 이동"
        case "command": "도구 실행"
        case "icloudEvict": "iCloud 로컬 사본 내리기"
        case "undo": "되돌리기"
        default: "기타"
        }
    }

    private var resultText: String {
        switch row.entry.result {
        case "success": "성공"
        case "partial": "일부 성공"
        case "failed": "실패"
        case "skipped": "건너뜀"
        default: "알 수 없음"
        }
    }

    private var resultColor: Color {
        switch row.entry.result {
        case "success": Theme.safe
        case "failed": Theme.discouraged
        default: Theme.review
        }
    }

    /// 되돌릴 수 없는 이유 한 줄 (되돌리기 대상이 아닌 기록은 nil).
    private var undoNote: String? {
        guard row.entry.method != "undo", row.entry.result != "failed", row.entry.result != "skipped" else { return nil }
        switch row.entry.method {
        case "command": return "되돌릴 수 없음: 도구 실행은 삭제된 내용을 복구할 수 없습니다"
        case "icloudEvict": return "되돌릴 수 없음: 로컬 사본을 내린 것이라 필요하면 iCloud에서 다시 내려받으세요"
        case "trash":
            if row.canUndo { return nil }
            return "되돌릴 수 없음: " + (row.undoReason ?? "이유를 알 수 없습니다")
        default: return nil
        }
    }

    private var rowSummary: String {
        var parts = [row.entry.originalPath, methodText, resultText, Fmt.bytes(row.entry.sizeBytes),
                     Fmt.dateTime(row.entry.timestamp)]
        if let n = undoNote { parts.append(n) }
        if let f = feedback { parts.append(f) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.originalPath).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(methodText)
                    DotLabel(text: resultText, color: resultColor)
                    Text(Fmt.bytes(row.entry.sizeBytes)).monospacedDigit()
                    Text(Fmt.dateTime(row.entry.timestamp))
                }
                .font(.caption).foregroundStyle(.secondary)
                if let d = row.entry.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                if let n = undoNote {
                    NoticeLabel(text: n, systemImage: "info.circle", color: Theme.neutral, secondary: true)
                }
                if let f = feedback {
                    NoticeLabel(text: f, systemImage: "checkmark.bubble", color: Theme.info)
                }
            }
            Spacer()
            if row.entry.method == "trash", row.entry.result == "success" {
                if isUndoing { ProgressView().controlSize(.small) }
                Button("되돌리기", action: onUndo).disabled(!row.canUndo || isUndoing)
                    .accessibilityLabel("되돌리기, \((row.entry.originalPath as NSString).lastPathComponent)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowSummary)
    }
}
