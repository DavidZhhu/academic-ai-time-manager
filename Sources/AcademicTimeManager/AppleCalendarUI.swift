import AcademicCore
import Foundation
import SwiftUI

@MainActor @Observable
final class AppleCalendarViewModel {
    var status = "Not connected. Calendar access has not been requested by this app."
    var sources: [AppleCalendarSource] = []
    var selectedSource = ""
    var ready = false
    var working = false
    var preview: CalendarPreview?
    var owned: [(key: String, event: AppleCalendarEvent)] = []
    var hasPending = false
    var canUndo = false
    /// Transient, redacted values for the Timeline. This is never saved to SQLite or the journal.
    var timelineEvents: [AppleCalendarTimelineEvent] = []
    private var service: AppleCalendarService?
    private var timelineInterval: DateInterval?
    private var changeObservation: (any AppleCalendarChangeObservation)?

    private func connection() throws -> AppleCalendarService {
        if let service { return service }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AcademicTimeManager", isDirectory: true)
        let value = try AppleCalendarService(client: EventKitCalendarClient(),
            storage: FileCalendarJournalStore(url: root.appendingPathComponent("apple-calendar-ownership.json")))
        service = value; return value
    }
    func invalidate() { preview = nil; service?.invalidatePreview() }
    func requestPermission() async {
        working = true; defer { working = false }
        do { try await connection().requestAccess(); refresh() }
        catch { failed(error) }
    }
    func refresh() {
        invalidate()
        do {
            let service = try connection()
            sources = try service.sources()
            if !sources.contains(where: { $0.id == selectedSource }) { selectedSource = sources.first?.id ?? "" }
            ready = service.calendarID != nil; reloadOwned(service)
            status = ready ? "Full access granted. The managed calendar is configured. Changes require a preview and your approval." : "Full access granted. Choose an account and create the dedicated calendar."
            refreshTimeline(in: defaultTimelineInterval())
        } catch { failed(error) }
    }
    func createCalendar() {
        do { try connection().createCalendar(sourceID: selectedSource, approved: true); refresh() }
        catch { failed(error) }
    }
    func refreshTimeline(in interval: DateInterval) {
        guard let service else { return }
        do {
            timelineEvents = try service.timelineEvents(in: interval)
            timelineInterval = interval
            if changeObservation == nil {
                changeObservation = try service.observeChanges { [weak self] in
                    self?.refreshObservedTimeline()
                }
            }
        } catch {
            timelineEvents = []
            if service.access != .fullAccess { failed(error) }
        }
    }
    func makePlan(dataset: AcademicDataset, progress: [String: AssignmentProgress], availability: AvailabilitySettings,
                  estimates: [String: Int], priorities: [String: Int], now: Date) throws -> AssignmentStudyPlan {
        do {
            return try CalendarAwarePlanning.makePlan(dataset: dataset, progress: progress, availability: availability,
                estimates: estimates, priorities: priorities, now: now, calendar: ready ? connection() : nil)
        } catch { failed(error); throw error }
    }
    func prepare(_ plan: AssignmentStudyPlan, timeZone: String, mode: StudyDataMode) {
        invalidate()
        do {
            guard plan.isCurrent(at: Date()) else { throw AppleCalendarError.invalidPlan }
            preview = try connection().preview(blocks: plan.schedule.blocks, timeZone: timeZone, mode: mode,
                expiresAt: plan.expiresAt ?? Date().addingTimeInterval(300))
        } catch { failed(error) }
    }
    func cancel(key: String) {
        invalidate()
        do { preview = try connection().preview(blocks: [], timeZone: TimeZone.current.identifier, mode: .live,
            expiresAt: Date().addingTimeInterval(300), cancelKeys: [key]) }
        catch { failed(error) }
    }
    func approve() {
        guard let preview else { return }
        self.preview = nil
        do {
            let service = try connection(); try service.approve(preview); reloadOwned(service)
            status = "Approved changes saved to the local Calendar store. Account syncing is handled by macOS; remote delivery is not confirmed."
            if let timelineInterval { refreshTimeline(in: timelineInterval) }
        } catch { failed(error) }
    }
    func undo() {
        invalidate()
        do { preview = try connection().previewUndo() }
        catch { failed(error) }
    }
    func recover() {
        do {
            let service = try connection(); try service.recoverPendingWrite(); reloadOwned(service)
            status = "Pending write reconciled. Generate and review a fresh proposal before publishing again."
            if let timelineInterval { refreshTimeline(in: timelineInterval) }
        }
        catch { failed(error) }
    }
    private func refreshObservedTimeline() {
        guard let timelineInterval else { return }
        refreshTimeline(in: timelineInterval)
    }
    private func defaultTimelineInterval() -> DateInterval {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 365, to: start) ?? start.addingTimeInterval(365 * 86400)
        return DateInterval(start: start, end: end)
    }
    private func reloadOwned(_ service: AppleCalendarService) {
        owned = service.managedKeys().compactMap { key in service.event(for: key).map { (key, $0) } }
        hasPending = service.hasPendingWrite; canUndo = service.canUndo
    }
    private func failed(_ error: Error) {
        invalidate(); status = ((error as? AppleCalendarError)?.localizedDescription ?? AppleCalendarError.unavailable.localizedDescription)
            + " Earlier confirmed changes, if any, remain saved; inspect Published study sessions before continuing."
        if let service {
            reloadOwned(service)
            if service.access != .fullAccess {
                ready = false; sources = []; timelineEvents = []; timelineInterval = nil
                changeObservation?.cancel(); changeObservation = nil
            }
        }
    }
}

struct AppleCalendarConnectionView: View {
    @Bindable var model: AppleCalendarViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Calendar", systemImage: "calendar").font(.headline)
            Text("Full Calendar access lets this app read busy times across your calendars and show protected Calendar events in Timeline. Event titles are displayed only locally; notes, attendees, locations and URLs are not retained. Only approved study sessions are saved in Academic AI Time Manager.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.status).textSelection(.enabled)
            if !model.timelineEvents.isEmpty {
                Text("Timeline is showing \(model.timelineEvents.count) protected Apple Calendar event\(model.timelineEvents.count == 1 ? "" : "s") for the selected range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Request Calendar access…") { Task { await model.requestPermission() } }.disabled(model.working)
                Button("Refresh connection") { model.refresh() }.disabled(model.working)
            }
            if !model.ready && !model.sources.isEmpty {
                Picker("Calendar account", selection: $model.selectedSource) {
                    ForEach(model.sources) { source in Text(source.title).tag(source.id) }
                }
                Button("Approve creation of Academic AI Time Manager calendar") { model.createCalendar() }
                    .disabled(model.selectedSource.isEmpty)
                Text("This creates a new empty calendar in the selected account. A same-name existing calendar is never adopted automatically.").font(.caption)
            }
            if model.hasPending { Button("Recover pending write (read only)") { model.recover() } }
            if model.canUndo { Button("Preview undo of last event change") { model.undo() } }
            if !model.owned.isEmpty {
                Text("Published study sessions").font(.headline)
                Text("Canceling a session requires a preview and approval. Unlisted personal events cannot be changed here.").font(.caption)
                ForEach(model.owned, id: \.key) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.event.title)
                            Text(entry.event.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                        Spacer()
                        Button("Preview cancellation") { model.cancel(key: entry.key) }.disabled(model.hasPending)
                    }
                }
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AppleCalendarPreviewView: View {
    @Bindable var model: AppleCalendarViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Apple Calendar changes").font(.title2.bold())
            Text("Destination: Academic AI Time Manager. Only the changes below will be applied. Sessions omitted from a new plan are kept until you explicitly cancel them in Connections.")
            if let preview = model.preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(preview.changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.label).font(.headline)
                                if let before = change.before { details(before, prefix: "Before") }
                                if let after = change.after { details(after, prefix: "After") }
                            }
                        }
                        if preview.changes.isEmpty { Text("No changes needed. These sessions are already published.") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Dismiss") { model.invalidate() }
                    Spacer()
                    Button("Approve exact changes") { model.approve() }
                        .disabled(preview.changes.isEmpty || preview.expiresAt <= Date())
                }
            }
        }.padding(24).frame(width: 640, height: 480)
    }
    private func details(_ event: AppleCalendarEvent, prefix: String) -> some View {
        Text("\(prefix): \(event.title)\n\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .abbreviated, time: .shortened))\nTime zone: \(event.timeZone) (times displayed in \(TimeZone.current.identifier))")
            .font(.callout).textSelection(.enabled)
    }
}
