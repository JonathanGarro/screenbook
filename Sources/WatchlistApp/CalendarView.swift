import SwiftUI
import WatchlistCore

// colors: tv and movies use the first two validated categorical slots

enum CalendarColors {
    static func color(_ type: MediaType) -> Color { type == .tv ? VizPalette.slots[0] : VizPalette.slots[1] }
}

func shortDay(_ day: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: day) else { return day }
    let out = DateFormatter()
    out.setLocalizedDateFormatFromTemplate("MMM d")
    return out.string(from: d)
}

func weekday(_ day: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: day) else { return "" }
    let out = DateFormatter()
    out.setLocalizedDateFormatFromTemplate("EEE")
    return out.string(from: d)
}

// next 30 days as a month grid

struct CalendarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView { CalendarContent() }
            .task { if model.calendarEvents.isEmpty { await model.loadCalendar() } }
    }
}

/// the page without the scroll view, also used for rendering to an image
struct CalendarContent: View {
    @Environment(AppModel.self) private var model
    private let days = 30
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    /// below this width a month grid gets too narrow to read, so the next week is listed day by day
    private let gridMinWidth: CGFloat = 620
    @State private var measured: CGFloat = 1000
    /// a fixed content width for rendering to an image, where nothing gets measured
    var renderWidth: CGFloat?
    private var width: CGFloat { renderWidth ?? measured }

    var body: some View {
        let byDay = Dictionary(grouping: model.calendarEvents, by: \.date)
        return VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Next 30 Days").font(.title2.bold())
                    if model.calendarLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    HStack(spacing: 14) {
                        legend(.tv, "TV episode")
                        legend(.movie, "Movie release")
                    }
                    .font(.callout)
                }
                UpcomingCovers(entries: upcomingTitles(), width: width)
                if width >= gridMinWidth {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(weekdaySymbols(), id: \.self) { s in
                            Text(s).font(.caption.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                        ForEach(gridDays(), id: \.self) { day in
                            DayCell(day: day, events: byDay[day] ?? [], inRange: inRange(day), isToday: day == model.today)
                        }
                    }
                } else {
                    Text("Next 7 Days").font(.headline).padding(.top, 4)
                    VStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { i in
                            let day = DateText.addDays(model.today, i)
                            DayRow(day: day, events: byDay[day] ?? [], isToday: i == 0)
                        }
                    }
                }
                if model.calendarEvents.isEmpty && !model.calendarLoading {
                    Text("Nothing on your watchlist is scheduled in the next 30 days.")
                        .foregroundStyle(.secondary)
                }
                Text("Episode dates are original air dates from TMDB. Click an entry to open the title; the calendar button in the toolbar brings you back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { measured = g.size.width - 40 }
                    .onChange(of: g.size.width) { _, w in measured = w - 40 }
            })
    }

    /// each title with something in the next 30 days, once, by its first date
    private func upcomingTitles() -> [(event: CalendarEvent, title: Title?)] {
        let end = DateText.addDays(model.today, days)
        var seen = Set<String>()
        return model.calendarEvents
            .filter { $0.date >= model.today && $0.date <= end }
            .sorted { ($0.date, $0.title) < ($1.date, $1.title) }
            .filter { seen.insert($0.titleId).inserted }
            .map { ($0, model.title($0.titleId)) }
    }

    private func legend(_ type: MediaType, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(CalendarColors.color(type)).frame(width: 9, height: 9)
            Text(text)
        }
    }

    private var calendar: Calendar { Calendar.current }

    private func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    private func inRange(_ day: String) -> Bool {
        day >= model.today && day <= DateText.addDays(model.today, days)
    }

    /// whole weeks covering today through 30 days out, starting on the locale's first weekday
    private func gridDays() -> [String] {
        guard let start = date(model.today) else { return [] }
        let weekdayIndex = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -weekdayIndex, to: start)!
        let lastDay = calendar.date(byAdding: .day, value: days, to: start)!
        let total = (calendar.dateComponents([.day], from: first, to: lastDay).day ?? days) + 1
        let cells = Int((Double(total) / 7).rounded(.up)) * 7
        return (0..<cells).map { DateText.day(calendar.date(byAdding: .day, value: $0, to: first)!) }
    }

    private func weekdaySymbols() -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}

/// covers for what is coming in the next 30 days, as many as fit (up to four), then a quiet "+N more"
struct UpcomingCovers: View {
    @Environment(AppModel.self) private var model
    let entries: [(event: CalendarEvent, title: Title?)]
    let width: CGFloat
    private let spacing: CGFloat = 12
    private let minTile: CGFloat = 110
    private let maxTile: CGFloat = 170

    var body: some View {
        if !entries.isEmpty {
            // leave room for the "+N more" label when not everything fits
            let room = entries.count > 1 ? width - 64 : width
            let fit = max(1, min(4, Int((room + spacing) / (minTile + spacing))))
            let shown = Array(entries.prefix(fit))
            let usable = entries.count > shown.count ? width - 64 : width
            let tile = min(maxTile, (usable - spacing * CGFloat(fit - 1)) / CGFloat(fit))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(shown, id: \.event.id) { entry in
                    cover(entry, tile: tile)
                }
                if entries.count > shown.count {
                    Text("+\(entries.count - shown.count) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .help(entries.dropFirst(shown.count).map { "\($0.event.title), \(shortDay($0.event.date))" }.joined(separator: "\n"))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func cover(_ entry: (event: CalendarEvent, title: Title?), tile: CGFloat) -> some View {
        let e = entry.event
        let url = entry.title?.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") }
        return Button {
            model.selectedTitleID = e.titleId
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Text(e.title).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(6))
                }
                .frame(width: tile, height: tile * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(e.title).font(.caption.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(CalendarColors.color(e.mediaType)).frame(width: 6, height: 6)
                    Text("\(shortDay(e.date)) \u{00B7} \(e.label)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: tile, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(e.episodeName.map { "\(e.title), \(e.label): \($0)" } ?? "\(e.title), \(e.label)")
    }
}

/// one day as a full-width row, used when the window is too narrow for the month grid
struct DayRow: View {
    @Environment(AppModel.self) private var model
    let day: String
    let events: [CalendarEvent]
    let isToday: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(weekday(day)).font(.caption.bold()).foregroundStyle(isToday ? Color.accentColor : .secondary)
                Text(shortDay(day)).font(.callout.weight(.semibold).monospacedDigit())
            }
            .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if events.isEmpty {
                    Text("Nothing scheduled").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(events) { e in
                    Button {
                        model.selectedTitleID = e.titleId
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(CalendarColors.color(e.mediaType)).frame(width: 7, height: 7)
                            Text(e.title).font(.callout).lineLimit(1)
                            Text(e.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(VizPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isToday ? Color.accentColor : Color.secondary.opacity(0.15)))
    }
}

struct DayCell: View {
    @Environment(AppModel.self) private var model
    let day: String
    let events: [CalendarEvent]
    let inRange: Bool
    let isToday: Bool
    private let maxShown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(dayNumber)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : (inRange ? Color.primary : Color.secondary))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isToday ? Color.accentColor : .clear))
                if dayNumber == "1" { Text(monthName).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
            }
            ForEach(events.prefix(maxShown)) { e in
                Button {
                    model.selectedTitleID = e.titleId
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(CalendarColors.color(e.mediaType)).frame(width: 6, height: 6)
                        Text(e.mediaType == .tv ? "\(e.title) \(e.label)" : e.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(e))
            }
            if events.count > maxShown {
                Text("+\(events.count - maxShown) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(events.dropFirst(maxShown).map(help).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(inRange ? VizPalette.surface : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isToday ? Color.accentColor : Color.secondary.opacity(0.15)))
        .opacity(inRange ? 1 : 0.45)
    }

    private var parsed: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    private var dayNumber: String {
        parsed.map { String(Calendar.current.component(.day, from: $0)) } ?? ""
    }

    private var monthName: String {
        guard let d = parsed else { return "" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f.string(from: d)
    }

    private func help(_ e: CalendarEvent) -> String {
        var s = "\(e.title), \(e.label)"
        if let n = e.episodeName { s += ": \(n)" }
        return s
    }
}
