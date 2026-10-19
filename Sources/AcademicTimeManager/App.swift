import AcademicCore
import SwiftUI
import Foundation

@main
struct AcademicTimeManagerApp: App {
    @State private var model = PlannerViewModel()
    @State private var outlook = OutlookViewModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, outlook: outlook)
                .frame(minWidth: 820, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
@Observable
final class PlannerViewModel {
    var items: [AcademicItem] = []
    var reviews: [ReviewItem] = []
    var sourceRecords: [SourceRecord] = []
    var conflicts: [AcademicConflict] = []
    var availability = AvailabilitySettings()
    var planResult: AssignmentStudyPlan?
    var assignmentProgress: [String: AssignmentProgress] = [:]
    var assignmentProgressError: String?
    var dataMode: StudyDataMode = .live {
        didSet { if dataMode != oldValue { planResult = nil; assignmentProgressError = nil } }
    }
    var message = "Use Sync to load Oxford Canvas data, or select Demo Mode to explore sample data."
    var database: LocalDatabase?
    var isSyncingCanvas = false
    var canvasSyncHasError = false
    var lastSuccessfulCanvasSync: Date?
    private let canvasSync = CanvasSyncService()

    init() {
        let fixture = SampleData.make()
        do {
            let db = try LocalDatabase(path: Self.databasePath())
            for source in fixture.sources { try db.save(source) }
            for item in fixture.items { try db.save(item) }
            let savedReviews = try db.reviewItems()
            for review in fixture.reviews where !savedReviews.contains(where: { $0.id == review.id }) { try db.save(review) }
            let savedConflicts = try db.conflicts()
            for conflict in fixture.conflicts where !savedConflicts.contains(where: { $0.id == conflict.id }) { try db.save(conflict) }
            availability = try db.availabilitySettings() ?? AvailabilitySettings()
            try db.save(availability)
            database = db
            items = try db.items()
            assignmentProgress = try db.assignmentProgress()
            lastSuccessfulCanvasSync = try db.lastSuccessfulCanvasSync()
            reviews = try db.reviewItems()
            sourceRecords = try db.sourceRecords()
            conflicts = try db.conflicts()
            if lastSuccessfulCanvasSync != nil { message = "Showing saved Oxford Canvas data. Use Sync to refresh it." }
        } catch {
            database = nil
            items = fixture.items
            reviews = fixture.reviews
            sourceRecords = fixture.sources
            conflicts = fixture.conflicts
            message = "Local storage unavailable. Demo Mode is available with sample data in memory."
        }
    }

    func synchronizeCanvas() {
        guard dataMode == .live else { return }
        guard let database else { message = "Local storage is unavailable, so Canvas data cannot be saved."; return }
        guard !isSyncingCanvas else { return }
        isSyncingCanvas = true
        canvasSyncHasError = false
        message = "Syncing read-only data from Oxford Canvas…"
        Task {
            defer { isSyncingCanvas = false }
            do {
                let batch = try await canvasSync.fetch()
                try database.importCanvas(batch.result, successfulAt: batch.completedAt)
                items = try database.items()
                sourceRecords = try database.sourceRecords()
                lastSuccessfulCanvasSync = try database.lastSuccessfulCanvasSync()
                planResult = nil
                canvasSyncHasError = false
                message = "Canvas sync complete: \(batch.report.courseCount) courses, \(batch.report.sourceRecordCount) records and \(batch.report.academicItemCount) timeline events imported. Generate a new proposal to account for updated commitments."
            } catch {
                canvasSyncHasError = true
                message = error.localizedDescription
            }
        }
    }

    func reloadImportedData() {
        guard let database else { return }
        do {
            items = try database.items(); sourceRecords = try database.sourceRecords()
            planResult = nil
        } catch { message = "Could not reload imported data from local storage." }
    }

    func generatePlan(estimates: [String: Int] = [:], priorities: [String: Int] = [:]) {
        planResult = dataset.makePlan(progress: assignmentProgress,
            availability: availability, estimates: estimates, priorities: priorities, now: Date())
    }

    var dataset: AcademicDataset {
        AcademicDataset(mode: dataMode, items: items, sources: sourceRecords, reviews: reviews, conflicts: conflicts)
    }

    var assignments: [PlanningAssignment] { dataset.assignments }

    func assignmentStatus(for id: String) -> AssignmentStatus { assignmentProgress[id]?.status ?? .notStarted }

    func setAssignmentStatus(_ status: AssignmentStatus, for id: String) {
        guard let database else {
            assignmentProgressError = "Local storage is unavailable. Assignment status could not be saved."
            return
        }
        let updated = AssignmentProgress(assignmentID: id, status: status)
        do {
            try database.save(updated)
            assignmentProgress[id] = updated
            assignmentProgressError = nil
            planResult = nil
        } catch {
            assignmentProgressError = "Could not save assignment status. Your previous status has been kept. Try again."
        }
    }

    func sourceName(for sourceID: String) -> String {
        sourceRecords.first(where: { $0.id == sourceID })?.provider ?? "Unknown source"
    }

    func saveAvailability() {
        do { try database?.save(availability); message = "Availability preferences saved locally." }
        catch { message = "Could not save availability: \(error.localizedDescription)" }
    }

    func resolve(_ review: ReviewItem, as decision: ReviewDecision) {
        var updated = review; updated.decision = decision
        if decision == .accepted { updated.state = .verified }
        if decision == .rejected { updated.state = .disputed }
        do { try database?.save(updated); reviews = try database?.reviewItems() ?? reviews.map { $0.id == updated.id ? updated : $0 } }
        catch { message = "Could not save review decision: \(error.localizedDescription)" }
    }

    private static func databasePath() -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AcademicTimeManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("planner.sqlite").path
    }
}

struct ContentView: View {
    @Bindable var model: PlannerViewModel
    @Bindable var outlook: OutlookViewModel
    @State private var selected = "Timeline"
    @State private var calendarMode: CalendarMode = .week
    @State private var selectedDate = Date()
    @State private var assignmentEffort: [String: Int] = [:]
    @State private var assignmentPriority: [String: Int] = [:]
    @State private var canvasConnection = CanvasConnectionViewModel()
    private let sections = ["Timeline", "Plan preview", "Review inbox", "Availability", "Connections"]
    var body: some View {
        NavigationSplitView {
            List(sections, id: \.self, selection: $selected) { section in
                Label(section, systemImage: icon(for: section)).tag(section)
            }
            .navigationTitle("Academic Planner")
        } detail: {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    dataModeControls
                    switch selected {
                    case "Plan preview": planView
                    case "Review inbox": reviewView
                    case "Availability": availabilityView
                    case "Connections": connectionsView
                    default: timelineView
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .safeAreaPadding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.synchronizeCanvas() } label: {
                    if model.isSyncingCanvas { Label("Syncing…", systemImage: "arrow.triangle.2.circlepath") }
                    else { Label("Sync Canvas", systemImage: "arrow.clockwise") }
                }.disabled(model.isSyncingCanvas || model.database == nil || model.dataMode == .demo)
            }
            if model.isSyncingCanvas { ToolbarItem(placement: .status) { ProgressView().controlSize(.small).help("Reading Canvas data") } }
            if model.canvasSyncHasError { ToolbarItem(placement: .status) { Label("Sync failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(model.message) } }
        }
        .task(id: model.dataMode) {
            outlook.attach(model.database)
            guard model.dataMode == .live else { return }
            while !Task.isCancelled {
                if await outlook.poll() { model.reloadImportedData() }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: canvasConnection.isConnected) { _, connected in
            if connected { model.dataMode = .live }
        }
    }

    private var dataModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Data mode", selection: $model.dataMode) {
                ForEach(StudyDataMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360)
                .disabled(model.isSyncingCanvas || outlook.busy)
            Text(model.dataMode == .demo
                 ? "Demo Mode · Sample assignments and events only. Switch to Live data to plan your academic work."
                 : "Live data · Demonstration assignments and events are excluded from this calendar and study planning.")
                .font(.callout).foregroundStyle(model.dataMode == .demo ? .orange : .secondary)
        }
    }

    private var timelineView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                heading(model.dataMode == .demo ? "Demonstration calendar" : "Academic calendar",
                        subtitle: model.dataMode == .demo ? "Sample events for exploring the app" : "Canvas events and approved Outlook commitments")
                Spacer()
                Picker("Calendar view", selection: $calendarMode) {
                    ForEach(CalendarMode.allCases) { mode in Text(mode.label).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 240)
            }
            if model.dataMode == .live {
                Label(model.message, systemImage: model.canvasSyncHasError ? "exclamationmark.triangle.fill" : "info.circle").font(.callout).foregroundStyle(model.canvasSyncHasError ? .orange : .secondary)
                if model.isSyncingCanvas { ProgressView("Reading courses, assignments and calendar events from Oxford Canvas…").controlSize(.small) }
                if let lastSync = model.lastSuccessfulCanvasSync {
                    Label("Last successful Canvas sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))", systemImage: "arrow.clockwise.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            calendarNavigation
            switch calendarMode {
            case .day: eventList(for: dayEvents())
            case .week: eventList(for: weekEvents())
            case .month: monthCalendar
            }
            Spacer()
        }
    }

    private var calendarNavigation: some View {
        HStack {
            Button { moveCalendar(by: -1) } label: { Label("Previous", systemImage: "chevron.left") }
                .labelStyle(.iconOnly).help("Previous \(calendarMode.label.lowercased())")
            Button("Today") { selectedDate = Date() }
            Button { moveCalendar(by: 1) } label: { Label("Next", systemImage: "chevron.right") }
                .labelStyle(.iconOnly).help("Next \(calendarMode.label.lowercased())")
            Text(calendarTitle).font(.title2.bold()).padding(.leading, 8)
            Spacer()
        }
    }

    private var calendarTitle: String {
        switch calendarMode {
        case .day: return selectedDate.formatted(date: .complete, time: .omitted)
        case .week:
            let range = weekRange()
            return "\(range.start.formatted(date: .abbreviated, time: .omitted)) – \(range.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))"
        case .month: return selectedDate.formatted(.dateTime.month(.wide).year())
        }
    }

    private func moveCalendar(by amount: Int) {
        let component: Calendar.Component = calendarMode == .day ? .day : calendarMode == .week ? .weekOfYear : .month
        if let next = Calendar.current.date(byAdding: component, value: amount, to: selectedDate) { selectedDate = next }
    }

    private func dayEvents() -> [AcademicItem] {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: selectedDate)) else { return [] }
        return model.dataset.items.filter { $0.startsAt >= calendar.startOfDay(for: selectedDate) && $0.startsAt < end }.sorted { $0.startsAt < $1.startsAt }
    }

    private func weekRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate)
        let weekday = calendar.component(.weekday, from: dayStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return (start, end)
    }

    private func weekEvents() -> [AcademicItem] {
        let range = weekRange()
        return model.dataset.items.filter { $0.startsAt >= range.start && $0.startsAt < range.end }.sorted { $0.startsAt < $1.startsAt }
    }

    private var monthCalendar: some View {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: selectedDate)
        let monthStart = calendar.date(from: components) ?? selectedDate
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<2
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(weekdaySymbols(), id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 78) }
                ForEach(dayRange, id: \.self) { number in
                    if let date = calendar.date(byAdding: .day, value: number - 1, to: monthStart) {
                        monthDay(date, number: number)
                    }
                }
            }
            if !dayEvents().isEmpty {
                Text("Events on \(selectedDate.formatted(date: .complete, time: .omitted))").font(.title3.bold())
                eventList(for: dayEvents())
            }
        }
    }

    private func weekdaySymbols() -> [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let first = max(0, min(symbols.count - 1, Calendar.current.firstWeekday - 1))
        return Array(symbols[first...] + symbols[..<first])
    }

    private func monthDay(_ date: Date, number: Int) -> some View {
        let events = model.dataset.items.filter { Calendar.current.isDate($0.startsAt, inSameDayAs: date) }
        return Button { selectedDate = date } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("\(number)").font(.callout.bold()); if Calendar.current.isDateInToday(date) { Circle().fill(.blue).frame(width: 6, height: 6) } }
                ForEach(Array(events.prefix(2))) { item in
                    HStack(spacing: 3) { Circle().fill(color(for: item.kind)).frame(width: 5, height: 5); Text(item.title).lineLimit(1).font(.system(size: 9)) }
                }
                if events.count > 2 { Text("+\(events.count - 2) more").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .padding(7).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(Calendar.current.isDate(date, inSameDayAs: selectedDate) ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(events.count) events")
    }

    @ViewBuilder
    private func eventList(for events: [AcademicItem]) -> some View {
        if events.isEmpty {
            ContentUnavailableView("No events", systemImage: "calendar", description: Text("There are no events in this range for the selected data mode."))
        } else {
            ForEach(events) { item in
                let providers = item.sourceRecordIDs.map(model.sourceName(for:))
                let isCanvasImport = providers.contains("Canvas")
                let isOutlookImport = providers.contains("Outlook")
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(item.startsAt.formatted(date: .omitted, time: .shortened)).font(.headline)
                        Text(item.startsAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        if item.endsAt > item.startsAt { Text("to \(item.endsAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }.frame(width: 105, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2).fill(color(for: item.kind)).frame(width: 5)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: icon(for: item.kind)).foregroundStyle(color(for: item.kind))
                            Text(item.title).font(.headline)
                            Spacer()
                            Label(item.isProtected ? "Protected" : "Flexible", systemImage: item.isProtected ? "lock.fill" : "arrow.left.arrow.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(item.kind.label) · \(item.verification.rawValue.capitalized) · \(item.timeZoneIdentifier)").font(.subheadline).foregroundStyle(.secondary)
                        Label(isCanvasImport ? "Imported from Oxford Canvas" : isOutlookImport ? "Approved from Outlook email" : "Demonstration data", systemImage: isCanvasImport ? "arrow.down.doc" : "sparkles")
                            .font(.caption).foregroundStyle(isCanvasImport ? .blue : .secondary)
                        DisclosureGroup("Event details and source") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Source: \(providers.isEmpty ? "Unknown" : providers.joined(separator: ", "))")
                                Text("Start: \(item.startsAt.formatted(date: .complete, time: .shortened))")
                                Text("Time zone: \(item.timeZoneIdentifier)")
                                if let record = item.sourceRecordIDs.first.flatMap({ sourceID in model.sourceRecords.first(where: { $0.id == sourceID }) }),
                                   let uri = record.sourceURI, let url = URL(string: uri) {
                                    Link("Open source", destination: url).padding(.top, 3)
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                        }.font(.caption)
                    }
                }
                .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var planView: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            planContents(now: context.date)
        }
    }

    private func planContents(now: Date) -> some View {
        let assignments = model.assignments
        let eligible = assignments.filter { $0.group(status: model.assignmentStatus(for: $0.id), now: now) == .active }
        return VStack(alignment: .leading, spacing: 18) {
            heading(model.dataMode == .demo ? "Demonstration study plan" : "Study plan proposal", subtitle: "Track progress locally and plan unfinished work before its deadline")
            Text("Status is saved on this Mac. Completed and overdue assignments are excluded from new study plans.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = model.assignmentProgressError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if model.database == nil {
                Text("Local storage is unavailable. Status changes are disabled until it is available.").foregroundStyle(.orange)
            }
            ForEach(AssignmentPlanningGroup.allCases, id: \.self) { group in
                let grouped = assignments.filter { $0.group(status: model.assignmentStatus(for: $0.id), now: now) == group }
                if !grouped.isEmpty {
                    Text("\(group.label) (\(grouped.count))").font(.title3.bold())
                    ForEach(grouped) { assignment in assignmentCard(assignment, group: group) }
                }
            }
            if assignments.isEmpty {
                Text(model.dataMode == .demo ? "No demonstration assignments are available." : "No Canvas assignments are cached yet. Connect Oxford Canvas and use Sync to import them.").foregroundStyle(.secondary)
            } else if eligible.isEmpty {
                Text("No unfinished assignments with future deadlines to schedule.").foregroundStyle(.secondary)
            }
            Button("Generate proposal") { model.generatePlan(estimates: assignmentEffort, priorities: assignmentPriority) }
                .disabled(eligible.isEmpty)
            Text("Upcoming assignments are split into requirement review, focused work, and final review. Effort estimates are editable local inputs.")
                .font(.callout).foregroundStyle(.secondary)
            if let snapshot = model.planResult {
                if snapshot.isCurrent(at: now) {
                    let plan = snapshot.schedule
                    ForEach(plan.blocks) { block in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(block.title).font(.headline)
                            Text("\(block.startAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endAt.formatted(date: .omitted, time: .shortened)) · \(block.durationMinutes) min")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("Proposed · Source-backed by \(block.sourceRecordIDs.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(plan.unallocated) { item in
                        Label("\(item.title): \(item.minutes) minutes could not be scheduled before the deadline.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).padding(12).background(.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("This proposal is local and has not been written to a calendar. Fixed imported events and protected rest are avoided.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("A deadline has passed since this proposal was generated. Generate a new proposal for the remaining upcoming assignments.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func assignmentCard(_ assignment: PlanningAssignment, group: AssignmentPlanningGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(assignment.title).font(.headline)
            Text(assignment.dueAt.map { "Due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No deadline provided")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.sourceName(for: assignment.sourceRecordIDs.first ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Local status", selection: Binding(
                    get: { model.assignmentStatus(for: assignment.id) },
                    set: { model.setAssignmentStatus($0, for: assignment.id) }
                )) {
                    ForEach(AssignmentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).frame(maxWidth: 300, alignment: .leading)
                .disabled(model.database == nil)
                .accessibilityLabel("Status for \(assignment.title)")
                if group == .completed {
                    Button("Reopen") { model.setAssignmentStatus(.notStarted, for: assignment.id) }
                        .disabled(model.database == nil)
                }
            }
            if group == .overdue {
                Label("Overdue · excluded from study scheduling", systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            } else if group == .completed {
                Label("Completed · excluded from study scheduling", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else if group == .undated {
                Text("A deadline is needed before this assignment can be scheduled.").font(.caption).foregroundStyle(.secondary)
            }
            if assignment.submission?.suggestsCompletion == true, group != .completed {
                Text("Canvas records a submission. If all work is finished, you can mark this assignment completed locally.")
                    .font(.callout).foregroundStyle(.secondary)
                if let observed = assignment.retrievedAt {
                    Text("Checked at last import: \(observed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Mark completed locally") { model.setAssignmentStatus(.completed, for: assignment.id) }
                    .disabled(model.database == nil)
            }
            if group == .active {
                HStack {
                    Stepper("Effort: \(assignmentEffort[assignment.id, default: 180]) min", value: effortBinding(for: assignment.id), in: 30...1_440, step: 30)
                    Picker("Priority", selection: priorityBinding(for: assignment.id)) {
                        ForEach(1...5, id: \.self) { Text("Priority \($0)").tag($0) }
                    }.frame(width: 150)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 9))
    }

    private func effortBinding(for id: String) -> Binding<Int> {
        Binding(get: { assignmentEffort[id, default: 180] }, set: { assignmentEffort[id] = $0 })
    }

    private func priorityBinding(for id: String) -> Binding<Int> {
        Binding(get: { assignmentPriority[id, default: 3] }, set: { assignmentPriority[id] = $0 })
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Review inbox", subtitle: "Tentative items stay separate until you decide")
            if model.dataMode == .live { OutlookReviewView(model: outlook, changed: model.reloadImportedData) }
            if model.dataset.reviews.isEmpty && !model.dataset.conflicts.contains(where: { $0.state == .unresolved }) {
                Text("No items to review in this data mode.").foregroundStyle(.secondary)
            }
            ForEach(model.dataset.conflicts.filter { $0.state == .unresolved }) { conflict in
                VStack(alignment: .leading, spacing: 10) {
                    Label("Conflicting source values", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    Text(conflict.field).font(.subheadline)
                    ForEach(conflict.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ConflictValueFormatter.display(candidate.value)).font(.body)
                            Text("Source: \(model.sourceName(for: candidate.sourceRecordID))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Both values are preserved. No deadline was selected or changed.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(model.dataset.reviews) { review in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(review.title).font(.headline); Spacer(); Text("\(Int(review.confidence * 100))% confidence").font(.caption).foregroundStyle(.secondary) }
                    Text(review.evidence).font(.callout).foregroundStyle(.secondary)
                    Text("Evidence state: \(review.state.rawValue.capitalized) · Review: \(review.decision.rawValue.capitalized)").font(.caption)
                    HStack {
                        Button("Confirm") { model.resolve(review, as: .accepted) }
                        Button("Leave pending") { model.resolve(review, as: .pending) }
                        Button("Reject") { model.resolve(review, as: .rejected) }
                    }
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
        }
    }

    private var availabilityView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Availability", subtitle: "Defaults for planning proposals")
            Form {
                Picker("Study starts", selection: $model.availability.studyStartHour) { ForEach(6..<13) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("Study ends", selection: $model.availability.studyEndHour) { ForEach(14..<23) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("Protected rest starts", selection: $model.availability.protectedRestStartHour) { ForEach(20..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("Protected rest ends", selection: $model.availability.protectedRestEndHour) { ForEach(6..<11) { Text(String(format: "%02d:00", $0)).tag($0) } }
                LabeledContent("Time zone", value: model.availability.timeZoneIdentifier)
            }.frame(maxWidth: 500)
            Button("Save preferences") { model.saveAvailability() }
            Text("These settings are local defaults. Study proposals are not published to a calendar.").foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var connectionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Connections", subtitle: "Connect Oxford Canvas with a read-only API token")
            canvasConnectionView
            OutlookConnectionsView(model: outlook, isDemo: model.dataMode == .demo, changed: model.reloadImportedData)
            connection("Apple Calendar", detail: "Not connected · EventKit permission not requested", icon: "calendar")
            Spacer()
        }
    }

    private var canvasConnectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Oxford Canvas", systemImage: "graduationcap").font(.headline)
                Spacer()
                Label(canvasConnection.statusTitle, systemImage: canvasConnection.statusSymbol)
                    .font(.callout).foregroundStyle(canvasConnection.statusColor)
            }
            Text("Instance: canvas.ox.ac.uk · Access: read-only")
                .font(.callout).foregroundStyle(.secondary)
            if let lastSync = model.lastSuccessfulCanvasSync {
                Label("Last successful sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField("Canvas API token", text: $canvasConnection.tokenInput)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .autocorrectionDisabled()
            Text("Enter the token from your Passwords app here. It is stored in macOS Keychain, never in the app database. The app sends it only to Oxford Canvas over HTTPS when you test the connection or request a read-only sync.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = canvasConnection.message {
                Label(message, systemImage: canvasConnection.hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(canvasConnection.hasError ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(canvasConnection.isWorking ? "Testing…" : "Save token and test connection") {
                    Task { await canvasConnection.saveAndTest() }
                }
                .disabled(canvasConnection.isWorking || canvasConnection.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if canvasConnection.hasSavedToken {
                    Button("Test saved connection") { Task { await canvasConnection.testSaved() } }
                        .disabled(canvasConnection.isWorking)
                    Button("Remove token", role: .destructive) { canvasConnection.showRemoveConfirmation = true }
                        .disabled(canvasConnection.isWorking)
                }
            }
            if canvasConnection.isWorking { ProgressView().controlSize(.small) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .task { canvasConnection.refreshStatus() }
        .confirmationDialog("Remove the saved Oxford Canvas token from Keychain?", isPresented: $canvasConnection.showRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove token", role: .destructive) { canvasConnection.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the token from this app's Keychain entry. It does not revoke the token in Canvas.")
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }
    }
    private func connection(_ name: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) { Image(systemName: icon).font(.title2).frame(width: 32); VStack(alignment: .leading) { Text(name).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }; Spacer(); Text("Offline").font(.caption).padding(6).background(.quaternary, in: Capsule()) }
            .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
    private func icon(for section: String) -> String {
        switch section { case "Plan preview": "sparkles.rectangle.stack"; case "Review inbox": "tray.full"; case "Availability": "clock"; case "Connections": "link"; default: "calendar.day.timeline.left" }
    }
    private func color(for state: VerificationState) -> Color {
        switch state { case .verified: .green; case .inferred: .blue; case .disputed: .orange }
    }
    private func color(for kind: AcademicItemKind) -> Color {
        switch kind { case .classSession: .blue; case .tutorial: .purple; case .deadline: .orange; case .studyBlock: .teal }
    }
    private func icon(for kind: AcademicItemKind) -> String {
        switch kind { case .classSession: "book.closed.fill"; case .tutorial: "person.2.fill"; case .deadline: "exclamationmark.circle.fill"; case .studyBlock: "pencil.and.outline" }
    }
}

private enum CalendarMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@MainActor
@Observable
final class CanvasConnectionViewModel {
    var tokenInput = ""
    var isWorking = false
    var hasSavedToken = false
    var isConnected = false
    var hasError = false
    var message: String?
    var showRemoveConfirmation = false
    private let service = CanvasConnectionService()

    var statusTitle: String {
        if isWorking { "Checking" }
        else if isConnected { "Connected" }
        else if hasError { "Connection failed" }
        else if hasSavedToken { "Token saved" }
        else { "Not connected" }
    }
    var statusSymbol: String {
        if isWorking { "arrow.triangle.2.circlepath" }
        else if isConnected { "checkmark.circle.fill" }
        else if hasError { "exclamationmark.triangle.fill" }
        else { "circle" }
    }
    var statusColor: Color {
        if isConnected { .green }
        else if hasError { .orange }
        else { .secondary }
    }

    func refreshStatus() {
        do {
            hasSavedToken = try service.hasSavedToken()
            if !hasSavedToken { isConnected = false }
        } catch {
            hasError = true
            message = error.localizedDescription
        }
    }

    func saveAndTest() async {
        isWorking = true; hasError = false; isConnected = false; message = nil
        defer { isWorking = false }
        do {
            try await service.saveAndValidate(token: tokenInput)
            tokenInput = ""
            hasSavedToken = true
            isConnected = true
            message = "Oxford Canvas accepted the token. Only read-only API requests are enabled."
        } catch {
            tokenInput = ""
            refreshStatus()
            hasError = true
            message = error.localizedDescription
        }
    }

    func testSaved() async {
        isWorking = true; hasError = false; isConnected = false; message = nil
        defer { isWorking = false }
        do {
            try await service.validateSavedToken()
            hasSavedToken = true; isConnected = true
            message = "Oxford Canvas accepted the saved token. Only read-only API requests are enabled."
        } catch {
            refreshStatus(); hasError = true; message = error.localizedDescription
        }
    }

    func disconnect() {
        do {
            try service.disconnect()
            tokenInput = ""; hasSavedToken = false; isConnected = false; hasError = false
            message = "The token was removed from macOS Keychain."
        } catch {
            hasError = true; message = error.localizedDescription
        }
    }
}

private extension AcademicItemKind {
    var label: String {
        switch self { case .classSession: "Class"; case .tutorial: "Tutorial"; case .deadline: "Deadline"; case .studyBlock: "Study block" }
    }
}
