# Plan: FileHasher memory leak, VM-image exclusion, scheduler backoff

**Goal:** Stop `raid-integrity-monitor` from ballooning to file-size RSS while hashing (autoreleased `NSData` chunks from `FileHandle.read(upToCount:)`), exclude VM disk images by default, and stop the scheduler from retrying a killed scan every 5 minutes forever.
**Date:** 2026-09-20
**Status:** unexecuted
**Sized for:** ~200k-context host
**Base commit:** c77a3ad

**Sources:**
- `docs/handoffs/2026-09-20 - 00 - FileHasher memory leak and VM-image exclusion.md` (diagnosis)
- `CLAUDE.md` (architecture rules: zero dependencies, worker pool, prepared statements)
- `IntegrityMonitor/Sources/IntegrityMonitor/Hashing/FileHasher.swift`, `Upgrade/HashUpgradeScanner.swift` (the three leaking loops)

**Ratified design calls (user, 2026-09-20):**
- **Fix approach:** one shared POSIX `ChunkedFileReader` (open/read/close into a single buffer allocated once per file); all three hashing loops use it. No `autoreleasepool`, no `FileHandle`, no `Data` per chunk.
- **Leak test:** always-on, 512 MB sparse file, assert resident-memory growth < 64 MB, for SHA256, BLAKE3 and the upgrade path.
- **VM exclusions:** `directoryPatterns` += `"Virtual Machines"`, `"*.utm"`, `"*.vmwarevm"`, `"*.pvm"`; `pathPatterns` += `"*.qcow2"`, `"*.vmdk"`, `"*.vdi"`, `"*.img.raw"`. `maxSizeBytes` stays `null`. No `"*.img"`.
- **Backoff:** `--mode scheduled` only. If the 3 most recent `scans` rows all have `completed_at IS NULL`, skip the file scan until `fileScanIntervalHours` has elapsed since the newest `started_at`. Threshold 3 is a hardcoded constant, not config.
- **Alert once:** on first backoff detection log a `scan_backoff` event and send one alert gated by `onScanCompleteWithIssues`; later ticks skip the alert while a `scan_backoff` event newer than the newest scan's `started_at` exists.
- **Machine steps:** live config edit, reinstall, `launchctl`, RSS verification are a manual checklist (below), not plan items.
- **Schema seed fix:** item 0 added; fresh DBs seed schema_version with the current version.

**Regression check (2026-09-20, c77a3ad):**
- 0: guard folded — seed `schema_version` only when the table is empty (no UNIQUE constraint; `INSERT OR IGNORE` would append a row on every open).
- 1: guard folded — `forEachChunk` returns the fstat size so the empty-file test can observe `totalSize`.
- 2: guard folded — `ResidentMemory.makeSparseFile` must create the file before `FileHandle(forWritingTo:)`.
- 3: guard folded — store-backed tests trap on `open()` at BASE; item 0 is the prerequisite.
- 4: guard folded — template test decodes with `JSONDecoder`, never `ConfigLoader.load`; README states existing configs need manual `exclude` edits.
- 5: guard folded — factor `lastRaidEvent()` column reads into `extractScanEvent(from:)`; test events carry explicit timestamps.
- 6: guard folded — `lastEvent(ofType:)` queried only on the 3-incomplete branch; Ctrl+C'd manual scans named in README and alert body.

**Standing requirements:**
- skills: coding-standards (Swift overrides; tab indentation, `// ====` function dividers, `// ::::` property separators, one parameter per line)
- Tests run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` from `IntegrityMonitor/`.
- No SwiftPM dependencies; `sqlite3`, `CryptoKit`, `CBLAKE3`, `Darwin` only.
- Any authorized deviation from item text lands as a dated NOTES line under the item.

**Out of scope:**
- Editing `~/.config/raid-integrity-monitor/config.json`, running `install.sh`, `launchctl` — manual checklist.
- The absent `G-Titan` RAID set; the 2026-09-19 watchdog panic.
- Deep-merge of nested config keys in `install.sh`.
- Any version bump.

---

## 0. Fix fresh-database schema seed (duplicate `files_inaccessible` column) — ✅ DONE (2026-09-20)

**What:** Regression from `c77a3ad` ("Add files_inaccessible counter"): `SQLiteManifestStore.createSchema()` already declares `files_inaccessible` in `CREATE TABLE scans` but seeds `INSERT OR IGNORE INTO schema_version VALUES (1)`, so `runMigrations()` immediately runs `ALTER TABLE scans ADD COLUMN files_inaccessible` and `open()` fails with `duplicate column name` on every fresh database (fresh installs and every store-backed test). Fix: seed `schema_version` with the current version (3) in `createSchema()` — the DDL there is the complete current schema, so a fresh DB needs no migrations. Existing DBs at version 1 or 2 still migrate exactly as today. `schema_version` stays 3; no other schema change.
**Regression guard.** `schema_version` has no UNIQUE constraint, so `INSERT OR IGNORE INTO schema_version VALUES (3)` would append a row on every open and `runMigrations()` reads `SELECT version FROM schema_version LIMIT 1` with no ORDER BY — a v2 DB could then read the stray 3, skip migration 3 and fail in `prepareStatements()`. Seed only when empty: `INSERT INTO schema_version (version) SELECT 3 WHERE NOT EXISTS (SELECT 1 FROM schema_version)`. This keeps the v1/v2 migration path byte-identical and stops row accumulation.
**Files:** `IntegrityMonitor/Sources/IntegrityMonitor/Database/SQLiteManifestStore.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/SQLiteManifestStoreTests.swift`
**Read first:** IntegrityMonitor/Sources/IntegrityMonitor/Database/SQLiteManifestStore.swift — open, createSchema, runMigrations, prepareStatements, exec; IntegrityMonitor/Tests/IntegrityMonitorTests/SQLiteManifestStoreTests.swift — setUp, testOpen_createsTablesSuccessfully; CLAUDE.md — "SQLite schema" section (schema version 3)
**Tests:** Add `testOpen_freshDatabaseSeedsCurrentSchemaVersion` to `SQLiteManifestStoreTests`: open a fresh on-disk store, `insertScan` + `updateScan` a `ScanResult` with `filesInaccessible = 7`, `lastScan()` returns it with `filesInaccessible == 7`; close and reopen the same file — `open()` succeeds again and `schema_version` holds exactly one row (read it with `sqlite3_open` on the same file in the test). Existing `SQLiteManifestStoreTests` must pass (they trap on `open()` today).
**Acceptance:**
```
cd IntegrityMonitor && swift build
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SQLiteManifestStoreTests
```
Bite check: `testOpen_freshDatabaseSeedsCurrentSchemaVersion` must fail against the pre-item tree.
**Commit:** `fix(db): seed schema_version with current version so fresh databases open`
NOTES (2026-09-20): introduced `private static let currentSchemaVersion = 3` in `SQLiteManifestStore` and interpolated it into the seed statement instead of a bare literal (coding-standards magic-number rule); `runMigrations()` literals untouched.
NOTES (2026-09-20): new test code uses the 4-space indentation of the existing `SQLiteManifestStoreTests.swift` rather than tabs, to avoid mixed indentation in one file; the test file was not restyled.

## 1. Add `ChunkedFileReader` (POSIX chunk reader) — ✅ DONE (2026-09-20)

**What:** New `IntegrityMonitor/Sources/IntegrityMonitor/Hashing/ChunkedFileReader.swift`, an internal `enum ChunkedFileReader` with one static entry point:
`static func forEachChunk(of url: URL, chunkSize: Int, body: (_ chunk: UnsafeRawBufferPointer, _ totalSize: Int64) throws -> Void) throws`.
Binding behaviour:
- `open(2)` `O_RDONLY`; `fstat(2)` for `totalSize`; `close(2)` in `defer`. Failure of open/read → `AppError.fileAccess(path: url.path, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))`.
- Exactly one `UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)` per call, deallocated in `defer`. Never `Data`, never `FileHandle`.
- `read(2)` loop: `EINTR` retried; a short read (`0 < n < chunkSize`) is passed to `body` as an `n`-byte slice and is NOT end-of-file; only `0` ends the loop. `body` errors propagate.
- Nothing else in this item — hashers switch in items 2 and 3.
**Regression guard.** `forEachChunk` returning `Void` delivers `totalSize` only through `body`, which the empty-file test asserts is never called — the test could not observe `totalSize == 0`. Declare `@discardableResult static func forEachChunk(of:chunkSize:body:) throws -> Int64` returning the `fstat` size; the empty-file test asserts the return value.
**Files:** `IntegrityMonitor/Sources/IntegrityMonitor/Hashing/ChunkedFileReader.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/ChunkedFileReaderTests.swift`
**Read first:** IntegrityMonitor/Sources/IntegrityMonitor/Hashing/FileHasher.swift — SHA256Hasher.hash(fileAt:onProgress:), BLAKE3Hasher.hash(fileAt:onProgress:); IntegrityMonitor/Sources/IntegrityMonitor/Models.swift — AppError.fileAccess, AppError.description; IntegrityMonitor/Tests/IntegrityMonitorTests/BLAKE3HasherTests.swift — setUp, tearDown, testHash_throwsOnMissingFile; IntegrityMonitor/Package.swift — IntegrityMonitorTests testTarget
**Tests:** `ChunkedFileReaderTests` (temp dir per test, as in `BLAKE3HasherTests`): empty file → `body` never called, returned `totalSize == 0`; 10 000-byte file with `chunkSize: 4096` → chunks of 4096, 4096, 1808 and concatenation equals the file; `totalSize` equals file size; missing path throws `AppError.fileAccess`; a `body` that throws propagates the error.
**Acceptance:**
```
cd IntegrityMonitor && swift build
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ChunkedFileReaderTests
```
**Commit:** `feat(hashing): add POSIX ChunkedFileReader with single reusable buffer`
NOTES (2026-09-20): added a `precondition(chunkSize > 0)` guard — a zero-byte buffer would make `read(2)` return 0 and silently report EOF on a non-empty file.
NOTES (2026-09-20): `fstat(2)` failure also throws `AppError.fileAccess` (plan named only open/read failures) rather than silently reporting `totalSize` 0.
NOTES (2026-09-20): docs — added a `Hashing/ChunkedFileReader.swift` row to the CLAUDE.md module table.

## 2. Fix `SHA256Hasher` / `BLAKE3Hasher` leak via `ChunkedFileReader` — ✅ DONE (2026-09-20)

Depends on item 1.

**What:** Fix for the leak diagnosed in the handoff (regression since the hashers were written: every 4 MB `read(upToCount:)` result stays autoreleased until the whole file is hashed → RSS ≈ file size). In `Hashing/FileHasher.swift` replace both `while true { handle.read(upToCount:) }` loops with `ChunkedFileReader.forEachChunk(of:chunkSize:)`. SHA-256 feeds `hasher.update(bufferPointer: chunk)`; BLAKE3 feeds `blake3_hasher_update(&hasher, chunk.baseAddress, chunk.count)`. `bytesProcessed`/`onProgress` semantics unchanged (called once per chunk with `(bytesProcessed, totalSize)`). `chunkSize` default stays 4 MiB. Remove the `FileHandle` and `resourceValues(forKeys: [.fileSizeKey])` code from both hashers. Public API of `FileHasher`, both structs and `HasherFactory` unchanged.
Add test helper `IntegrityMonitor/Tests/IntegrityMonitorTests/Support/ResidentMemory.swift`: `enum ResidentMemory { static func currentBytes() -> UInt64 }` via `task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), …)` reading `mach_task_basic_info.resident_size`; and `static func makeSparseFile(at url: URL, byteCount: Int) throws` using `FileHandle(forWritingTo:)` + `truncate(atOffset:)` (or `ftruncate`).
**Regression guard.** `FileHandle(forWritingTo:)` throws NSCocoaErrorDomain code 4 ("doesn't exist") on a path with no file yet, and every leak test starts on a fresh temp path. `makeSparseFile` must create the file first — `FileManager.default.createFile(atPath:contents:nil)` before `FileHandle(forWritingTo:)`, or `open(path, O_WRONLY|O_CREAT, 0o644)` + `ftruncate`.
**Files:** `IntegrityMonitor/Sources/IntegrityMonitor/Hashing/FileHasher.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/Support/ResidentMemory.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/SHA256HasherTests.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/BLAKE3HasherTests.swift`
**Read first:** IntegrityMonitor/Sources/IntegrityMonitor/Hashing/FileHasher.swift — SHA256Hasher.hash(fileAt:onProgress:), BLAKE3Hasher.hash(fileAt:onProgress:), HashProgressHandler; IntegrityMonitor/Tests/IntegrityMonitorTests/SHA256HasherTests.swift — testHash_emptyFile, testHash_knownContent, testHash_multiChunkFile; IntegrityMonitor/Tests/IntegrityMonitorTests/BLAKE3HasherTests.swift — testHash_multiChunkFile; IntegrityMonitor/Sources/IntegrityMonitor/Scanning/FileScanner.swift — hashFile(url:existingRecord:hasher:now:onProgress:)
**Tests:** In each hasher test file add `testHash_largeFileDoesNotRetainChunks`: 512 MiB sparse file (`ResidentMemory.makeSparseFile`), `before = ResidentMemory.currentBytes()`, hash, `after`, `XCTAssertLessThan(after &- before, 64 * 1024 * 1024)` (guard `after >= before` first; treat a decrease as pass). Also `testHash_progressReportsMonotonicAndTotal`: 10 MiB file, `chunkSize: 4 MiB`, progress calls are `(4,10),(8,10),(10,10)` MiB. Existing known-digest tests must still pass (proves byte-exact equivalence of the new loop).
**Acceptance:**
```
cd IntegrityMonitor && swift build
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SHA256HasherTests|BLAKE3HasherTests"
```
Bite check: `testHash_largeFileDoesNotRetainChunks` (both files) must fail against the pre-item tree.
**Commit:** `fix(hashing): stream file chunks through ChunkedFileReader to stop autorelease growth`
NOTES (2026-09-20): new test methods in SHA256HasherTests.swift use tab indentation per the standing coding-standards requirement; the pre-existing body of that file uses 4-space indentation and was left untouched (no restyle).
NOTES (2026-09-20): each hasher test file gained a private `ProgressRecorder` (NSLock-guarded) so the `@Sendable` progress handler can collect calls without data-race warnings.
NOTES (2026-09-20): bite check confirmed locally — against the HEAD FileHasher.swift both `testHash_largeFileDoesNotRetainChunks` fail (RSS growth 268 MB SHA-256 / 539 MB BLAKE3); with the new loops they pass.

## 3. Fix `HashUpgradeScanner.upgradeFile` leak via `ChunkedFileReader`

Depends on items 0 and 1.

**What:** Same defect, third copy (missed by the handoff): `Upgrade/HashUpgradeScanner.swift` `upgradeFile(record:oldHasher:newHasher:newAlgorithm:onProgress:)` reads with `FileHandle.read(upToCount:)` inside one file-wide `autoreleasepool`, so chunks accumulate per file. Replace the `FileHandle` + `while true` loop with `ChunkedFileReader.forEachChunk(of:chunkSize: 4 * 1024 * 1024)`; feed `UnsafeRawBufferPointer` to both the old and new hasher states exactly as today (SHA via `update(bufferPointer:)`, BLAKE3 via `blake3_hasher_update`). Remove the now-pointless `autoreleasepool` wrapper and its comment. On open/read failure keep the existing behaviour: `logger.warn("Cannot read …")` and `return .skipped(path:)`. Single-pass dual hashing, verify-before-upgrade, and progress reporting unchanged.
**Regression guard.** At BASE `swift test --filter HashUpgradeScannerTests` traps before any test body runs: `SQLiteManifestStore.open()` on a fresh DB seeds `schema_version` 1 then runs migration 3's `ALTER TABLE scans ADD COLUMN files_inaccessible` → `duplicate column name` → `try! store.open()` in `setUp` crashes the xctest process. Item 0 (with `testOpen_freshDatabaseSeedsCurrentSchemaVersion` in `SQLiteManifestStoreTests`) is the prerequisite — this item runs only after item 0 has landed, so its test and bite check are observable.
**Files:** `IntegrityMonitor/Sources/IntegrityMonitor/Upgrade/HashUpgradeScanner.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/HashUpgradeScannerTests.swift`
**Read first:** IntegrityMonitor/Sources/IntegrityMonitor/Upgrade/HashUpgradeScanner.swift — upgradeFile(record:oldHasher:newHasher:newAlgorithm:onProgress:), FileUpgradeResult, buildFileProgress(fileURL:completed:total:phaseStart:); IntegrityMonitor/Tests/IntegrityMonitorTests/HashUpgradeScannerTests.swift — setUp, sha256(of:), testUpgrade_cleanFile_succeeds; IntegrityMonitor/Sources/IntegrityMonitor/Database/SQLiteManifestStore.swift — open; IntegrityMonitor/Sources/IntegrityMonitor/Database/ManifestStore.swift — records(withAlgorithm:)
**Tests:** Add `testUpgrade_largeFileDoesNotRetainChunks` to `HashUpgradeScannerTests`: one 512 MiB sparse file recorded as `sha256` in a temp `SQLiteManifestStore` (its real SHA-256 computed by `SHA256Hasher` from item 2), run `upgrade(from: "sha256", to: "blake3")`, assert RSS growth < 64 MiB (`ResidentMemory`) and the record's `hash_algorithm` is now `blake3` with the digest `BLAKE3Hasher` computes for the same file. Existing upgrade tests unchanged.
**Acceptance:**
```
cd IntegrityMonitor && swift build
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HashUpgradeScannerTests
```
Bite check: `testUpgrade_largeFileDoesNotRetainChunks` must fail against the pre-item tree.
**Commit:** `fix(upgrade): stream chunks through ChunkedFileReader in upgradeFile`

## 4. Exclude VM disk images by default

**What:** In `IntegrityMonitor/config.json.template` add to `exclude.directoryPatterns`: `"Virtual Machines"`, `"*.utm"`, `"*.vmwarevm"`, `"*.pvm"`; add to `exclude.pathPatterns`: `"*.qcow2"`, `"*.vmdk"`, `"*.vdi"`, `"*.img.raw"`. `maxSizeBytes` stays `null`. In `README.md` "Configuration" (`pathPatterns` / `directoryPatterns` rows, ~L146-156) mention that VM bundles and disk images are excluded by default because they change on every VM boot. No code change — `ExclusionRules` already matches `directoryPatterns` on `lastPathComponent` and `pathPatterns` on both full path and filename.
**Regression guard.** (a) `ConfigLoader.load(from:)` validates `watchPaths` (the template's `/Volumes/VOLUME_NAME` does not exist → throws "No watchPaths are currently accessible") and runs `createDirectories`, writing `~/.local/share/raid-integrity-monitor/` on the test machine. Pin the test to `JSONDecoder().decode(Config.self, from: Data(contentsOf: templateURL))` — never `ConfigLoader.load`; the test must not touch `~/.local/share`. (b) `install.sh` merges top-level keys only and `exclude` already exists in every installed config, so "excluded by default" is false for reinstalled machines. In the README paragraph this item adds, state "on fresh installs; existing configs: add the patterns to `exclude` by hand" (deep-merge is out of scope per the plan header).
**Files:** `IntegrityMonitor/config.json.template`, `README.md`, `IntegrityMonitor/Tests/IntegrityMonitorTests/ExclusionRulesTests.swift`
**Read first:** IntegrityMonitor/config.json.template — exclude.pathPatterns, exclude.directoryPatterns; IntegrityMonitor/Sources/IntegrityMonitor/Scanning/ExclusionRules.swift — ExclusionRules.shouldDescend(into:), shouldInclude(fileAt:size:); IntegrityMonitor/Sources/IntegrityMonitor/Config.swift — ExclusionConfig.init(from:), ConfigLoader.load(from:); IntegrityMonitor/install.sh — config merge python block; README.md — "config merging on reinstall" paragraph
**Tests:** Add `testTemplateExcludesVirtualMachineImages` to `ExclusionRulesTests`: locate the template relative to `#filePath` (`../../config.json.template`), decode it with `JSONDecoder().decode(Config.self, from:)` (the same decoder `ConfigLoader.load` uses — never `ConfigLoader.load` itself), build `ExclusionRules(config: config.exclude)`, assert `shouldDescend(into:)` is false for `…/Virtual Machines`, `…/Windows.utm`, `…/Ubuntu.vmwarevm`, `…/Win11.pvm`; `shouldInclude` is false for `…/data.img.raw`, `…/disk.qcow2`, `…/disk.vmdk`, `…/disk.vdi`; and true for `…/backup.img` and `…/photo.jpg`. Match on the exact spellings written into the template.
**Acceptance:**
```
cd IntegrityMonitor && python3 -c "import json; json.load(open('config.json.template'))"
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ExclusionRulesTests
```
**Commit:** `feat(config): exclude VM bundles and disk images by default`

## 5. `ManifestStore`: `recentScans(limit:)` and `lastEvent(ofType:)`

Depends on item 0.

**What:** Add two read operations to the `ManifestStore` protocol (`Database/ManifestStore.swift`):
- `func recentScans(limit: Int) throws -> [ScanResult]` — newest first by `started_at`, same columns as `lastScan()`.
- `func lastEvent(ofType eventType: String) throws -> ScanEvent?` — newest `events` row with that `event_type`.
Implement in `SQLiteManifestStore`: two new prepared statements created in `open()` next to `stmtLastScan` / `stmtLastRaidEvent`, finalised in `close()`, reused (never re-prepared per call) via `sqlite3_reset` + `sqlite3_bind_*`. Reuse `extractScanResult(from:)` and the existing event-row extractor. `MirroredManifestStore` delegates both to `primary` (like `lastScan()`). No schema change; `schema_version` stays 3. Every `ManifestStore` conformer is `SQLiteManifestStore` and `MirroredManifestStore` (no test doubles exist).
**Regression guard.** (a) No "existing event-row extractor" exists — `lastRaidEvent()` inlines the column reads. Factor those reads into `private func extractScanEvent(from:)` (mirror of `extractScanResult(from:)`) and call it from both `lastRaidEvent()` and `lastEvent(ofType:)`. (b) `ScanEvent.init` defaults `timestamp: Date()`, so two `scan_backoff` inserts in one test can share a timestamp and `ORDER BY timestamp DESC LIMIT 1` returns either row. Give every event and scan in the test an explicit `timestamp:` / `startedAt:` (`Date(timeIntervalSince1970: 1000/2000/3000)`), as `testLastRaidEvent_returnsMostRecentRaidEvent` already does.
**Files:** `IntegrityMonitor/Sources/IntegrityMonitor/Database/ManifestStore.swift`, `IntegrityMonitor/Sources/IntegrityMonitor/Database/SQLiteManifestStore.swift`, `IntegrityMonitor/Sources/IntegrityMonitor/Database/MirroredManifestStore.swift`, `IntegrityMonitor/Tests/IntegrityMonitorTests/SQLiteManifestStoreTests.swift`
**Read first:** IntegrityMonitor/Sources/IntegrityMonitor/Database/ManifestStore.swift — ManifestStore (lastRaidEvent, lastScan); IntegrityMonitor/Sources/IntegrityMonitor/Database/SQLiteManifestStore.swift — prepareStatements, stmtLastScan, lastRaidEvent, extractScanResult(from:), close; IntegrityMonitor/Sources/IntegrityMonitor/Database/MirroredManifestStore.swift — lastScan; IntegrityMonitor/Tests/IntegrityMonitorTests/SQLiteManifestStoreTests.swift — testLastRaidEvent_returnsMostRecentRaidEvent
**Tests:** In `SQLiteManifestStoreTests` (on-disk DB in temp dir): insert 4 scans with distinct `startedAt`, complete only the oldest via `updateScan`; `recentScans(limit: 3)` returns 3, newest first, all with `completedAt == nil`; `recentScans(limit: 10)` returns 4; `lastEvent(ofType: "scan_backoff")` is nil, then after `logEvent` of two `scan_backoff` events and one `raid_degraded` (each with an explicit distinct `timestamp:`), returns the newest `scan_backoff`; calling each twice returns identical results (statement reuse).
**Acceptance:**
```
cd IntegrityMonitor && swift build
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SQLiteManifestStoreTests
```
**Commit:** `feat(db): add recentScans(limit:) and lastEvent(ofType:) to ManifestStore`

## 6. Scheduler backoff after consecutive incomplete scans

Depends on item 5.

**What:** New `IntegrityMonitor/Sources/IntegrityMonitor/Scanning/ScanSchedulePolicy.swift` — a pure, testable decision (`public struct ScanSchedulePolicy`, `static let incompleteScanThreshold = 3`):
`func decide(recentScans: [ScanResult], lastBackoffEvent: ScanEvent?, now: Date, fileScanInterval: TimeInterval) -> Decision` with `enum Decision { case runScan(lastCompleted: Date?); case notDue(nextIn: TimeInterval); case backoff(consecutiveIncomplete: Int, retryIn: TimeInterval, shouldAlert: Bool) }`. Binding rules:
- `recentScans` is `store.recentScans(limit: 3)` (newest first). If count == 3 and every `completedAt == nil`: `elapsed = now - recentScans[0].startedAt`; `elapsed >= fileScanInterval` → `.runScan`; else `.backoff(3, retryIn: interval - elapsed, shouldAlert: lastBackoffEvent == nil || lastBackoffEvent.timestamp < recentScans[0].startedAt)`.
- Otherwise: today's rule exactly — `lastCompleted = recentScans.first?.completedAt ?? .distantPast`; elapsed ≥ interval → `.runScan`, else `.notDue`.
In `IntegrityMonitorCLI/main.swift` `case "scheduled"` (~L253-278): replace the inline elapsed check with the policy. `.runScan` and `.notDue` log the existing messages unchanged. `.backoff`: `logger.warn("Scheduled run: skipping file scan — 3 consecutive scans never completed; retrying in ~Nh")`; when `shouldAlert`, send `Alert(title: "Integrity scan keeps failing", subtitle: "", body: "3 consecutive scans on this machine were killed or crashed before completing. Next retry in ~Nh. Check the log.", severity: .warning)` via `alertManager.sendIfEnabled(scanComplete:hasIssues: true)` and `store.logEvent(ScanEvent(eventType: "scan_backoff", detail: "{\"consecutiveIncomplete\":3}"))`. `scan`, `scan-files`, `verify`, `upgrade-hash` modes untouched. Document in `README.md` "Operation modes" `scheduled` row (~L349) and the `fileScanIntervalHours` paragraph (~L289): after 3 consecutive incomplete scans the scheduler waits a full interval and notifies once.
**Regression guard.** (a) `events` has no index and holds one row per new/modified file ever seen, so `lastEvent(ofType: "scan_backoff")` on every 5-minute tick would add a full events-table scan. In `case "scheduled"` call `lastEvent(ofType:)` only when `recentScans` has 3 rows all with `completedAt == nil`; otherwise pass `lastBackoffEvent: nil` — policy signature unchanged. (b) There is no SIGINT handler, so a manual `--mode scan` ended with Ctrl+C leaves `completed_at` NULL and counts toward the threshold. Name this in the README `scheduled` row / `fileScanIntervalHours` paragraph ("scans interrupted with Ctrl+C count as incomplete; `--mode scan` still runs immediately") and in the alert body ("killed, crashed or interrupted").
**Files:** `IntegrityMonitor/Sources/IntegrityMonitor/Scanning/ScanSchedulePolicy.swift`, `IntegrityMonitor/Sources/IntegrityMonitorCLI/main.swift`, `README.md`, `IntegrityMonitor/Tests/IntegrityMonitorTests/ScanSchedulePolicyTests.swift`
**Read first:** IntegrityMonitor/Sources/IntegrityMonitorCLI/main.swift — run() case "scheduled" (fileScanIntervalSeconds, lastScan, elapsed); IntegrityMonitor/Sources/IntegrityMonitor/Notifications/AlertChannel.swift — AlertManager.sendIfEnabled(scanComplete:hasIssues:); IntegrityMonitor/Sources/IntegrityMonitor/Models.swift — ScanResult, ScanEvent (well-known type constants), Alert; IntegrityMonitor/Sources/IntegrityMonitor/Scanning/FileScanner.swift — scan(mode:) (insertScan/updateScan lifecycle, completedAt only set on return or catch); IntegrityMonitor/Sources/IntegrityMonitor/Logger.swift — Logger.warn; README.md — Operation modes table `scheduled` row
**Tests:** `ScanSchedulePolicyTests` (pure, no DB): empty history → `.runScan`; last scan completed 1 h ago with 24 h interval → `.notDue(nextIn ≈ 23 h)`; 2 incomplete → `.runScan`; 3 incomplete started 10 min ago, no event → `.backoff(3, shouldAlert: true)`; same with a `scan_backoff` event newer than the newest `startedAt` → `shouldAlert: false`; event older than the newest `startedAt` → `shouldAlert: true`; 3 incomplete, newest 25 h ago → `.runScan`. Plus one CLI journey check in Acceptance.
**Acceptance:**
```
cd IntegrityMonitor && swift build
cd IntegrityMonitor && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScanSchedulePolicyTests
cd IntegrityMonitor && grep -n "3 consecutive scans never completed" Sources/IntegrityMonitorCLI/main.swift
```
**Commit:** `feat(scheduler): back off and alert once after 3 consecutive incomplete scans`

---

## Post-execution checklist (manual, on this machine — not plan items)

1. Edit `~/.config/raid-integrity-monitor/config.json`:
   - `exclude.directoryPatterns` += `"Virtual Machines"`, `"*.utm"`, `"*.vmwarevm"`, `"*.pvm"`; `exclude.pathPatterns` += `"*.qcow2"`, `"*.vmdk"`, `"*.vdi"`, `"*.img.raw"`.
   - `logging.level` → `"info"`; `database.replica` → `"~/Google Drive/My Drive/RAID-Integrity-Monitor/manifest.db"`.
2. `cd IntegrityMonitor && ./install.sh` (release build → `~/bin/raid-integrity-monitor`; existing config is merged top-level only, so step 1 is not overwritten).
3. Dry run with RSS watch: `~/bin/raid-integrity-monitor --mode scan-files & pid=$!; while kill -0 $pid 2>/dev/null; do ps -o rss= -p $pid; sleep 5; done` — RSS stays < ~200 MB and the log ends with `=== Scan complete`.
4. Re-enable: `launchctl enable gui/501/com.airic-lenz.raid-integrity-monitor && launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.airic-lenz.raid-integrity-monitor.plist`, then `launchctl kickstart gui/501/com.airic-lenz.raid-integrity-monitor`.
5. Confirm `tail ~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log` shows a completed scan and no backoff warning.
