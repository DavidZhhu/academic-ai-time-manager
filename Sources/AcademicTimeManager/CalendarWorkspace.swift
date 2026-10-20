import AcademicCore
import SwiftUI

struct CalendarWorkspace: View {
    @Bindable var model: PlannerViewModel
    @Binding var state: CalendarPresentationState
    let effort: [String: Int]
    let priority: [String: Int]
    var openReminder: (String) -> Void = { _ in }
    @State private var draft: CalendarSessionDraft?
    private var interval: DateInterval { CalendarPresentation.visibleInterval(date: state.date, mode: state.mode) }
    private var events: [UnifiedTimelineEvent] {
        CalendarPresentation.events(model.timelineEvents, in: interval, sources: state.visibleSources)
    }
    private var reminderMarkers: [ReminderDueMarker] {
        state.showsReminderMarkers ? model.reminderMarkers(in: interval) : []
    }
    private var selectedEvent: UnifiedTimelineEvent? {
        // Resolve by ID against current scoped values; never retain a stale personal title on mode changes.
        model.timelineEvents.first { $0.id == state.selectedEventID && state.visibleSources.contains($0.source) }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                navigation.padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                HStack(spacing: 8) {
                    Label("Live data", systemImage: "checkmark.shield")
                        .fontWeight(.medium)
                    Text("· \(events.count) events" + (reminderMarkers.isEmpty ? "" : " · \(reminderMarkers.count) reminders due"))
                    Spacer()
                    Text(TimeZone.current.identifier)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 8)
                if state.visibleSources.isEmpty {
                    Text("All calendar sources are hidden. Enable a source in the sidebar.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
                } else if events.isEmpty {
                    Text("No events in this range for the selected sources.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
                }
                if state.mode == .month {
                    CalendarMonthView(events: events, markers: reminderMarkers, openReminder: openReminder, state: $state)
                } else {
                    CalendarTimeGrid(days: CalendarPresentation.days(containing: state.date, mode: state.mode), events: events,
                                     markers: reminderMarkers, openReminder: openReminder, state: $state,
                                     makeDraft: model.appleCalendar.draft, propose: { draft = $0 })
                }
                Divider()
                Group {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(model.message, systemImage: model.canvasSyncHasError ? "exclamationmark.triangle" : "arrow.clockwise")
                            .foregroundStyle(model.canvasSyncHasError ? .orange : .secondary).lineLimit(2).help(model.message)
                        if let date = model.lastSuccessfulCanvasSync {
                            Text("Canvas synced \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        }
                        Text(model.appleCalendar.status).foregroundStyle(.secondary).lineLimit(2).help(model.appleCalendar.status)
                    }.font(.caption2).padding(.horizontal, 18).padding(.vertical, 8)
                }
            }.frame(minWidth: 320)
            if state.showsTasks {
                AcademicTaskPanel(model: model, effort: effort, priority: priority, openReminder: openReminder)
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 340)
            }
        }
        .sheet(isPresented: Binding(get: { selectedEvent != nil || draft != nil }, set: {
            if !$0 { state.selectedEventID = nil; draft = nil }
        })) {
            if let draft {
                CalendarSessionEditor(model: model.appleCalendar, draft: draft).id(draft.id)
            } else if let event = selectedEvent {
                CalendarEventInspector(event: event, sources: model.dataset.sources,
                    edit: event.isEditableStudySession ? { draft = model.appleCalendar.draft(for: event) } : nil)
            }
        }
    }
    private var navigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                dateNavigation
                Spacer(minLength: 12)
                viewPicker
                newSessionButton
            }
            VStack(alignment: .leading, spacing: 10) {
                dateNavigation
                HStack { viewPicker; newSessionButton }
            }
        }
    }
    private var newSessionButton: some View {
        Button { draft = CalendarInteraction.create(on: state.date, fromMinute: 9 * 60) } label: {
            Label("New session", systemImage: "plus")
        }.keyboardShortcut("n", modifiers: .command)
            .help("Propose a study session. Review and approval are required before saving.")
    }
    private var dateNavigation: some View {
        HStack(spacing: 8) {
            Button { state.move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous \(state.mode.label.lowercased())")
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Today") { state.date = Date() }.keyboardShortcut("t", modifiers: .command)
            Button { state.move(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next \(state.mode.label.lowercased())")
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Text(title).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }.buttonStyle(.borderless)
    }
    private var title: String {
        switch state.mode {
        case .day: state.date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).year())
        case .month: state.date.formatted(.dateTime.month(.wide).year())
        case .week:
            "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(interval.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }
    private var viewPicker: some View {
        Picker("Calendar view", selection: $state.mode) {
            ForEach(AcademicCalendarMode.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Calendar view").frame(width: 210)
    }
}
