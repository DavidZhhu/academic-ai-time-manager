import AcademicCore
import SwiftUI

/// Publishes the read-only Reminders snapshot. Reminder content lives only here, in memory.
@MainActor @Observable
final class RemindersViewModel {
    var snapshot = RemindersSnapshot.empty
    var state = RemindersSyncState.notSynced
    var report: RemindersSyncReport?
    var working = false
    var selectedListID: String?   // nil = all lists
    var selectedReminderID: String?
    private let service: RemindersSyncService

    init(client: (any RemindersClient)? = nil) {
        service = RemindersSyncService(client: client ?? EventKitRemindersClient())
        service.onUpdate = { [weak self] in self?.publish() }
    }

    private func publish() {
        snapshot = service.snapshot; state = service.state; report = service.lastReport
        if let id = selectedListID, snapshot.list(id) == nil { selectedListID = nil }
        if let id = selectedReminderID, !snapshot.items.contains(where: { $0.id == id }) { selectedReminderID = nil }
    }

    var access: RemindersAccess { service.access }
    var isConnected: Bool { service.access == .fullAccess }

    var statusText: String {
        switch state {
        case .notSynced:
            return access == .fullAccess ? "Connected. Waiting for the first read." : accessText
        case .notAuthorized(let access): return accessText(access)
        case .synced:
            let when = snapshot.syncedAt?.formatted(date: .omitted, time: .shortened) ?? ""
            return "Read-only · \(snapshot.items.count) reminders in \(snapshot.lists.count) lists · updated \(when)"
        case .failed(let message): return "\(message) Showing the last successful read\(snapshot.syncedAt.map { " (\($0.formatted(date: .omitted, time: .shortened)))" } ?? "")."
        }
    }
    private var accessText: String { accessText(access) }
    private func accessText(_ access: RemindersAccess) -> String {
        switch access {
        case .notDetermined: "Not connected. This app has not asked for Reminders access."
        case .fullAccess: "Connected."
        case .denied: "Reminders access was denied or revoked. Re-enable it in System Settings › Privacy & Security › Reminders. Stored reminder content has been cleared from this app."
        case .restricted: "Reminders access is restricted by this Mac's configuration."
        case .writeOnly: "Only write access to Reminders is granted, which this read-only feature cannot use. Choose Full Access in System Settings › Privacy & Security › Reminders."
        }
    }
    var isStale: Bool { if case .failed = state { return true } else { return false } }

    func requestPermission() async {
        working = true; defer { working = false }
        do { try await service.requestAccess() } catch { /* status reflects the denial below */ }
        await refresh()
    }
    func refresh() async {
        working = true; defer { working = false }
        await service.syncIfAuthorized()
        publish()
    }
    /// Reads on launch, then on EventKit change notifications and every five minutes. Never prompts.
    func startMonitoring() { service.startMonitoring(); publish() }
    func stopMonitoring() { service.stopMonitoring() }
    func select(_ id: String) {
        if let item = snapshot.items.first(where: { $0.id == id }) { selectedListID = item.listID; selectedReminderID = id }
    }
}

// MARK: - Connections

struct RemindersConnectionView: View {
    @Bindable var model: RemindersViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Reminders", systemImage: "checklist").font(.headline)
            Text("Read-only. Full Reminders access lets this app show your reminders, due dates and lists. Nothing is created, edited, completed or deleted, and reminder content stays on this Mac: it is held in memory, not saved, and never sent to a cloud AI service or any other server.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.statusText).textSelection(.enabled)
                .foregroundStyle(model.isStale || model.access == .denied || model.access == .writeOnly ? Color.orange : Color.primary)
            HStack {
                Button("Request Reminders access…") { Task { await model.requestPermission() } }
                    .disabled(model.working || model.access == .fullAccess)
                Button("Refresh now") { Task { await model.refresh() } }
                    .disabled(model.working || !model.isConnected)
                if model.working { ProgressView().controlSize(.small) }
            }
            if let report = model.report, report.removedItems + report.removedLists + report.duplicatesCollapsed > 0 {
                Text("Last read: \(report.removedItems) reminder(s) and \(report.removedLists) list(s) no longer exist, \(report.duplicatesCollapsed) duplicate(s) merged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Limits of Apple's public API: subtasks, sections, attachments, images, tags and location/early-alert details are not exposed, so they are not shown. Recurring reminders appear once, at their next due date.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Reminders page

struct RemindersPage: View {
    @Bindable var model: RemindersViewModel
    let isDemo: Bool
    var body: some View {
        Group {
            if isDemo {
                emptyState("Demo Mode shows no personal reminders.", detail: "Switch to Live data to see Apple Reminders.")
            } else if !model.isConnected {
                emptyState("Apple Reminders is not connected.", detail: model.statusText)
            } else {
                HSplitView {
                    listNavigation.frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
                    VStack(spacing: 0) {
                        if model.isStale { Label(model.statusText, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(10) }
                        reminderList
                        Divider()
                        detail.frame(minHeight: 150, idealHeight: 210, maxHeight: 280)
                    }.frame(minWidth: 320)
                }
            }
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Text("Connect it in Connections.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var listNavigation: some View {
        List(selection: $model.selectedListID) {
            Label("All reminders", systemImage: "tray.full")
                .badge(RemindersPresentation.openCount(model.snapshot.items)).tag(String?.none)
            Section("Lists") {
                ForEach(model.snapshot.lists) { list in
                    Label(list.title, systemImage: "list.bullet")
                        .badge(RemindersPresentation.openCount(model.snapshot.items, listID: list.id))
                        .tag(Optional(list.id))
                        .help("\(list.title) · \(list.sourceTitle)")
                        .accessibilityLabel("\(list.title), account \(list.sourceTitle)")
                }
            }
        }
    }

    private var reminderList: some View {
        let nodes = RemindersPresentation.tree(model.snapshot.items, listID: model.selectedListID)
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            List(selection: $model.selectedReminderID) {
                if nodes.isEmpty {
                    Text(model.snapshot.items.isEmpty ? "No reminders found." : "No reminders in this list.").foregroundStyle(.secondary)
                }
                OutlineGroup(nodes, children: \.optionalChildren) { node in
                    ReminderRow(item: node.item, now: context.date,
                                listTitle: model.selectedListID == nil ? model.snapshot.list(node.item.listID)?.title : nil)
                        .tag(Optional(node.item.id))
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selectedReminderID, let item = model.snapshot.items.first(where: { $0.id == id }) {
            ReminderDetail(item: item, list: model.snapshot.list(item.listID))
        } else {
            Text("Select a reminder to see its details.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ReminderNode {
    var optionalChildren: [ReminderNode]? { children.isEmpty ? nil : children }
}

/// Completion is an indicator only; this view has no control that changes a reminder.
struct ReminderRow: View {
    let item: ReminderItem
    let now: Date
    var listTitle: String?
    var body: some View {
        let overdue = RemindersPresentation.isOverdue(item, now: now)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isCompleted ? Color.green : overdue ? .orange : .secondary)
                .accessibilityLabel(item.isCompleted ? "Completed" : "Not completed")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).strikethrough(item.isCompleted).foregroundStyle(item.isCompleted ? .secondary : .primary)
                HStack(spacing: 6) {
                    if item.due != nil { Text(RemindersPresentation.dueDescription(item, now: now)).foregroundStyle(overdue ? .orange : .secondary) }
                    if item.priority != .none { Label(item.priority.label, systemImage: "exclamationmark").labelStyle(.titleAndIcon) }
                    if item.isRecurring { Label("Repeats", systemImage: "repeat").labelStyle(.titleAndIcon) }
                    if let listTitle { Text(listTitle) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ReminderDetail: View {
    let item: ReminderItem
    let list: ReminderListInfo?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isCompleted ? Color.green : .secondary)
                    Text(item.displayTitle).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                Text(item.isCompleted ? "Completed\(item.completedAt.map { " " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")" : "Not completed")
                    .font(.callout).foregroundStyle(.secondary)
                row("Due", item.due.map { $0.hasTime ? $0.date.formatted(date: .complete, time: .shortened) : $0.date.formatted(date: .complete, time: .omitted) } ?? "No due date")
                if let zone = item.due?.timeZoneIdentifier { row("Time zone", zone) }
                if item.priority != .none { row("Priority", item.priority.label) }
                if let list { row("List", "\(list.title) · \(list.sourceTitle)") }
                if item.isRecurring { row("Repeats", (item.recurrenceSummary ?? "Recurring") + " — only the next due date is shown") }
                if let notes = item.notes { Text(notes).font(.callout).textSelection(.enabled).padding(.top, 4) }
                if let url = item.url { Link(url.absoluteString, destination: url).font(.callout).lineLimit(2) }
                Text("Read-only · edit this reminder in the Reminders app")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

// MARK: - Academic tasks panel section

struct ReminderTaskSection: View {
    @Bindable var model: RemindersViewModel
    let isDemo: Bool
    var open: (String) -> Void
    @State private var expanded = true
    var body: some View {
        if !isDemo && model.isConnected {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let groups = RemindersPresentation.upcoming(model.snapshot.items, now: context.date)
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.isStale { Label("Out of date", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
                        if groups.overdue.isEmpty && groups.upcoming.isEmpty {
                            Text("No upcoming reminders in the next \(RemindersPresentation.upcomingHorizonDays) days.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(groups.overdue + groups.upcoming) { item in
                            Button { open(item.id) } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "circle").foregroundStyle(.teal)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.displayTitle).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                                        Text(RemindersPresentation.dueDescription(item, now: context.date)).font(.caption)
                                            .foregroundStyle(RemindersPresentation.isOverdue(item, now: context.date) ? Color.orange : .secondary)
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityHint("Open in Reminders")
                        }
                    }.padding(.top, 6)
                } label: {
                    HStack {
                        Label("Reminders", systemImage: "checklist").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(groups.overdue.count + groups.upcoming.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Calendar markers

/// Due-date marker: a hollow circle and teal text, visually distinct from busy event blocks and
/// from Canvas deadline flags. It has no duration and occupies no time slot.
struct ReminderMarkerChip: View {
    let marker: ReminderDueMarker
    var open: (String) -> Void
    var body: some View {
        Button { open(marker.reminderID) } label: {
            HStack(spacing: 3) {
                Image(systemName: marker.isCompleted ? "checkmark.circle.fill" : "circle")
                Text(marker.hasTime ? "\(marker.date.formatted(date: .omitted, time: .shortened)) \(marker.title)" : marker.title)
                    .lineLimit(1).strikethrough(marker.isCompleted)
            }
            .font(.caption2).foregroundStyle(marker.isCompleted ? Color.secondary : Color.teal)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.teal.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1, 2])))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("Reminder due: \(marker.title) · \(marker.listTitle). Not busy time.")
            .accessibilityLabel("Reminder due, \(marker.title), \(marker.hasTime ? marker.date.formatted(date: .abbreviated, time: .shortened) : "all day"), \(marker.isCompleted ? "completed" : "not completed"), not busy time")
    }
}
