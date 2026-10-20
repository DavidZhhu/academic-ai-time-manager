import AcademicCore
import SwiftUI

/// The resize handle is a sibling of the move target so its drag cannot become a move.
struct CalendarStudyInteraction: View {
    let event: UnifiedTimelineEvent
    let compact: Bool
    let selected: Bool
    let day: Date
    let dayWidth: CGFloat
    let hourHeight: CGFloat
    let makeDraft: (UnifiedTimelineEvent) -> CalendarSessionDraft?
    let select: () -> Void
    let preview: (CalendarSessionDraft?) -> Void
    let propose: (CalendarSessionDraft) -> Void
    @State private var initial: CalendarSessionDraft?
    @GestureState private var dragging = false

    var body: some View {
        CalendarEventBlock(event: event, compact: compact, selected: selected, select: select)
            .highPriorityGesture(gesture(resizing: false))
            .overlay(alignment: .bottom) {
                // Only the occurrence's actual end can be resized on an overnight session.
                if event.end <= CalendarPresentation.dayInterval(day).end {
                    Capsule().fill(.green).frame(width: 28, height: 4)
                        .frame(maxWidth: .infinity).frame(height: 10).contentShape(Rectangle())
                        .gesture(gesture(resizing: true))
                        .help("Drag to resize; or open Move or resize session from the context menu.")
                        .accessibilityHidden(true)
                }
            }
            .contextMenu {
                Button("Move or resize session…") { if let draft = makeDraft(event) { propose(draft) } }
            }
            .accessibilityAction(named: "Move or resize session") { if let draft = makeDraft(event) { propose(draft) } }
            .onChange(of: dragging) { _, active in
                if !active { initial = nil; preview(nil) }
            }
    }
    private func gesture(resizing: Bool) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if initial == nil { initial = makeDraft(event) }
                if let initial { preview(transformed(initial, value.translation, resizing: resizing)) }
            }
            .onEnded { value in
                // GestureState can reset before this callback; the original owned snapshot is safe to resolve again.
                if let base = initial ?? makeDraft(event) { propose(transformed(base, value.translation, resizing: resizing)) }
                initial = nil; preview(nil)
            }
    }
    private func transformed(_ draft: CalendarSessionDraft, _ translation: CGSize, resizing: Bool) -> CalendarSessionDraft {
        let minutes = Double(translation.height / hourHeight * 60)
        if resizing { return CalendarInteraction.resize(draft, byMinutes: minutes) }
        let offset = Int((translation.width / max(1, dayWidth)).rounded())
        let targetDay = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day
        return CalendarInteraction.move(draft, to: targetDay,
            minute: CalendarPresentation.minuteOffset(draft.start, on: day) + minutes)
    }
}
