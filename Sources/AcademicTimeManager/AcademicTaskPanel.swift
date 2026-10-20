import AcademicCore
import SwiftUI

struct AcademicTaskPanel: View {
    @Bindable var model: PlannerViewModel
    let effort: [String: Int]
    let priority: [String: Int]
    var openReminder: (String) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Academic tasks", systemImage: "checklist").font(.headline)
                Spacer()
                Text("\(model.assignments.filter { model.assignmentStatus(for: $0.id) != .completed }.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ReminderTaskSection(model: model.reminders, isDemo: model.dataMode == .demo, open: openReminder)
                        if let error = model.assignmentProgressError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        if model.assignments.isEmpty {
                            Text(model.dataMode == .demo ? "No sample assignments." : "No cached assignments. Use Canvas sync to import academic deadlines.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(AssignmentPlanningGroup.allCases, id: \.self) { group in
                            let assignments = model.assignments.filter { $0.group(status: model.assignmentStatus(for: $0.id), now: context.date) == group }
                            if !assignments.isEmpty {
                                Text(group.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(assignments) { assignment in taskRow(assignment, group: group) }
                            }
                        }
                    }.padding(16)
                }
            }
            Divider()
            Text("Local progress · estimates editable in Plan preview · reminders are read-only")
                .font(.caption2).foregroundStyle(.secondary).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private func taskRow(_ assignment: PlanningAssignment, group: AssignmentPlanningGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: group == .completed ? "checkmark.circle.fill" : "flag")
                    .foregroundStyle(group == .completed ? Color.green : group == .overdue ? .orange : .secondary)
                Text(assignment.title).font(.callout.weight(.medium))
                    .strikethrough(group == .completed)
            }
            Text(assignment.dueAt.map { "Due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No deadline")
                .font(.caption).foregroundStyle(group == .overdue ? .orange : .secondary)
            Text(assignment.sourceRecordIDs.map { model.sourceName(for: $0) }.joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let value = priority[assignment.id] { Label("Priority \(value)", systemImage: "flag.fill") }
                if let value = effort[assignment.id] { Label("\(value) min", systemImage: "clock") }
            }.font(.caption2).foregroundStyle(.secondary)
            Picker("Status", selection: Binding(get: { model.assignmentStatus(for: assignment.id) }, set: { model.setAssignmentStatus($0, for: assignment.id) })) {
                ForEach(AssignmentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.menu).disabled(model.database == nil)
                .accessibilityLabel("Local status for \(assignment.title)")
            Divider()
        }
    }
}
