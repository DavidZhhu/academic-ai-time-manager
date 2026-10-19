import AcademicCore
import SwiftUI

/// A horizontally scrollable week keeps event labels usable in a narrow window.
/// Day columns use elapsed hours; DST days label their own repeated/skipped local hours.
struct CalendarTimeGrid: View {
    let days: [Date]
    let events: [UnifiedTimelineEvent]
    @Binding var state: CalendarPresentationState
    private let hourHeight: CGFloat = 72
    private let gutter: CGFloat = 52
    private var calendar: Calendar { .current }
    private var hourCount: Int {
        Int(ceil(days.map { CalendarPresentation.dayInterval($0).duration / 3600 }.max() ?? 24))
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    dayHeaders
                    allDayRow
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
                                timeLabels
                                HStack(spacing: 0) {
                                    Color.clear.frame(width: gutter)
                                    ForEach(days, id: \.self) { day in
                                        dayColumn(day).frame(maxWidth: .infinity)
                                    }
                                }
                            }.frame(height: CGFloat(hourCount) * hourHeight)
                        }
                        .onAppear { proxy.scrollTo(8, anchor: .top) }
                    }
                }
                .frame(width: max(geometry.size.width, gutter + CGFloat(days.count) * (days.count == 1 ? 260 : 112)), height: geometry.size.height)
            }
        }
    }
    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Text(TimeZone.current.abbreviation() ?? "Time")
                .font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
            ForEach(days, id: \.self) { day in
                Button { state.openDay(day) } label: {
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                        Text(day.formatted(.dateTime.day())).font(.title2.weight(.medium))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(calendar.isDateInToday(day) ? Color.white : Color.primary)
                            .background(calendar.isDateInToday(day) ? Color.accentColor : .clear, in: Circle())
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(calendar.isDate(day, inSameDayAs: state.date) ? Color.accentColor.opacity(0.05) : .clear)
                }.buttonStyle(.plain).accessibilityLabel("Open \(day.formatted(date: .complete, time: .omitted))")
            }
        }
    }
    private var allDayRow: some View {
        let count = days.map { dayEvents($0).filter(\.isAllDay).count }.max() ?? 0
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                Text("All day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter).padding(.top, 8)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        ForEach(dayEvents(day).filter(\.isAllDay)) { event in
                            CalendarEventBlock(event: event, compact: true, selected: state.selectedEventID == event.id) { state.selectedEventID = event.id }
                                .frame(height: 26)
                        }
                    }.padding(4).frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                        .overlay(alignment: .trailing) { Divider() }
                }
            }
        }
        .frame(height: min(130, max(34, CGFloat(count) * 30 + 8)))
    }
    private var timeLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<hourCount, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing)
                    .id(hour)
            }
        }
    }
    private func dayColumn(_ day: Date) -> some View {
        let interval = CalendarPresentation.dayInterval(day)
        let hours = Int(ceil(interval.duration / 3600))
        let placements = CalendarPresentation.timedPlacements(events, on: day)
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(calendar.isDateInToday(day) ? Color.accentColor.opacity(0.035) : Color.clear)
                ForEach(0...hours, id: \.self) { hour in
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 0.5)
                        .offset(y: CGFloat(hour) * hourHeight)
                    if interval.duration != 86400, hour < hours {
                        Text(dstHourLabel(interval.start.addingTimeInterval(Double(hour) * 3600)))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .offset(x: 3, y: CGFloat(hour) * hourHeight + 1)
                    }
                }
                ForEach(placements) { placement in
                    let laneWidth = geometry.size.width / CGFloat(placement.columnCount)
                    CalendarEventBlock(event: placement.event,
                        compact: placement.durationMinutes < 48,
                        selected: state.selectedEventID == placement.event.id) { state.selectedEventID = placement.event.id }
                        .frame(width: max(1, laneWidth - 4), height: max(3, CGFloat(placement.durationMinutes) / 60 * hourHeight - 1))
                        .offset(x: CGFloat(placement.column) * laneWidth + 2, y: CGFloat(placement.startMinute) / 60 * hourHeight)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if interval.contains(context.date), context.date < interval.end {
                        let y = CGFloat(CalendarPresentation.minuteOffset(context.date, on: day)) / 60 * hourHeight
                        HStack(spacing: 0) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Rectangle().fill(.red).frame(height: 1)
                        }.offset(y: y - 3).allowsHitTesting(false)
                            .accessibilityLabel("Current time \(context.date.formatted(date: .omitted, time: .shortened))")
                    }
                }.allowsHitTesting(false)
            }
            .frame(height: CGFloat(hours) * hourHeight)
            .overlay(alignment: .trailing) { Divider() }
            .clipped()
        }
    }
    private func dstHourLabel(_ date: Date) -> String {
        "\(date.formatted(date: .omitted, time: .shortened)) \(calendar.timeZone.abbreviation(for: date) ?? "")"
    }
    private func dayEvents(_ day: Date) -> [UnifiedTimelineEvent] {
        CalendarPresentation.events(events, in: CalendarPresentation.dayInterval(day), sources: state.visibleSources)
    }
}
