import AcademicCore
import SwiftUI

extension UnifiedTimelineSource {
    var calendarColor: Color {
        switch self {
        case .canvas: .blue
        case .outlook: .purple
        case .appleCalendar: .orange
        case .managedCalendar: .green
        case .demonstration, .unknown: .secondary
        }
    }
    var calendarSymbol: String {
        switch self {
        case .canvas: "book.closed"
        case .outlook: "envelope"
        case .appleCalendar: "calendar"
        case .managedCalendar: "graduationcap"
        case .demonstration: "sparkles"
        case .unknown: "questionmark.circle"
        }
    }
}

struct CalendarSidebar: View {
    @Binding var state: CalendarPresentationState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MiniCalendar(date: $state.date)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("CALENDARS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(UnifiedTimelineSource.allCases, id: \.self) { source in
                    Toggle(isOn: Binding(get: { state.visibleSources.contains(source) }, set: { enabled in
                        if enabled { state.visibleSources.insert(source) } else { state.visibleSources.remove(source) }
                    })) {
                        Label(source.label, systemImage: source.calendarSymbol)
                            .font(.callout).foregroundStyle(source.calendarColor)
                    }
                    .toggleStyle(.checkbox)
                    .help("Show or hide \(source.label). Scheduling still respects hidden commitments.")
                }
                Toggle(isOn: $state.showsReminderMarkers) {
                    Label("Reminder due dates", systemImage: "checklist").font(.callout).foregroundStyle(.teal)
                }
                .toggleStyle(.checkbox)
                .help("Show or hide Apple Reminders due-date markers. They are never busy time.")
                Text("Filters change this calendar only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16)
    }
}

struct MiniCalendar: View {
    @Binding var date: Date
    private var calendar: Calendar { .current }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(date.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month in mini-calendar")
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month in mini-calendar")
            }.buttonStyle(.borderless)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(CalendarPresentation.days(containing: date, mode: .month), id: \.self) { day in
                    Button { date = day } label: {
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 11, weight: calendar.isDateInToday(day) ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(calendar.isDate(day, inSameDayAs: date) ? Color.white : calendar.isDate(day, equalTo: date, toGranularity: .month) ? Color.primary : Color.secondary)
                            .background(calendar.isDate(day, inSameDayAs: date) ? Color.accentColor : .clear, in: Circle())
                            .overlay(Circle().stroke(calendar.isDateInToday(day) ? Color.accentColor : .clear))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(calendar.isDate(day, inSameDayAs: date) ? .isSelected : [])
                }
            }
        }
    }
    private func move(_ offset: Int) {
        date = calendar.date(byAdding: .month, value: offset, to: date) ?? date
    }
}
