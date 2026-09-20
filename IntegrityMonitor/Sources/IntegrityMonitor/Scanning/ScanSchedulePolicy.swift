import Foundation

// ---------------------------------------------------------------------------
// MARK: - ScanSchedulePolicy
// ---------------------------------------------------------------------------

/// Pure decision logic for `--mode scheduled`: is a file scan due, not due,
/// or should the scheduler back off because the most recent scans keep dying
/// before they complete?
///
/// Backoff rule: when the `incompleteScanThreshold` most recent scans all have
/// no `completedAt`, the scan is only retried once a full `fileScanInterval`
/// has elapsed since the newest of them started. The caller is told to alert
/// exactly once per backoff episode — while no `scan_backoff` event newer than
/// that newest `startedAt` exists.
public struct ScanSchedulePolicy {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	/// Number of consecutive incomplete scans that triggers backoff.
	public static let incompleteScanThreshold = 3

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	/// Event type written to the audit log when backoff is first detected.
	public static let backoffEventType = "scan_backoff"

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	/// Outcome of one scheduler tick.
	public enum Decision: Equatable {
		/// Run the file scan now; `lastCompleted` is the newest completion
		/// known from the recent-scan window (nil when none is known).
		case runScan(lastCompleted: Date?)
		/// Interval not yet elapsed since the last completed scan.
		case notDue(nextIn: TimeInterval)
		/// Recent scans keep dying — skip until `retryIn` has passed.
		case backoff(
			consecutiveIncomplete: Int,
			retryIn: TimeInterval,
			shouldAlert: Bool
		)
	}

	// ============================================================================
	public init() {}

	// ============================================================================
	/// Decides what the scheduler should do on this tick.
	///
	/// - Parameters:
	///   - recentScans: The newest scans, newest first — at least
	///     `incompleteScanThreshold` rows when available.
	///   - lastBackoffEvent: The newest `scan_backoff` event, or nil. Callers may
	///     pass nil without querying when `recentScans` cannot trigger backoff.
	///   - now: The current time.
	///   - fileScanInterval: Minimum seconds between file scans.
	public func decide(
		recentScans: [ScanResult],
		lastBackoffEvent: ScanEvent?,
		now: Date,
		fileScanInterval: TimeInterval
	) -> Decision {
		guard Self.hasReachedIncompleteThreshold(recentScans) else {
			return decideByLastCompletion(
				recentScans: recentScans,
				now: now,
				fileScanInterval: fileScanInterval
			)
		}

		let newestStartedAt = recentScans[0].startedAt
		let elapsed = now.timeIntervalSince(newestStartedAt)
		if elapsed >= fileScanInterval {
			return .runScan(lastCompleted: nil)
		}

		let hasAlertedForThisEpisode = lastBackoffEvent.map { $0.timestamp >= newestStartedAt } ?? false
		return .backoff(
			consecutiveIncomplete: Self.incompleteScanThreshold,
			retryIn: fileScanInterval - elapsed,
			shouldAlert: !hasAlertedForThisEpisode
		)
	}

	// ============================================================================
	/// True when the newest `incompleteScanThreshold` scans all never completed —
	/// the only case in which the caller needs to look up the last backoff event.
	public static func hasReachedIncompleteThreshold(
		_ recentScans: [ScanResult]
	) -> Bool {
		guard recentScans.count >= incompleteScanThreshold else {
			return false
		}
		return recentScans.prefix(incompleteScanThreshold).allSatisfy { $0.completedAt == nil }
	}

	// ============================================================================
	/// The pre-backoff rule: due once `fileScanInterval` has elapsed since the
	/// newest scan's completion (never completed counts as infinitely long ago).
	private func decideByLastCompletion(
		recentScans: [ScanResult],
		now: Date,
		fileScanInterval: TimeInterval
	) -> Decision {
		let lastCompleted = recentScans.first?.completedAt
		let elapsed = now.timeIntervalSince(lastCompleted ?? .distantPast)
		guard elapsed < fileScanInterval else {
			return .runScan(lastCompleted: lastCompleted)
		}
		return .notDue(nextIn: fileScanInterval - elapsed)
	}
}
