import SwiftUI
import StorageCore

struct SunburstView: View {
    @Bindable var model: AppModel
    var hover: ExploreHover
    private let holeFraction = 0.28

    @Environment(\.colorScheme) private var scheme
    @State private var hoverArc: SunburstArc?
    /// 마우스 위치: 이 뷰의 body 가 읽지 않는다 (툴팁 하위 뷰만 읽어 Canvas 재평가 방지, F11-4).
    @State private var pointer = ChartPointer()

    /// 고리 기하 (그리기·탭·호버가 같은 계산을 쓴다).
    private struct Dial {
        let center: CGPoint
        let outer: CGFloat
        let hole: CGFloat
        let ring: CGFloat

        init(size: CGSize, holeFraction: Double) {
            let side = min(size.width, size.height)
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            outer = side / 2 - 4
            hole = outer * holeFraction
            ring = (outer - hole) / 4
        }

        func hit(_ p: CGPoint, in arcs: [SunburstArc]) -> SunburstArc? {
            let dx = p.x - center.x, dy = p.y - center.y
            let r = (dx * dx + dy * dy).squareRoot()
            guard r >= hole, r <= outer else { return nil }
            let depth = Int((r - hole) / ring) + 1
            var ang = atan2(dy, dx) + .pi / 2
            if ang < 0 { ang += 2 * .pi }
            let frac = ang / (2 * .pi)
            return arcs.first { $0.depth == depth && $0.start <= frac && frac < $0.end }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let dial = Dial(size: geo.size, holeFraction: holeFraction)
            let arcs = model.arcs
            let palette = SunburstPaletteCache.palette(for: arcs)
            let total = max(arcs.filter { $0.depth == 1 }.reduce(Int64(0)) { $0 + $1.size }, 1)
            let rowHover = hover.rowHoverPath
            let highlight = highlightTest(arcs: arcs, rowHover: rowHover)
            let interactive = model.rowsMatchFocus

            ZStack {
                Canvas { ctx, _ in
                    draw(ctx, dial: dial, arcs: arcs, palette: palette, highlight: highlight)
                }
                .accessibilityHidden(true)
                .opacity(interactive ? 1 : Theme.Opacity.stale)

                centerContent(dial: dial, total: total)
                chartAccessibility(arcs: arcs, total: total, dial: dial)
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in
                if interactive, let a = dial.hit(loc, in: arcs) { activate(a) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    pointer.location = p
                    let a = interactive ? dial.hit(p, in: arcs) : nil
                    if a?.id != hoverArc?.id { hoverArc = a }
                case .ended:
                    hoverArc = nil
                }
            }
            .onChange(of: hoverArc?.id) { _, _ in
                hover.chartHoverPath = (hoverArc?.isOther == false) ? hoverArc?.path : nil
            }
            .overlay(alignment: .topLeading) {
                if let a = hoverArc {
                    SunburstTooltip(arc: a, total: total, pointer: pointer, size: geo.size)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if arcs.isEmpty { Text("표시할 데이터 없음").foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("용량 선버스트 차트")
            .accessibilityHint("조각을 활성화하면 폴더는 확대, 파일은 선택합니다. 목록이 같은 정보를 제공합니다.")
            .accessibilityAction(named: "상위로") { model.focusUp() }
        }
        .padding(8)
    }

    // MARK: - 그리기

    /// 호버 대상(차트 또는 목록)과 관련 있는 조각인지. 호버가 없으면 nil.
    private func highlightTest(arcs: [SunburstArc], rowHover: String?) -> ((SunburstArc) -> Bool)? {
        if let a = hoverArc {
            if a.isOther { return { $0.id == a.id } }
            let p = a.path
            return { $0.isOther ? false : ($0.path == p || $0.path.hasPrefix(p + "/") || p.hasPrefix($0.path + "/")) }
        }
        if let p = rowHover, arcs.contains(where: { !$0.isOther && ($0.path == p || $0.path.hasPrefix(p + "/")) }) {
            return { !$0.isOther && ($0.path == p || $0.path.hasPrefix(p + "/")) }
        }
        return nil
    }

    private func draw(_ ctx: GraphicsContext, dial: Dial, arcs: [SunburstArc], palette: SunburstPalette,
                      highlight: ((SunburstArc) -> Bool)?) {
        for a in arcs {
            let r0 = dial.hole + dial.ring * CGFloat(a.depth - 1)
            let r1 = r0 + dial.ring - 1
            // 외곽선 대신 조각 사이에 배경이 비치는 얇은 틈을 둬 fill 한 번으로 그린다 (perf-12, design-11).
            let span = (a.end - a.start) * 2 * .pi
            let gap = min(0.75 / max(r0, 1), span * 0.25)
            let s0 = a.start * 2 * .pi - .pi / 2 + gap / 2
            let e0 = a.end * 2 * .pi - .pi / 2 - gap / 2
            var p = Path()
            p.addArc(center: dial.center, radius: r1, startAngle: .radians(s0), endAngle: .radians(e0), clockwise: false)
            p.addArc(center: dial.center, radius: r0, startAngle: .radians(e0), endAngle: .radians(s0), clockwise: true)
            p.closeSubpath()
            let dim = highlight.map { !$0(a) } ?? false
            ctx.fill(p, with: .color(palette.color(for: a, scheme: scheme).opacity(dim ? Theme.Opacity.dim : 1)))
        }
        // 큰 조각(깊이 1~2)에만 이름 직접 표기
        for a in arcs where a.depth <= 2 && !a.isOther {
            let rm = dial.hole + dial.ring * (CGFloat(a.depth) - 0.5)
            let arcLen = (a.end - a.start) * 2 * .pi * rm
            guard arcLen >= 48, dial.ring >= 16 else { continue }
            let theta = (a.start + a.end) / 2 * 2 * .pi - .pi / 2
            let w = min(dial.ring / max(abs(cos(theta)), 0.15), arcLen / max(abs(sin(theta)), 0.15))
            guard let text = truncatedName(a.name, width: w - 4) else { continue }
            let pos = CGPoint(x: dial.center.x + rm * cos(theta), y: dial.center.y + rm * sin(theta))
            let dim = highlight.map { !$0(a) } ?? false
            ctx.draw(Text(text).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.labelColor(for: a, scheme: scheme).opacity(dim ? Theme.Opacity.dim : 1)), at: pos)
        }
    }

    // MARK: - 중앙

    @ViewBuilder private func centerContent(dial: Dial, total: Int64) -> some View {
        let atTop = model.outcome.map { $0.parentPath(of: model.focusPath) == nil } ?? true
        if atTop {
            VStack(spacing: 1) {
                Text(folderName).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(Fmt.bytes(total)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: dial.hole * 1.7)
            .position(dial.center)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("현재 폴더 \(folderName), \(Fmt.bytes(total)), 최상위")
        } else {
            Button { model.focusUp() } label: {
                Label("상위로", systemImage: "arrow.up").labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("상위 폴더로 (⌘↑)")
            .position(dial.center)
        }
    }

    private var folderName: String {
        model.outcome?.breadcrumb(for: model.focusPath).last?.name ?? "/"
    }

    // MARK: - 접근성

    /// 조각마다 실제 조각 위치(중간 반지름·각도)에 놓인 투명 요소. "기타"는 동작 없는 읽기 전용.
    private func chartAccessibility(arcs: [SunburstArc], total: Int64, dial: Dial) -> some View {
        let top = arcs.filter { $0.depth == 1 }.sorted { $0.size > $1.size }.prefix(12)
        return ZStack {
            ForEach(Array(top)) { a in
                let rm = dial.hole + dial.ring * 0.5
                let theta = (a.start + a.end) / 2 * 2 * .pi - .pi / 2
                let arcLen = (a.end - a.start) * 2 * .pi * rm
                let side = max(16, min(dial.ring, arcLen))
                let label = "\(a.name), \(Fmt.bytes(a.size)), \(percentText(Double(a.size) / Double(total)))"
                Group {
                    if a.isOther {
                        Color.clear.frame(width: side, height: side)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(label)
                    } else {
                        Color.clear.frame(width: side, height: side)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(label)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { activate(a) }
                    }
                }
                .position(x: dial.center.x + rm * cos(theta), y: dial.center.y + rm * sin(theta))
            }
        }
    }

    /// 조각 활성화: 폴더는 확대, 파일은 선택, "기타"는 무시.
    private func activate(_ a: SunburstArc) {
        guard !a.isOther, model.rowsMatchFocus else { return }
        // 파일은 reveal 과 같은 동작: 부모 폴더로 포커스한 뒤 선택 (목록에 없는 경로를 선택하지 않는다, F11-1).
        if a.isDirectory { model.focus(a.path) } else { model.reveal(path: a.path) }
    }
}

/// 마우스 위치 보관 (관찰은 SunburstTooltip 만).
@MainActor @Observable
final class ChartPointer {
    var location: CGPoint = .zero
}

/// 툴팁 (작은 유리 카드). 위치가 바뀔 때 이 뷰만 다시 그려진다.
private struct SunburstTooltip: View {
    let arc: SunburstArc
    let total: Int64
    let pointer: ChartPointer
    let size: CGSize

    private static let width: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(arc.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text("\(Fmt.bytes(arc.size)) · \(percentText(Double(arc.size) / Double(total)))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: Self.width, alignment: .leading)
        .glassEffect(.regular, in: Theme.cardShape)
        .offset(offset)
    }

    private var offset: CGSize {
        let p = pointer.location
        let x = p.x + 14 + Self.width > size.width ? p.x - 14 - Self.width : p.x + 14
        let y = min(max(p.y + 14, 0), max(size.height - 54, 0))
        return CGSize(width: max(x, 0), height: y)
    }
}
