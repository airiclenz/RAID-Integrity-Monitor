import XCTest
@testable import IntegrityMonitor
import Foundation
import SQLite3

final class SQLiteManifestStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: SQLiteManifestStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.db")
        store = SQLiteManifestStore(path: dbURL)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Schema

    func testOpen_createsTablesSuccessfully() throws {
        // If open() didn't throw we have the schema — verify via a round-trip
        let paths = try store.allPaths()
        XCTAssertTrue(paths.isEmpty)
    }

    func testOpen_freshDatabaseSeedsCurrentSchemaVersion() throws {
        // Arrange: a fresh on-disk store that must open without running migrations
        let dbURL = tempDir.appendingPathComponent("fresh.db")
        let freshStore = SQLiteManifestStore(path: dbURL)
        try freshStore.open()

        // Act: round-trip a scan whose files_inaccessible column only exists at schema v3
        var scan = ScanResult(startedAt: Date())
        scan.id = try freshStore.insertScan(scan)
        scan.filesInaccessible = 7
        scan.status = .completed
        scan.completedAt = Date()
        try freshStore.updateScan(scan)
        let lastScan = try freshStore.lastScan()

        freshStore.close()
        let reopenedStore = SQLiteManifestStore(path: dbURL)
        try reopenedStore.open()
        reopenedStore.close()

        // Assert
        XCTAssertEqual(lastScan?.filesInaccessible, 7)
        XCTAssertEqual(try readSchemaVersionRows(at: dbURL), [3])
    }

    /// Reads every row of schema_version with the raw sqlite3 API so the
    /// assertion does not depend on the store's own migration logic.
    private func readSchemaVersionRows(at dbURL: URL) throws -> [Int] {
        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle else {
            throw AppError.database("Cannot open \(dbURL.path) for schema_version read")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT version FROM schema_version", -1, &statement, nil) == SQLITE_OK else {
            throw AppError.database("Cannot prepare schema_version read")
        }
        defer { sqlite3_finalize(statement) }

        var versions: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            versions.append(Int(sqlite3_column_int(statement, 0)))
        }
        return versions
    }

    // MARK: - Upsert and fetch

    func testUpsert_insertAndRetrieve() throws {
        let now = Date()
        let record = FileRecord(
            path: "/RAID/Photos/img001.jpg",
            size: 4_096_000,
            mtime: now,
            hash: "abc123def456",
            hashAlgorithm: "sha256",
            firstSeen: now,
            lastVerified: now,
            status: .ok
        )
        try store.upsert(record)

        let fetched = try store.record(for: "/RAID/Photos/img001.jpg")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.path, record.path)
        XCTAssertEqual(fetched?.size, record.size)
        XCTAssertEqual(fetched?.hash, record.hash)
        XCTAssertEqual(fetched?.hashAlgorithm, record.hashAlgorithm)
        XCTAssertEqual(fetched?.status, .ok)
    }

    func testUpsert_updatesExistingRecord() throws {
        let now = Date()
        var record = FileRecord(
            path: "/RAID/file.txt",
            size: 100,
            mtime: now,
            hash: "oldhash",
            hashAlgorithm: "sha256",
            firstSeen: now,
            lastVerified: now,
            status: .ok
        )
        try store.upsert(record)

        record.hash = "newhash"
        record.status = .modified
        try store.upsert(record)

        let fetched = try store.record(for: "/RAID/file.txt")
        XCTAssertEqual(fetched?.hash, "newhash")
        XCTAssertEqual(fetched?.status, .modified)
    }

    func testRecord_returnsNilForUnknownPath() throws {
        let result = try store.record(for: "/nonexistent/path.jpg")
        XCTAssertNil(result)
    }

    // MARK: - Batch upsert

    func testUpsertBatch_insertsManyRecords() throws {
        let count = 1000
        let now = Date()
        var records: [FileRecord] = []
        for i in 0..<count {
            records.append(FileRecord(
                path: "/RAID/file_\(i).jpg",
                size: Int64(i * 1024),
                mtime: now,
                hash: String(format: "%064d", i),
                hashAlgorithm: "sha256",
                firstSeen: now,
                lastVerified: now,
                status: .ok
            ))
        }

        try store.upsertBatch(records)

        let paths = try store.allPaths()
        XCTAssertEqual(paths.count, count)
    }

    func testUpsertBatch_emptyIsNoOp() throws {
        XCTAssertNoThrow(try store.upsertBatch([]))
        let paths = try store.allPaths()
        XCTAssertTrue(paths.isEmpty)
    }

    // MARK: - allPaths

    func testAllPaths_returnsAllInsertedPaths() throws {
        let now = Date()
        let expected = Set(["/RAID/a.jpg", "/RAID/b.jpg", "/RAID/c.jpg"])
        for path in expected {
            try store.upsert(FileRecord(
                path: path, size: 0, mtime: now, hash: "x",
                hashAlgorithm: "sha256", firstSeen: now, lastVerified: now
            ))
        }
        let result = try store.allPaths()
        XCTAssertEqual(result, expected)
    }

    // MARK: - deleteRecord

    func testDeleteRecord_removesFromDB() throws {
        let now = Date()
        try store.upsert(FileRecord(
            path: "/RAID/gone.jpg", size: 0, mtime: now, hash: "abc",
            hashAlgorithm: "sha256", firstSeen: now, lastVerified: now, status: .ok
        ))
        try store.deleteRecord(path: "/RAID/gone.jpg")
        let fetched = try store.record(for: "/RAID/gone.jpg")
        XCTAssertNil(fetched)
    }

    // MARK: - filesToVerify ordering

    func testFilesToVerify_returnsOldestFirst() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let records = (0..<5).map { i in
            FileRecord(
                path: "/RAID/file_\(i).jpg",
                size: 100,
                mtime: base,
                hash: "hash\(i)",
                hashAlgorithm: "sha256",
                firstSeen: base,
                lastVerified: base.addingTimeInterval(Double(i) * 86400),
                status: .ok
            )
        }
        try store.upsertBatch(records)

        let cutoff = base.addingTimeInterval(3 * 86400)  // 3 days after base
        let toVerify = try store.filesToVerify(before: cutoff, limit: 10)

        // Should return files 0, 1, 2 (lastVerified < cutoff), oldest first
        XCTAssertEqual(toVerify.count, 3)
        XCTAssertEqual(toVerify[0].path, "/RAID/file_0.jpg")
        XCTAssertEqual(toVerify[1].path, "/RAID/file_1.jpg")
        XCTAssertEqual(toVerify[2].path, "/RAID/file_2.jpg")
    }

    func testFilesToVerify_respectsLimit() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let records = (0..<10).map { i in
            FileRecord(
                path: "/RAID/file_\(i).jpg",
                size: 0, mtime: base, hash: "hash\(i)",
                hashAlgorithm: "sha256", firstSeen: base, lastVerified: base, status: .ok
            )
        }
        try store.upsertBatch(records)

        let cutoff = Date()  // far future
        let toVerify = try store.filesToVerify(before: cutoff, limit: 3)
        XCTAssertEqual(toVerify.count, 3)
    }

    func testFilesToVerify_skipsCorruptedFiles() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        try store.upsert(FileRecord(
            path: "/RAID/corrupted.jpg", size: 0, mtime: base,
            hash: "badhash", hashAlgorithm: "sha256",
            firstSeen: base, lastVerified: base, status: .corrupted
        ))
        let cutoff = Date()
        let toVerify = try store.filesToVerify(before: cutoff, limit: 10)
        XCTAssertTrue(toVerify.isEmpty)
    }

    // MARK: - Scan operations

    func testInsertScan_returnsRowId() throws {
        var scan = ScanResult(startedAt: Date())
        let rowid = try store.insertScan(scan)
        XCTAssertGreaterThan(rowid, 0)
        scan.id = rowid

        // Update it
        scan.filesWalked = 100
        scan.status = .completed
        scan.completedAt = Date()
        try store.updateScan(scan)

        let last = try store.lastScan()
        XCTAssertNotNil(last)
        XCTAssertEqual(last?.filesWalked, 100)
        XCTAssertEqual(last?.status, .completed)
    }

    func testLastScan_returnsNilWhenEmpty() throws {
        let last = try store.lastScan()
        XCTAssertNil(last)
    }

    // MARK: - Recent scans

    /// Inserts four scans with distinct `startedAt` values and completes only
    /// the oldest one via `updateScan`.
    private func insertFourScansCompletingOldest() throws {
        var oldest = ScanResult(startedAt: Date(timeIntervalSince1970: 1000))
        oldest.id = try store.insertScan(oldest)
        oldest.completedAt = Date(timeIntervalSince1970: 1500)
        oldest.status = .completed
        try store.updateScan(oldest)

        for seconds in [2000.0, 3000.0, 4000.0] {
            _ = try store.insertScan(ScanResult(startedAt: Date(timeIntervalSince1970: seconds)))
        }
    }

    func testRecentScans_returnsNewestFirstRespectingLimit() throws {
        try insertFourScansCompletingOldest()

        let recent = try store.recentScans(limit: 3)

        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(
            recent.map { $0.startedAt.timeIntervalSince1970 },
            [4000, 3000, 2000]
        )
        XCTAssertTrue(recent.allSatisfy { $0.completedAt == nil })
    }

    func testRecentScans_limitLargerThanRowCountReturnsAll() throws {
        try insertFourScansCompletingOldest()

        let recent = try store.recentScans(limit: 10)

        XCTAssertEqual(recent.count, 4)
        XCTAssertEqual(recent.last?.startedAt.timeIntervalSince1970, 1000)
        XCTAssertNotNil(recent.last?.completedAt)
    }

    func testRecentScans_returnsEmptyWhenNoScans() throws {
        let recent = try store.recentScans(limit: 3)
        XCTAssertTrue(recent.isEmpty)
    }

    func testRecentScans_repeatedCallsReturnIdenticalResults() throws {
        try insertFourScansCompletingOldest()

        let first = try store.recentScans(limit: 3)
        let second = try store.recentScans(limit: 3)

        XCTAssertEqual(first.map { $0.id }, second.map { $0.id })
        XCTAssertEqual(
            first.map { $0.startedAt.timeIntervalSince1970 },
            second.map { $0.startedAt.timeIntervalSince1970 }
        )
    }

    // MARK: - Events

    func testLogEvent_doesNotThrow() throws {
        XCTAssertNoThrow(try store.logEvent(ScanEvent(
            eventType: ScanEvent.fileCorrupted,
            path: "/RAID/bad.jpg",
            detail: "{\"test\":true}"
        )))
    }

    // MARK: - Last RAID event

    func testLastRaidEvent_returnsNilWhenNoEvents() throws {
        let event = try store.lastRaidEvent()
        XCTAssertNil(event)
    }

    func testLastRaidEvent_returnsNilWhenOnlyNonRaidEvents() throws {
        try store.logEvent(ScanEvent(
            eventType: ScanEvent.fileCorrupted,
            path: "/RAID/bad.jpg",
            detail: "corruption detected"
        ))
        try store.logEvent(ScanEvent(
            eventType: ScanEvent.scanComplete,
            detail: "done"
        ))

        let event = try store.lastRaidEvent()
        XCTAssertNil(event)
    }

    func testLastRaidEvent_returnsMostRecentRaidEvent() throws {
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: ScanEvent.raidDegraded,
            detail: "degraded"
        ))
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 2000),
            eventType: ScanEvent.raidOnline,
            detail: "recovered"
        ))

        let event = try store.lastRaidEvent()
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.eventType, ScanEvent.raidOnline)
        XCTAssertEqual(event?.detail, "recovered")
    }

    func testLastRaidEvent_ignoresNonRaidEventTypes() throws {
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: ScanEvent.raidDisappeared,
            detail: "array gone"
        ))
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 2000),
            eventType: ScanEvent.fileNew,
            path: "/RAID/new.jpg"
        ))

        let event = try store.lastRaidEvent()
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.eventType, ScanEvent.raidDisappeared)
    }

    // MARK: - Last event of type

    func testLastEventOfType_returnsNilWhenNoMatchingEvents() throws {
        let event = try store.lastEvent(ofType: "scan_backoff")
        XCTAssertNil(event)
    }

    func testLastEventOfType_returnsNewestMatchingEvent() throws {
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: "scan_backoff",
            detail: "first"
        ))
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 2000),
            eventType: "scan_backoff",
            detail: "second"
        ))
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 3000),
            eventType: ScanEvent.raidDegraded,
            detail: "degraded"
        ))

        let event = try store.lastEvent(ofType: "scan_backoff")

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.eventType, "scan_backoff")
        XCTAssertEqual(event?.detail, "second")
        XCTAssertEqual(event?.timestamp.timeIntervalSince1970, 2000)
    }

    func testLastEventOfType_repeatedCallsReturnIdenticalResults() throws {
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: "scan_backoff",
            detail: "first"
        ))
        try store.logEvent(ScanEvent(
            timestamp: Date(timeIntervalSince1970: 2000),
            eventType: "scan_backoff",
            detail: "second"
        ))

        let first = try store.lastEvent(ofType: "scan_backoff")
        let second = try store.lastEvent(ofType: "scan_backoff")

        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(first?.detail, second?.detail)
    }

    // MARK: - Algorithm query

    func testRecordsWithAlgorithm() throws {
        let now = Date()
        try store.upsert(FileRecord(
            path: "/RAID/a.jpg", size: 0, mtime: now, hash: "h1",
            hashAlgorithm: "sha256", firstSeen: now, lastVerified: now
        ))
        try store.upsert(FileRecord(
            path: "/RAID/b.jpg", size: 0, mtime: now, hash: "h2",
            hashAlgorithm: "sha256", firstSeen: now, lastVerified: now
        ))

        let sha256Records = try store.records(withAlgorithm: "sha256")
        XCTAssertEqual(sha256Records.count, 2)

        let blake3Records = try store.records(withAlgorithm: "blake3")
        XCTAssertTrue(blake3Records.isEmpty)
    }
}
