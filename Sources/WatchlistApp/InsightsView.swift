import AppKit
import Charts
import SwiftUI
import WatchlistCore

// palette (validated all-pairs for scatter, light and dark; see README)

enum VizPalette {
    static let slots: [Color] = [
        Color(light: 0x2a78d6, dark: 0x3987e5),
        Color(light: 0xeb6834, dark: 0xd95926),
        Color(light: 0x1baf7a, dark: 0x199e70),
    ]
    static let other = Color(light: 0x898781, dark: 0x898781)
    static let grid = Color(light: 0xe1e0d9, dark: 0x2c2c2a)
    static let surface = Color(light: 0xfcfcfb, dark: 0x1a1a19)
    static let textSecondary = Color(light: 0x52514e, dark: 0xc3c2b7)
}

extension Color {
    /// a color that follows the system appearance
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

// shared helpers

struct InsightsData {
    let points: [RatingPoint]
    let source: RatingSource
    let focus: String?

    /// the three most common primary genres across all reviews, so colors do not change with the source toggle
    var topGenres: [String] {
        var counts: [String: Int] = [:]
        for p in points { if let g = p.genres.first { counts[g, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3).map(\.key)
    }

    var allGenres: [String] {
        Array(Set(points.flatMap(\.genres))).sorted()
    }

    /// points that have the chosen outside score, filtered to the focused genre for the table
    var plotted: [RatingPoint] { points.filter { $0.external(source) != nil } }

    func group(_ p: RatingPoint) -> String {
        if let focus { return p.genres.contains(focus) ? focus : "Other genres" }
        if let g = p.genres.first, topGenres.contains(g) { return g }
        return "Other"
    }

    func color(_ group: String) -> Color {
        if let focus { return group == focus ? VizPalette.slots[0] : VizPalette.other }
        if let i = topGenres.firstIndex(of: group) { return VizPalette.slots[i] }
        return VizPalette.other
    }

    func isMuted(_ group: String) -> Bool { group == "Other" || group == "Other genres" }

    var legend: [String] {
        focus.map { [$0, "Other genres"] } ?? (topGenres + ["Other"])
    }
}

/// small deterministic spread so half-star ratings do not stack into one dot
func jitter(_ id: String) -> Double {
    var h: UInt64 = 1469598103934665603
    for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return (Double(h % 1000) / 1000 - 0.5) * 5
}

func scoreLabel(_ value: Double, _ source: RatingSource) -> String {
    source == .imdb ? String(format: "%.1f", value / 10) : "\(Int(value.rounded()))%"
}

func myLabel(_ rating: Double) -> String {
    let stars = ObsidianNote.stars(rating)
    return stars.isEmpty ? "0" : stars
}

// detail column: controls, stats, chart

/// hover lives in its own object so moving the cursor redraws only the tooltip layer, never the dots
@Observable
final class HoverState {
    var point: RatingPoint?
}

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var hover = HoverState()

    var body: some View {
        ScrollView {
            InsightsContent(hover: hover)
        }
        .task {
            if model.insightPoints.isEmpty { await model.loadInsights() }
        }
    }
}

/// everything inside the scroll view, separate so it can also be rendered to an image
struct InsightsContent: View {
    @Environment(AppModel.self) private var model
    let hover: HoverState

    var body: some View {
        @Bindable var model = model
        let data = InsightsData(points: model.insightPoints, source: model.insightSource, focus: model.insightGenre)
        VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("My Ratings vs. Everyone Else").font(.title2.bold())
                    Spacer()
                    Picker("Compare to", selection: $model.insightSource) {
                        ForEach(RatingSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Picker("Genre", selection: $model.insightGenre) {
                        Text("Top genres").tag(String?.none)
                        Divider()
                        ForEach(data.allGenres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .frame(width: 180)
                    Button {
                        Task { await model.loadInsights(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload from your notes")
                }

                if model.insightsLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.insightsProgress).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if data.plotted.isEmpty {
                    ContentUnavailableView("No Ratings to Compare", systemImage: "chart.dots.scatter",
                                           description: Text("Movie reviews need a rating and a \(model.insightSource.label) score. Use Fill IMDb and Rotten Tomatoes to add scores."))
                        .frame(minHeight: 300)
                } else {
                    StatsRow(data: data)
                    ScatterChart(points: data.points, source: data.source, focus: data.focus, hover: hover,
                                 open: { model.openReview(id: $0) })
                        .equatable()
                        .frame(maxWidth: 820)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(VizPalette.surface))
                    legend(data)
                    Text("Each dot is a movie you reviewed. On the dashed line your rating matches \(model.insightSource.detail); below it you liked the movie more, above it less. Your rating is scaled to 0 to 100 (5 stars = 100). Dots are spread slightly sideways so equal ratings do not overlap. Click a dot to open its review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
    }

    private func legend(_ data: InsightsData) -> some View {
        HStack(spacing: 16) {
            ForEach(data.legend, id: \.self) { g in
                HStack(spacing: 6) {
                    Circle().fill(data.color(g)).frame(width: 9, height: 9)
                    Text(g).font(.callout).foregroundStyle(.primary)
                    Text("\(data.plotted.filter { data.group($0) == g }.count)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

/// the dots. equatable on its inputs so hovering never rebuilds the marks.
struct ScatterChart: View, Equatable {
    let points: [RatingPoint]
    let source: RatingSource
    let focus: String?
    let hover: HoverState
    let open: (String) -> Void

    static func == (a: ScatterChart, b: ScatterChart) -> Bool {
        a.points == b.points && a.source == b.source && a.focus == b.focus
    }

    var body: some View {
        let data = InsightsData(points: points, source: source, focus: focus)
        // muted dots first so colored ones sit on top
        let ordered = data.plotted.sorted { data.isMuted(data.group($0)) && !data.isMuted(data.group($1)) }
        Chart {
            LineMark(x: .value("Mine", 0), y: .value("Theirs", 0), series: .value("Line", "parity"))
                .foregroundStyle(VizPalette.other)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            LineMark(x: .value("Mine", 100), y: .value("Theirs", 100), series: .value("Line", "parity"))
                .foregroundStyle(VizPalette.other)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(ordered) { p in
                let g = data.group(p)
                let x = p.mine + jitter(p.id)
                let y = p.external(source) ?? 0
                // a surface-colored ring under each dot keeps overlapping dots distinct
                PointMark(x: .value("Mine", x), y: .value("Theirs", y))
                    .symbol(.circle)
                    .symbolSize(150)
                    .foregroundStyle(VizPalette.surface)
                PointMark(x: .value("Mine", x), y: .value("Theirs", y))
                    .symbol(.circle)
                    .symbolSize(80)
                    .foregroundStyle(data.color(g).opacity(data.isMuted(g) && focus != nil ? 0.35 : 1))
            }
        }
        .chartXScale(domain: -4...104)
        .chartYScale(domain: -4...104)
        .chartPlotStyle { plot in plot.aspectRatio(1, contentMode: .fit) }
        .chartXAxis {
            AxisMarks(values: [0, 20, 40, 60, 80, 100]) { v in
                AxisGridLine().foregroundStyle(VizPalette.grid)
                AxisValueLabel { Text("\((v.as(Int.self) ?? 0) / 20)") }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 20, 40, 60, 80, 100]) { v in
                AxisGridLine().foregroundStyle(VizPalette.grid)
                AxisValueLabel { Text(scoreLabel(Double(v.as(Int.self) ?? 0), source)) }
            }
        }
        .chartXAxisLabel("My rating (stars)", alignment: .center)
        .chartYAxisLabel(source.label, position: .leading, alignment: .center)
        .chartOverlay { proxy in
            GeometryReader { geo in
                HoverLayer(proxy: proxy, geo: geo, points: data.plotted, source: source, hover: hover, open: open)
            }
        }
        .accessibilityLabel("Scatter plot of your ratings against \(source.label)")
    }
}

/// hit testing, the hover ring, the tooltip, and the corner labels
struct HoverLayer: View {
    let proxy: ChartProxy
    let geo: GeometryProxy
    let points: [RatingPoint]
    let source: RatingSource
    let hover: HoverState
    let open: (String) -> Void

    var body: some View {
        if let anchor = proxy.plotFrame {
            let frame: CGRect = geo[anchor]
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let loc):
                            let found = nearest(to: CGPoint(x: loc.x - frame.minX, y: loc.y - frame.minY))
                            if found?.id != hover.point?.id { hover.point = found }
                        case .ended:
                            hover.point = nil
                        }
                    }
                    .onTapGesture {
                        if let p = hover.point { open(p.id) }
                    }
                cornerLabel("You liked it more", x: 100, y: 2, trailing: true, frame: frame)
                cornerLabel("You liked it less", x: 0, y: 98, trailing: false, frame: frame)
                if let h = hover.point, let pos = position(h) {
                    let px = frame.minX + pos.x
                    let py = frame.minY + pos.y
                    Circle()
                        .stroke(Color.primary, lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .position(x: px, y: py)
                        .allowsHitTesting(false)
                    let flip = px + 230 > geo.size.width
                    Tooltip(point: h, source: source)
                        .offset(x: flip ? px - 222 : px + 14, y: max(0, min(py - 50, geo.size.height - 120)))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func position(_ p: RatingPoint) -> CGPoint? {
        let x: Double = p.mine + jitter(p.id)
        let y: Double = p.external(source) ?? 0
        return proxy.position(for: (x, y))
    }

    /// the dot under the cursor, within a few points of its center
    private func nearest(to loc: CGPoint) -> RatingPoint? {
        var best: RatingPoint?
        var bestDistance: CGFloat = 10
        for p in points {
            guard let pos = position(p) else { continue }
            let d = hypot(pos.x - loc.x, pos.y - loc.y)
            if d < bestDistance { best = p; bestDistance = d }
        }
        return best
    }

    @ViewBuilder
    private func cornerLabel(_ text: String, x: Double, y: Double, trailing: Bool, frame: CGRect) -> some View {
        if let pos = proxy.position(for: (x, y)) {
            Text(text)
                .font(.caption)
                .foregroundStyle(VizPalette.textSecondary)
                .frame(width: 160, alignment: trailing ? .trailing : .leading)
                .position(x: frame.minX + pos.x + (trailing ? -80 : 80), y: frame.minY + pos.y)
                .allowsHitTesting(false)
        }
    }
}

struct Tooltip: View {
    let point: RatingPoint
    let source: RatingSource

    var body: some View {
        let theirs = point.external(source) ?? 0
        let delta = point.delta(source) ?? 0
        VStack(alignment: .leading, spacing: 3) {
            Text(point.title).font(.callout.bold()).lineLimit(2)
            Text("You \(ObsidianNote.number(point.myRating)) of 5, \(source.label) \(scoreLabel(theirs, source))")
                .font(.caption)
            Text(delta >= 0 ? "You liked it \(Int(delta.rounded())) points more" : "You liked it \(Int((-delta).rounded())) points less")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !point.genres.isEmpty {
                Text(point.genres.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Click to open review").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct StatsRow: View {
    let data: InsightsData

    var body: some View {
        let deltas = data.plotted.compactMap { $0.delta(data.source) }
        let avg = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
        let close = deltas.filter { abs($0) <= 10 }.count
        let more = deltas.filter { $0 > 10 }.count
        let less = deltas.filter { $0 < -10 }.count
        HStack(spacing: 12) {
            tile("Movies", "\(deltas.count)", "rated, with a \(data.source.label) score")
            tile("Average difference", "\(avg >= 0 ? "+" : "")\(Int(avg.rounded()))",
                 avg >= 0 ? "you rate higher on average" : "you rate lower on average")
            tile("Within 10 points", "\(percent(close, deltas.count))", "\(close) movies")
            tile("Liked more", "\(more)", "over 10 points above")
            tile("Liked less", "\(less)", "over 10 points below")
        }
    }

    private func percent(_ n: Int, _ total: Int) -> String {
        total == 0 ? "0%" : "\(Int((Double(n) / Double(total) * 100).rounded()))%"
    }

    private func tile(_ label: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(VizPalette.surface))
    }
}

// content column: the table view of the same data

struct InsightsTable: View {
    @Environment(AppModel.self) private var model
    @State private var sort: Sort = .disagreement

    enum Sort: String, CaseIterable, Identifiable {
        case disagreement = "Biggest difference"
        case likedMore = "Liked more"
        case likedLess = "Liked less"
        case title = "Title"
        var id: String { rawValue }
    }

    var body: some View {
        let data = InsightsData(points: model.insightPoints, source: model.insightSource, focus: model.insightGenre)
        let rows = sorted(data.plotted.filter { model.insightGenre == nil || $0.genres.contains(model.insightGenre!) }, data.source)
        VStack(spacing: 0) {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .padding(10)
            List(rows) { p in
                Button {
                    model.openReview(id: p.id)
                } label: {
                    HStack {
                        Circle().fill(data.color(data.group(p))).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).lineLimit(1)
                            Text("You \(ObsidianNote.number(p.myRating)), \(data.source.label) \(scoreLabel(p.external(data.source) ?? 0, data.source))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let d = Int((p.delta(data.source) ?? 0).rounded())
                        Text(d > 0 ? "+\(d)" : "\(d)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sorted(_ points: [RatingPoint], _ s: RatingSource) -> [RatingPoint] {
        switch sort {
        case .disagreement: return points.sorted { abs($0.delta(s) ?? 0) > abs($1.delta(s) ?? 0) }
        case .likedMore: return points.sorted { ($0.delta(s) ?? 0) > ($1.delta(s) ?? 0) }
        case .likedLess: return points.sorted { ($0.delta(s) ?? 0) < ($1.delta(s) ?? 0) }
        case .title: return points.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}
