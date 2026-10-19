import AcademicCore
import SwiftUI

struct CalendarMonthView: View {
    let events: [UnifiedTimelineEvent]
    @Binding var state: CalendarPresentationState
    private var calendar: Calendar { .current }
    private let columns = Array(repeating: GridItem(.flexible(minimum: 80), spacing: 1), count: 7)
    var body: some View {
        GeometryReader { geometry in
            let days = CalendarPresentation.days(containing: state.date, mode: .month)
            ScrollView([.horizontal, .vertical]) {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 10)
                    }
                    ForEach(days, id: \.self) { day in
                        monthCell(day, height: max(100, (geometry.size.height - 38) / CGFloat(days.count / 7)))
                    }
                }.frame(width: max(geometry.size.width, 560))
                    .background(Color(nsColor: .separatorColor).opacity(0.4))
            }
        }
    }
    private func monthCell(_ day: Date, height: CGFloat) -> some View {
        let dayEvents = CalendarPresentation.events(events, in: CalendarPresentation.dayInterval(day), sources: state.visibleSources)
        return VStack(alignment: .leading, spacing: 4) {
            Button { state.openDay(day) } label: {
                HStack {
                    Spacer()
                    Text(day.formatted(.dateTime.day())).font(.callout.weight(.medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(calendar.isDateInToday(day) ? Color.white : Color.primary)
                        .background(calendar.isDateInToday(day) ? Color.accentColor : .clear, in: Circle())
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open Day view for \(day.formatted(date: .complete, time: .omitted)), \(dayEvents.count) events")
            ForEach(Array(dayEvents.prefix(3))) { event in
                CalendarEventBlock(event: event, compact: true, selected: state.selectedEventID == event.id) { state.selectedEventID = event.id }
                    .frame(height: 20)
            }
            if dayEvents.count > 3 {
                Button("+\(dayEvents.count - 3) more") { state.openDay(day) }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(5).frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(calendar.isDate(day, inSameDayAs: state.date) ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
        .opacity(calendar.isDate(day, equalTo: state.date, toGranularity: .month) ? 1 : 0.55)
    }
}
