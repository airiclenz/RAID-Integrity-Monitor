# Follow-ups

Open items recorded outside any plan. Remove a line when it is done.

## Documentation drift (found by the v2.0.0 release pre-flight, 2026-09-20)

Doc claims that no longer match the shipped code. None blocks a user; all are worth a docs pass.

- `technical-design-specification.md:653` — installer step "5. Sends a test notification" does not happen; `install.sh` only prints `--mode test` as a manual next step.
- `technical-design-specification.md:257,407` — no `missing` file status exists; vanished files are deleted from `files` (`FileScanner.swift`, `deleteRecord(path:)`).
- `technical-design-specification.md:271` — event-type list is stale; actual names are in `Models.swift` (`raid_online`, `raid_disappeared`, `smart_failed`, `hash_upgrade_start`, `hash_upgrade_complete`) plus `scan_backoff` in `ScanSchedulePolicy.swift`.
- `technical-design-specification.md:592` — `MacOSNotificationChannel` is now `MacOSAlertChannel`.
- `technical-design-specification.md:587` — `AlertChannel.send(_:)` is non-throwing.
- `technical-design-specification.md:624` — only a `.failed` SMART status raises an alert; array degraded/failed state derives from array status alone.
- `technical-design-specification.md:556` — SQLite is opened with plain `sqlite3_open`, not `SQLITE_OPEN_FULLMUTEX`.
- `README.md:5,11` — scans are interval-based (`fileScanIntervalHours`), not "daily"/"each night"; README §Scheduling already states this correctly.
- `README.md:224,233,281,289,299,498` — documented defaults (`maxVerificationsPerRun` 1000, `verificationIntervalDays` 30) are the code fallbacks; `config.json.template` (what `install.sh` installs) ships 25000 and 60.
- `IntegrityMonitor/plist.template` comment references a nonexistent `--mode init`.

## Channels

- Homebrew formula for `raid-integrity-monitor` in `airiclenz/homebrew-tap` — skipped at v2.0.0 by decision; `install.sh` remains the only install path.
