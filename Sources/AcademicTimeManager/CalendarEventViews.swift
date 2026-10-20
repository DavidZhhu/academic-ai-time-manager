import AcademicCore
import SwiftUI

struct CalendarEventBlock: View {
    let event: UnifiedTimelineEvent
    var compact = false
    var selected = false
    let select: () -> Void
    private var tint: Color { event.source.calendarColor }
    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: event.kind == .deadline ? 4 : 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 3) {
                        if event.kind == .deadline { Image(systemName: "flag.fill") }
                        Text(event.title).fontWeight(.semibold).lineLimit(compact ? 1 : 2)
                    }
                    if !compact {
                        Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                        Text(event.source.label).lineLimit(1)
                        Label(event.verification.rawValue.capitalized,
                              systemImage: event.isProtected ? "lock.fill" : "sparkles").lineLimit(1)
                    }
                }.font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(compact ? 3 : 5)
            .foregroundStyle(.primary)
            .background(tint.opacity(event.kind == .deadline ? 0.22 : 0.13), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? tint : tint.opacity(0.35),
                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: event.kind == .deadline ? [3, 2] : [])))
            .clipped()
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(description)
            .accessibilityLabel(description)
            .accessibilityHint("Inspect event details")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var description: String {
        "\(event.title), \(event.kind == .deadline ? "deadline, " : "")\(event.source.label), \(event.isAllDay ? "all day" : event.start.formatted(date: .abbreviated, time: .shortened)), \(event.verification.rawValue), \(event.isProtected ? "protected" : "flexible")"
    }
}

struct CalendarEventInspector: View {
    let event: UnifiedTimelineEvent
    let sources: [SourceRecord]
    var edit: (() -> Void)? = nil
    var cancel: (() throws -> Void)? = nil
    @State private var cancellationError: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(event.kind == .deadline ? "Deadline" : "Event details", systemImage: event.kind == .deadline ? "flag.fill" : "calendar")
                        .foregroundStyle(event.source.calendarColor)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                Text(event.title).font(.title2.bold()).textSelection(.enabled)
                Label(event.source.label, systemImage: event.source.calendarSymbol)
                    .foregroundStyle(event.source.calendarColor)
                Divider()
                LabeledContent("Start", value: event.start.formatted(date: .complete, time: event.isAllDay ? .omitted : .shortened))
                if event.end > event.start {
                    LabeledContent(event.isAllDay ? "Ends (exclusive)" : "End", value: event.end.formatted(date: .complete, time: event.isAllDay ? .omitted : .shortened))
                }
                if event.isAllDay { Text("All-day event").font(.callout) }
                LabeledContent("Source time zone", value: event.timeZone)
                LabeledContent("Display time zone", value: TimeZone.current.identifier)
                LabeledContent("Verification", value: event.verification.rawValue.capitalized)
                Label(event.isProtected ? "Protected commitment" : "Flexible study time", systemImage: event.isProtected ? "lock.fill" : "arrow.left.arrow.right")
                if event.source == .appleCalendar {
                    Text("The original title is shown only on this Mac. Notes, locations, attendees and URLs are not retained.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sources.filter { event.sourceRecordIDs.contains($0.id) }) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source: \(source.provider)").font(.caption)
                        if let uri = source.sourceURI, let url = URL(string: uri), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link("Open original source", destination: url)
                        }
                    }
                }
                if let edit {
                    Button("Move or resize session…", action: edit)
                        .help("Edit start/end using the keyboard, then preview and approve.")
                    if let cancel {
                        Button("Cancel study session…", role: .destructive) {
                            do { try cancel() }
                            catch {
                                cancellationError = (error as? AppleCalendarError)?.localizedDescription
                                    ?? "Calendar could not verify this session. Refresh Calendar in Connections and inspect the event before retrying."
                            }
                        }.help("Review the exact session before approving its cancellation.")
                    }
                } else {
                    Label("Protected and read-only", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    if event.source == .appleCalendar {
                        Text("This Calendar event cannot be cancelled here. If it was previously a study session, refresh Calendar in Connections and inspect any external changes before retrying. Your event remains unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let cancellationError {
                    Text(cancellationError).font(.callout).foregroundStyle(.orange)
                    Text("Open Connections to refresh Calendar or recover a pending write. Resolve external changes in Apple Calendar before making a fresh proposal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
        }.frame(width: 480, height: 540)
    }
}
