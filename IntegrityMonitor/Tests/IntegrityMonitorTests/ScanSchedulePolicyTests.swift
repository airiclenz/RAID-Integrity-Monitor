import XCTest
@testable import IntegrityMonitor
import Foundation

final class ScanSchedulePolicyTests: XCTestCase {

	private let hour: TimeInterval = 3600
	private let twentyFourHours: TimeInterval = 24 * 3600
	private let now = Date(timeIntervalSince1970: 1_000_000)
	private let policy = ScanSchedulePolicy()

	// ============================================================================
	private func makeScan(
		startedAgo: TimeInterval,
		completedAgo: TimeInterval? = nil
	) -> ScanResult {
		ScanResult(
			startedAt: now.addingTimeInterval(-startedAgo),
			completedAt: completedAgo.map { now.addingTimeInterval(-$0) }
		)
	}

	// ============================================================================
	private func makeIncompleteScans(
		count: Int,
		newestStartedAgo: TimeInterval
	) -> [ScanResult] {
		(0..<count).map { index in
			makeScan(startedAgo: newestStartedAgo + Double(index) * hour)
		}
	}

	// ============================================================================
	private func makeBackoffEvent(
		ago: TimeInterval
	) -> ScanEvent {
		ScanEvent(
			timestamp: now.addingTimeInterval(-ago),
			eventType: ScanSchedulePolicy.backoffEventType
		)
	}

	// ============================================================================
	func testDecide_emptyHistory_runsScan() {
		let decision = policy.decide(
			recentScans: [],
			lastBackoffEvent: nil,
			now: now,
			fileScanInterval: twentyFourHours
		)

		XCTAssertEqual(decision, .runScan(lastCompleted: nil))
	}

	// ============================================================================
	func testDecide_lastCompletedOneHourAgo_isNotDueForRemainingInterval() {
		let scans = [makeScan(startedAgo: 2 * hour, completedAgo: hour)]

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: nil,
			now: now,
			fileScanInterval: twentyFourHours
		)

		guard case .notDue(let nextIn) = decision else {
			return XCTFail("Expected .notDue, got \(decision)")
		}
		XCTAssertEqual(nextIn, 23 * hour, accuracy: 1)
	}

	// ============================================================================
	func testDecide_lastCompletedLongAgo_runsScanWithCompletionDate() {
		let scans = [makeScan(startedAgo: 26 * hour, completedAgo: 25 * hour)]

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: nil,
			now: now,
			fileScanInterval: twentyFourHours
		)

		XCTAssertEqual(decision, .runScan(lastCompleted: now.addingTimeInterval(-25 * hour)))
	}

	// ============================================================================
	func testDecide_twoIncompleteScans_runsScan() {
		let scans = makeIncompleteScans(count: 2, newestStartedAgo: 10 * 60)

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: nil,
			now: now,
			fileScanInterval: twentyFourHours
		)

		XCTAssertEqual(decision, .runScan(lastCompleted: nil))
	}

	// ============================================================================
	func testDecide_threeIncompleteScansNoEvent_backsOffAndAlerts() {
		let scans = makeIncompleteScans(count: 3, newestStartedAgo: 10 * 60)

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: nil,
			now: now,
			fileScanInterval: twentyFourHours
		)

		guard case .backoff(let consecutiveIncomplete, let retryIn, let shouldAlert) = decision else {
			return XCTFail("Expected .backoff, got \(decision)")
		}
		XCTAssertEqual(consecutiveIncomplete, 3)
		XCTAssertEqual(retryIn, twentyFourHours - 10 * 60, accuracy: 1)
		XCTAssertTrue(shouldAlert)
	}

	// ============================================================================
	func testDecide_threeIncompleteScansWithNewerBackoffEvent_backsOffWithoutAlert() {
		let scans = makeIncompleteScans(count: 3, newestStartedAgo: 10 * 60)
		let event = makeBackoffEvent(ago: 5 * 60)

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: event,
			now: now,
			fileScanInterval: twentyFourHours
		)

		guard case .backoff(_, _, let shouldAlert) = decision else {
			return XCTFail("Expected .backoff, got \(decision)")
		}
		XCTAssertFalse(shouldAlert)
	}

	// ============================================================================
	func testDecide_threeIncompleteScansWithOlderBackoffEvent_backsOffAndAlerts() {
		let scans = makeIncompleteScans(count: 3, newestStartedAgo: 10 * 60)
		let event = makeBackoffEvent(ago: 15 * 60)

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: event,
			now: now,
			fileScanInterval: twentyFourHours
		)

		guard case .backoff(_, _, let shouldAlert) = decision else {
			return XCTFail("Expected .backoff, got \(decision)")
		}
		XCTAssertTrue(shouldAlert)
	}

	// ============================================================================
	func testDecide_threeIncompleteScansNewestIntervalAgo_runsScan() {
		let scans = makeIncompleteScans(count: 3, newestStartedAgo: 25 * hour)

		let decision = policy.decide(
			recentScans: scans,
			lastBackoffEvent: nil,
			now: now,
			fileScanInterval: twentyFourHours
		)

		XCTAssertEqual(decision, .runScan(lastCompleted: nil))
	}

	// ============================================================================
	func testHasReachedIncompleteThreshold_onlyTrueForThreeIncompleteScans() {
		let threeIncomplete = makeIncompleteScans(count: 3, newestStartedAgo: hour)
		let twoIncomplete = makeIncompleteScans(count: 2, newestStartedAgo: hour)
		let oneCompleted = [makeScan(startedAgo: hour, completedAgo: 30 * 60)]
			+ makeIncompleteScans(count: 2, newestStartedAgo: 2 * hour)

		XCTAssertTrue(ScanSchedulePolicy.hasReachedIncompleteThreshold(threeIncomplete))
		XCTAssertFalse(ScanSchedulePolicy.hasReachedIncompleteThreshold(twoIncomplete))
		XCTAssertFalse(ScanSchedulePolicy.hasReachedIncompleteThreshold(oneCompleted))
	}
}
