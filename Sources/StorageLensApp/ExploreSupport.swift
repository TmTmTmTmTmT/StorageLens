import SwiftUI
import AppKit
import StorageCore

/// 선버스트 <-> 목록 상호 하이라이트용 공유 상태 (탐색 화면 소유).
@Observable @MainActor
final class ExploreHover {
    /// 선버스트 조각 위에 마우스가 있을 때 그 조각의 경로 ("기타" 조각이면 nil).
    var chartHoverPath: String?
    /// 목록 행 위에 마우스가 있을 때 그 행의 경로.
    var rowHoverPath: String?

    /// 행이 차트 호버 대상(또는 그 조상)인가.
    func highlightsRow(_ rowPath: String) -> Bool {
        guard let p = chartHoverPath else { return false }
        return p == rowPath || p.hasPrefix(rowPath + "/")
    }
}

/// 정렬 선택 (이름순은 코어 RowSort에 없어 화면에서 처리).
enum ExploreSortChoice: String, CaseIterable, Identifiable {
    case size, modified, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: "크기"
        case .modified: "수정일"
        case .name: "이름"
        }
    }
}

/// 선버스트 색 (조각·목록 막대가 같은 색을 쓰도록 공유).
/// 조각 색은 생성 시 한 번 계산해 id로 저장한다 (라이트·다크 두 벌). 그리기 중에는 조회만 한다 (perf-12).
struct SunburstPalette {
    private var light: [String: Color] = [:]
    private var dark: [String: Color] = [:]
    /// 검정 글자가 읽히는(밝은) 조각 id (라이트·다크 별도).
    private var darkTextLight: Set<String> = []
    private var darkTextDark: Set<String> = []

    /// 기타 조각: 불투명 회색 (배경과 대비 확보, 투명 회색 금지).
    private static let otherLight = Color(white: 0.70)
    private static let otherDark = Color(white: 0.38)
    private static let otherLightLum = Theme.ChartLabel.luminance(hue: 0, saturation: 0, brightness: 0.70)
    private static let otherDarkLum = Theme.ChartLabel.luminance(hue: 0, saturation: 0, brightness: 0.38)

    private mutating func markOther(_ id: String) {
        light[id] = Self.otherLight
        dark[id] = Self.otherDark
        if Self.otherLightLum > Theme.ChartLabel.darkTextThreshold { darkTextLight.insert(id) }
        if Self.otherDarkLum > Theme.ChartLabel.darkTextThreshold { darkTextDark.insert(id) }
    }

    init(arcs: [SunburstArc]) {
        // 깊이 1 조각을 시작 각도 순으로 정렬해 이진 탐색으로 최상위 조상을 찾는다.
        let tops = arcs.filter { $0.depth == 1 }.sorted { $0.start < $1.start }
        let starts = tops.map(\.start)
        light.reserveCapacity(arcs.count)
        dark.reserveCapacity(arcs.count)
        for a in arcs {
            if a.isOther {
                markOther(a.id)
                continue
            }
            let mid = (a.start + a.end) / 2
            // mid 이하인 마지막 시작 각도의 최상위 조각.
            var lo = 0, hi = starts.count
            while lo < hi {
                let m = (lo + hi) / 2
                if starts[m] <= mid { lo = m + 1 } else { hi = m }
            }
            let top = lo > 0 && tops[lo - 1].start <= mid && mid < tops[lo - 1].end ? tops[lo - 1] : nil
            if top?.isOther == true {
                markOther(a.id)
                continue
            }
            let hue = top.map { ($0.start + $0.end) / 2 } ?? mid
            let step = Double(a.depth - 1)
            // 라이트: 밝은 파스텔. 다크: 채도·밝기를 낮춰 과밝기를 완화.
            let lb = max(0.5, 0.95 - 0.12 * step), db = max(0.45, 0.72 - 0.08 * step)
            light[a.id] = Color(hue: hue, saturation: 0.55, brightness: lb)
            dark[a.id] = Color(hue: hue, saturation: 0.50, brightness: db)
            if Theme.ChartLabel.luminance(hue: hue, saturation: 0.55, brightness: lb) > Theme.ChartLabel.darkTextThreshold { darkTextLight.insert(a.id) }
            if Theme.ChartLabel.luminance(hue: hue, saturation: 0.50, brightness: db) > Theme.ChartLabel.darkTextThreshold { darkTextDark.insert(a.id) }
        }
    }

    func color(for a: SunburstArc, scheme: ColorScheme) -> Color {
        (scheme == .dark ? dark[a.id] : light[a.id]) ?? Self.otherLight
    }

    /// 조각 위 이름 글자색: 조각 휘도에 따라 흑/백 (F11-5).
    func labelColor(for a: SunburstArc, scheme: ColorScheme) -> Color {
        let darkText = scheme == .dark ? darkTextDark.contains(a.id) : darkTextLight.contains(a.id)
        return darkText ? Theme.ChartLabel.onLight : Theme.ChartLabel.onDark
    }
}

/// 같은 arcs에 대해 팔레트를 다시 만들지 않도록 마지막 결과를 보관한다 (탐색 목록과 차트가 공유).
@MainActor
enum SunburstPaletteCache {
    private static var arcs: [SunburstArc] = []
    private static var palette = SunburstPalette(arcs: [])

    static func palette(for newArcs: [SunburstArc]) -> SunburstPalette {
        if newArcs != arcs {
            palette = SunburstPalette(arcs: newArcs)
            arcs = newArcs
        }
        return palette
    }
}

/// 폭에 맞게 이름을 말줄임 (CJK는 넓게 계산).
func truncatedName(_ s: String, width: CGFloat, ascii: CGFloat = 6, wide: CGFloat = 10.5) -> String? {
    var used: CGFloat = 0
    var out = ""
    let ellipsis: CGFloat = ascii * 1.5
    for ch in s {
        let w = ch.isASCII ? ascii : wide
        if used + w > width {
            guard !out.isEmpty else { return nil }
            while let last = out.last, used + ellipsis > width {
                used -= last.isASCII ? ascii : wide
                out.removeLast()
            }
            return out.isEmpty ? nil : out + "…"
        }
        used += w
        out.append(ch)
    }
    return out
}

func percentText(_ fraction: Double) -> String {
    fraction > 0 && fraction < 0.001 ? "0.1% 미만" : String(format: "%.1f%%", fraction * 100)
}

@MainActor
enum ExploreActions {
    static func revealInFinder(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func copyPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.sorted().joined(separator: "\n"), forType: .string)
    }

    /// 선택 항목의 합계 크기 (현재 폴더 행 기준).
    static func selectionTotal(_ model: AppModel) -> Int64 {
        model.rows.reduce(into: Int64(0)) { acc, row in
            if !row.isOmittedSummary, model.selection.contains(row.path) { acc += row.size }
        }
    }
}
