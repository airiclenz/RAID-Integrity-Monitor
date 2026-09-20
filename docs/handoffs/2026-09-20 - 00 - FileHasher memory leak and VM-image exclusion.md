# Handoff: FileHasher memory leak → macOS "out of application memory"

**Date:** 2026-09-20
**Status:** Diagnosed, NOT fixed. LaunchAgent is stopped and disabled on the dev machine.
**Next session goal:** fix the leak in `FileHasher.swift`, exclude VM disk images, rebuild, reinstall, re-enable the agent, verify.

---

## Symptom

macOS (27.0, build 26A428, 32 GB RAM) shows the **"Your system has run out of application memory"** Force-Quit dialog repeatedly, even right after a reboot, while Activity Monitor / `vm_stat` show ~15 GB unused. The apps listed in the dialog (Claude, Code, Enpass, Terminal, Finder) are NOT the cause.

## Root cause (verified)

`raid-integrity-monitor` (this project's CLI, installed to `~/bin/raid-integrity-monitor`, launched every 300 s by `~/Library/LaunchAgents/com.airic-lenz.raid-integrity-monitor.plist`) balloons to tens of GB of RAM while hashing a large file, gets killed by the kernel, and retries 5 minutes later. Forever.

Two contributing factors:

### 1. Autorelease leak in the hash loop (the bug)

`IntegrityMonitor/Sources/IntegrityMonitor/Hashing/FileHasher.swift` — both `SHA256Hasher.hash(fileAt:onProgress:)` (~L58-93) and `BLAKE3Hasher.hash(fileAt:onProgress:)` (~L117-157) do:

```swift
while true {
    let chunk: Data
    chunk = try handle.read(upToCount: chunkSize) ?? Data()   // 4 MB
    ...
    if chunk.isEmpty { break }
    hasher.update(...)
}
```

`FileHandle.read(upToCount:)` is bridged from `NSFileHandle` and returns an **autoreleased `NSData`**. There is no `autoreleasepool { }` around the loop body, and the hashing runs on worker tasks (`FileScanner.swift` ~L361-390, worker-pool) that never drain a pool mid-file. Every 4 MB chunk therefore stays alive until the *whole file* is hashed → resident memory ≈ file size.

Nightly scans succeeded until 2026-09-18 only because the changed files were small.

### 2. A 1 TB VM disk image on a watched volume (the trigger)

Files on `/Volumes/Bit Plantage` modified since the last successful scan (2026-09-18 22:06):

| Size | Path |
|---|---|
| **1000 GB (sparse)** | `/Volumes/Bit Plantage/Virtual Machines/OrbStack/data.img.raw` |
| 29 GB | `/Volumes/Bit Plantage/Virtual Machines/UTM/Windows.utm/Data/….qcow2` |
| 1 GB | `/Volumes/Bit Plantage/Virtual Machines/OrbStack/swap.img` |
| tiny | 5 more VM config/screenshot files |

The `Virtual Machines` directory is **not** in `exclude.directoryPatterns` (only `LLM-Models`, `*.lrdata`, etc.). These images change on every VM boot, so hashing them is pointless even after the leak is fixed.

## Evidence trail

- `~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log` — every run since 08:43 today ends at `Phase 2: Hashing 8 new/modified file(s)` with no `Scan complete`; "last completed 17757126h ago" (= epoch 0 → the completed-timestamp was never written because the process died).
- `/Library/Logs/DiagnosticReports/raid-integrity-monitor_2026-09-20-*.cpu_resource.diag` — one per run, ~65 % CPU for ~138 s, then process gone.
- `sysctl vm.swapusage` / `top`: 2.18 M swapouts (~8 GB) within 16 min of boot; yesterday's panic log (`panic-full-2026-09-19-101212.0002.panic`, watchdog timeout — separate issue) records 5 swapfiles.
- `launchd.stderr.log`: `Warning: watchPath not currently accessible: /Volumes/G-Titan` — the AppleRAID set `G-Titan` is currently **not present** (`diskutil appleRAID list` → none). Unrelated to the memory issue but worth the user's attention; monitor logs `raid_disappeared`.

## Current machine state (what was done this session)

```
launchctl bootout gui/501/com.airic-lenz.raid-integrity-monitor   # stopped
launchctl disable gui/501/com.airic-lenz.raid-integrity-monitor   # survives reboot
```
`launchctl print-disabled gui/501` shows it disabled. No monitor process is running. **No code or config was changed.**

## Plan for next session

1. **Fix `FileHasher.swift`** — wrap the body of both `while true` loops in `autoreleasepool { }` (return the `chunk` / a "done" flag from the pool closure). Keep the 4 MB `chunkSize`. Check `Upgrade/HashUpgradeScanner.swift` reuses these hashers rather than having its own loop (grep showed `read(upToCount:` only in `FileHasher.swift`, so it should be fine).
2. **Add a regression test** in `IntegrityMonitor/Tests/…/BLAKE3HasherTests.swift` (and SHA256) that hashes a ≥ 1 GB temp file (sparse is fine: `truncate`/`ftruncate`) and asserts resident memory stays well below file size (`task_info` / `mach_task_basic_info.resident_size` before/after). If that's too slow for CI, gate it behind an env var.
3. **Exclude VM images by default** — add `"Virtual Machines"` to `exclude.directoryPatterns` in
   - `~/.config/raid-integrity-monitor/config.json` (live config on this machine), and
   - `IntegrityMonitor/config.json.template` (so fresh installs get it).
   Consider also `*.img`, `*.img.raw`, `*.qcow2`, `*.vmdk`, `*.utm` patterns, or a sane default `maxSizeBytes`.
4. **Rebuild & reinstall**: `cd IntegrityMonitor && ./install.sh` (does `swift build -c release`, copies to `~/bin/raid-integrity-monitor`, installs plist). Check whether install.sh overwrites the live `config.json` — line ~254 copies the template; confirm it only does so when no config exists.
5. **Re-enable the agent**:
   ```
   launchctl enable gui/501/com.airic-lenz.raid-integrity-monitor
   launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.airic-lenz.raid-integrity-monitor.plist
   ```
6. **Verify**: trigger a run (`launchctl kickstart gui/501/com.airic-lenz.raid-integrity-monitor` or run `~/bin/raid-integrity-monitor --mode scheduled` manually) while watching `ps -o rss= -p <pid>`; confirm the log reaches `=== Scan complete` and RSS stays < ~200 MB.
7. Optional hardening: the scheduler treats a killed run as "scan never completed" and immediately restarts on the next tick. Consider recording a *scan-started* marker and backing off (or alerting) after N consecutive incomplete scans, so a future failure can't loop every 5 min.

## Side note (not to fix here)

`config.json` has `"logging": { "level": "~/Google Drive/My Drive/RAID-Integrity-Monitor/manifest.db" … }` — looks like a copy-paste error (a replica DB path pasted into `level`). Tell the user; don't silently change it.

## Suggested skills

- `coding-standards` — before editing Swift (Swift overrides apply).
- `feature-implementation` — for the scoped fix + test + template change.
- `code-review` (`/code-review medium`) — on the diff before committing.
- `pr-lifecycle` — if the fix goes through a branch/PR.

## Related artifacts

- Repo: `/Users/airic/Repos/RAID Integrity Monitor` (branch state at handoff: HEAD `c77a3ad`, clean).
- Installer: `IntegrityMonitor/install.sh`; plist template: `IntegrityMonitor/com.airic-lenz.raid-integrity-monitor.plist.template`.
- Live config: `~/.config/raid-integrity-monitor/config.json`; DB: `~/.local/share/raid-integrity-monitor/manifest.db` (895 MB).
