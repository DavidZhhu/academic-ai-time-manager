import XCTest
@testable import AcademicCore

final class AcademicDatasetTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!
    private let availability = AvailabilitySettings(timeZoneIdentifier: "Europe/London")

    private var sources: [SourceRecord] {
        [SourceRecord(id: "canvas-real", provider: "Canvas", externalID: "real", retrievedAt: now),
         SourceRecord(id: "source-canvas-demo", provider: "Canvas (sample)", externalID: "demo", retrievedAt: now)]
    }

    private func item(_ id: String, source: String, start: Date, end: Date? = nil) -> AcademicItem {
        AcademicItem(id: id, title: id, startsAt: start, endsAt: end ?? start,
            timeZoneIdentifier: "Europe/London", kind: end == nil ? .deadline : .classSession,
            verification: .verified, sourceRecordIDs: [source], isProtected: true)
    }

    private var deadlines: [AcademicItem] {
        [item("live-assignment", source: sources[0].id, start: now.addingTimeInterval(8 * 3600)),
         item("demo-assignment", source: sources[1].id, start: now.addingTimeInterval(8 * 3600))]
    }

    func testDefaultIsLiveEvenWithoutCachedCanvasDataAndNeverFallsBackToSamples() {
        let data = AcademicDataset(items: deadlines, sources: sources)
        XCTAssertEqual(data.mode, .live)
        XCTAssertEqual(data.items.map(\.id), ["live-assignment"])
        XCTAssertEqual(data.assignments.map(\.id), ["live-assignment"])
        let empty = AcademicDataset(items: [deadlines[1]], sources: [sources[1]])
        XCTAssertEqual(empty.mode, .live)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(empty.assignments.isEmpty)
        XCTAssertTrue(empty.makePlan(progress: [:], availability: availability, now: now).schedule.blocks.isEmpty)
    }

    func testDemoCommitmentsCannotBlockLiveStudyButRealCommitmentsStillDo() {
        let sampleBusy = item("sample-all-day", source: sources[1].id, start: now, end: now.addingTimeInterval(8 * 3600))
        let realBusy = item("real-first-hour", source: sources[0].id, start: now, end: now.addingTimeInterval(3600))
        let data = AcademicDataset(items: deadlines + [sampleBusy, realBusy], sources: sources)
        let plan = data.makePlan(progress: [:], availability: availability, now: now).schedule
        XCTAssertFalse(plan.blocks.isEmpty)
        XCTAssertTrue(plan.unallocated.isEmpty)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.sourceRecordIDs == [sources[0].id] })
        XCTAssertEqual(plan.blocks.first?.startAt, realBusy.endsAt)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.startAt >= realBusy.endsAt && $0.endAt <= deadlines[0].startsAt })
    }

    func testDemoModeUsesOnlySamplesForAssignmentsEventsReviewsAndConflicts() {
        let realBusy = item("real-all-day", source: sources[0].id, start: now, end: now.addingTimeInterval(8 * 3600))
        let demoBusy = item("demo-first-hour", source: sources[1].id, start: now, end: now.addingTimeInterval(3600))
        let reviews = sources.map {
            ReviewItem(id: $0.id, title: "Review", evidence: "Fixture", confidence: 0.5,
                state: .disputed, sourceRecordID: $0.id)
        }
        let conflicts = sources.map {
            AcademicConflict(id: $0.id, field: "due", candidates: [
                ConflictCandidate(id: "one", value: "one", sourceRecordID: $0.id, observedAt: now),
                ConflictCandidate(id: "two", value: "two", sourceRecordID: $0.id, observedAt: now)])
        }
        let data = AcademicDataset(mode: .demo, items: deadlines + [realBusy, demoBusy], sources: sources,
            reviews: reviews, conflicts: conflicts)
        XCTAssertEqual(data.assignments.map(\.id), ["demo-assignment"])
        XCTAssertEqual(Set(data.items.map(\.id)), ["demo-assignment", "demo-first-hour"])
        XCTAssertEqual(data.reviews.map(\.id), [sources[1].id])
        XCTAssertEqual(data.conflicts.map(\.id), [sources[1].id])
        let plan = data.makePlan(progress: [:], availability: availability, now: now).schedule
        XCTAssertFalse(plan.blocks.isEmpty)
        XCTAssertTrue(plan.unallocated.isEmpty)
        XCTAssertEqual(plan.blocks.first?.startAt, demoBusy.endsAt)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.sourceRecordIDs == [sources[1].id] })
        let live = AcademicDataset(items: deadlines, sources: sources, reviews: reviews, conflicts: conflicts)
        XCTAssertEqual(live.reviews.map(\.id), [sources[0].id])
        XCTAssertEqual(live.conflicts.map(\.id), [sources[0].id])
    }

    func testLegacyProvenanceAndUnknownOrMixedSourcesAreHandledConservatively() throws {
        let old = try JSONDecoder().decode(SourceRecord.self, from: Data(#"{"id":"old-sample","provider":"Canvas (sample)","externalID":"x","retrievedAt":0}"#.utf8))
        XCTAssertEqual(old.studyDataMode, .demo)
        let knownDemoID = SourceRecord(id: "source-outlook-demo", provider: "Canvas", externalID: "x", retrievedAt: now)
        XCTAssertEqual(knownDemoID.studyDataMode, .demo)
        let unknown = SourceRecord(id: "unknown", provider: "Unknown", externalID: "x", retrievedAt: now)
        XCTAssertNil(unknown.studyDataMode)
        var mixed = deadlines[0]; mixed.sourceRecordIDs = sources.map(\.id)
        var missing = deadlines[0]; missing.sourceRecordIDs = ["missing"]
        var noSource = deadlines[0]; noSource.sourceRecordIDs = []
        let unknownItem = item("unknown", source: unknown.id, start: now)
        for mode in StudyDataMode.allCases {
            let data = AcademicDataset(mode: mode, items: [mixed, missing, noSource, unknownItem], sources: sources + [unknown])
            XCTAssertTrue(data.items.isEmpty)
            XCTAssertTrue(data.assignments.isEmpty)
        }
        // Names are content, not origin: a real assignment may legitimately contain “demo”.
        var namedDemo = deadlines[0]; namedDemo.title = "Demo preparation"
        XCTAssertEqual(AcademicDataset(items: [namedDemo], sources: sources).items, [namedDemo])
    }

    func testUndatedSourceMetadataAlsoRespectsSelectedMode() {
        let metadata = sources.map {
            SourceRecord(id: $0.id, provider: $0.provider, externalID: $0.externalID, retrievedAt: now,
                displayTitle: "Undated assignment", assignmentDetails: ImportedAssignmentDetails(dueAt: nil))
        }
        for (mode, expectedID) in [(StudyDataMode.live, sources[0].id), (.demo, sources[1].id)] {
            let data = AcademicDataset(mode: mode, items: [], sources: metadata)
            XCTAssertEqual(data.assignments.map(\.id), [expectedID])
            XCTAssertNil(data.assignments.first?.dueAt)
        }
    }

    func testModeSelectionAndRepeatedImportPreserveStoredDataAndCompletionAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dataset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let completed = AssignmentProgress(assignmentID: deadlines[0].id, status: .completed, updatedAt: now)
        let demoProgress = AssignmentProgress(assignmentID: deadlines[1].id, status: .inProgress, updatedAt: now)
        do {
            let db = try LocalDatabase(path: path)
            for source in sources { try db.save(source) }
            for deadline in deadlines { try db.save(deadline) }
            try db.save(completed); try db.save(demoProgress)
            for mode in [StudyDataMode.live, .demo, .live] {
                let data = AcademicDataset(mode: mode, items: try db.items(), sources: try db.sourceRecords())
                let plan = data.makePlan(progress: try db.assignmentProgress(), availability: availability, now: now)
                XCTAssertEqual(plan.schedule.blocks.isEmpty, mode == .live)
            }
            try db.importCanvas(CanvasImportResult(sourceRecords: [sources[0]], academicItems: [deadlines[0]]), successfulAt: now)
        }
        let db = try LocalDatabase(path: path)
        XCTAssertEqual(Set(try db.items().map(\.id)), Set(deadlines.map(\.id)))
        XCTAssertEqual(Set(try db.sourceRecords().map(\.id)), Set(sources.map(\.id)))
        XCTAssertEqual(try db.assignmentProgress()[completed.assignmentID], completed)
        XCTAssertEqual(try db.assignmentProgress()[demoProgress.assignmentID], demoProgress)
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), now)
        XCTAssertEqual(AcademicDataset(items: try db.items(), sources: try db.sourceRecords()).mode, .live)
    }
}
