import AcademicCore
import SwiftUI

/// Cancellation remains a read-only proposal until the user approves this exact preview.
struct CalendarSessionCancellationView: View {
    @Bindable var model: AppleCalendarViewModel
    let preview: CalendarPreview
    let close: () -> Void
    @State private var error: String?

    private var session: AppleCalendarEvent? { preview.changes.first?.before }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Review study session cancellation", systemImage: "calendar.badge.minus")
                .font(.title2.bold())
            Text("Only the session shown below will be removed after you approve. You can preview an undo from Timeline afterward.")
                .font(.callout)
            if let session {
                Divider()
                Text(session.title).font(.headline).textSelection(.enabled)
                LabeledContent("Starts", value: session.start.formatted(date: .complete, time: .shortened))
                LabeledContent("Ends", value: session.end.formatted(date: .complete, time: .shortened))
                LabeledContent("Time zone", value: session.timeZone)
                LabeledContent("Calendar", value: "Academic AI Time Manager (\(session.calendarID))")
                Text("Calendar account syncing is handled by macOS.").font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.orange).font(.callout)
                Text("The session was preserved. Refresh Calendar in Connections; if a write is pending, use Recover pending write, then review a new cancellation preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Keep session") { model.invalidate(); close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve cancellation", role: .destructive) {
                    do { try model.approveSession(preview); close() }
                    catch {
                        self.error = (error as? AppleCalendarError)?.localizedDescription
                            ?? "Calendar could not verify this cancellation."
                    }
                }.disabled(session == nil || preview.changes.count != 1 || preview.changes.first?.after != nil
                           || preview.expiresAt <= Date() || error != nil)
            }
        }.padding(24).frame(width: 520, height: 420)
    }
}
