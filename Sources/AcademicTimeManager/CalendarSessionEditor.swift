import AcademicCore
import SwiftUI

/// Both pointer gestures and keyboard actions end here; editing never writes to Calendar.
struct CalendarSessionEditor: View {
    @Bindable var model: AppleCalendarViewModel
    @State var draft: CalendarSessionDraft
    @State private var preview: CalendarPreview?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.original == nil ? "Propose study session" : "Move or resize study session").font(.title2.bold())
            Text("Destination: Academic AI Time Manager calendar").font(.callout).foregroundStyle(.secondary)
            if let preview {
                Text("Review exact changes").font(.headline)
                HStack(alignment: .top, spacing: 16) {
                    if let original = draft.original {
                        VStack(alignment: .leading) {
                            rangeCard("Before", start: original.start, end: original.end, tint: .secondary)
                            Text(original.title).font(.callout)
                        }
                    }
                    rangeCard("Proposed", start: draft.start, end: draft.end, tint: .teal)
                }
                Text(draft.title).font(.headline)
                Text("No changes are saved until you approve. Conflicts and ownership are checked again at approval.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Preview expires \(preview.expiresAt.formatted(date: .omitted, time: .standard)).")
                    .font(.caption)
                Spacer()
                HStack {
                    Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                    Button("Back to editing") { self.preview = nil; model.invalidate() }
                    Spacer()
                    Button("Approve exact changes") { approve(preview) }
                        .disabled(preview.changes.isEmpty)
                }
                if preview.changes.isEmpty { Text("This session is already saved with these values.").font(.caption) }
            } else {
                Form {
                    TextField("Study title", text: $draft.title)
                    DatePicker("Start", selection: Binding(get: { draft.start }, set: { value in
                        let duration = draft.end.timeIntervalSince(draft.start)
                        draft.start = value; draft.end = value.addingTimeInterval(duration)
                    }), displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $draft.end, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("Display time zone", value: TimeZone.current.identifier)
                    LabeledContent("Session time zone", value: draft.timeZone)
                }
                HStack {
                    Button("15 minutes earlier") { shift(-900) }
                    Button("15 minutes later") { shift(900) }
                    Button("Shorten 15 minutes") { draft.end = draft.end.addingTimeInterval(-900) }
                    Button("Extend 15 minutes") { draft.end = draft.end.addingTimeInterval(900) }
                }.controlSize(.small)
                rangeCard("Proposed", start: draft.start, end: draft.end, tint: .teal)
                Text("Use the date and time fields to move to any day or change duration. Sessions must be in the future, within the next year, and no longer than 24 hours. Conflicts block approval, including hidden sources.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Review changes") { prepare() }.keyboardShortcut(.defaultAction)
                        .disabled(!model.ready || model.hasPending)
                }
                if !model.ready || model.hasPending {
                    Text("Set up the managed calendar or recover the pending write in Connections before reviewing changes.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(24).frame(width: 660, height: 540)
        .onChange(of: draft) { _, _ in error = nil }
        .onDisappear { model.invalidate() }
    }
    private func rangeCard(_ label: String, start: Date, end: Date, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: "calendar.badge.clock").font(.headline)
            Text(displayDate(start))
            Text("to \(displayDate(end))")
            Text("\(Int(end.timeIntervalSince(start) / 60)) minutes").font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint, style: StrokeStyle(dash: [4, 3])))
    }
    private func displayDate(_ date: Date) -> String {
        "\(date.formatted(date: .abbreviated, time: .shortened)) \(TimeZone.current.abbreviation(for: date) ?? TimeZone.current.identifier)"
    }
    private func shift(_ seconds: Double) {
        draft.start = draft.start.addingTimeInterval(seconds); draft.end = draft.end.addingTimeInterval(seconds)
    }
    private func prepare() {
        do { preview = try model.prepareSession(draft); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func approve(_ preview: CalendarPreview) {
        do { try model.approveSession(preview); dismiss() }
        catch { self.preview = nil; self.error = error.localizedDescription }
    }
    private func cancel() { model.invalidate(); dismiss() }
}
