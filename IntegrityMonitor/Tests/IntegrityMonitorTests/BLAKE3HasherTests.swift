import XCTest
@testable import IntegrityMonitor
import Foundation

final class BLAKE3HasherTests: XCTestCase {

	private var tempDir: URL!

	override func setUp() {
		super.setUp()
		tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("BLAKE3HasherTests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: tempDir)
		super.tearDown()
	}

	// BLAKE3 of empty input: af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
	func testHash_emptyFile() throws {
		let file = tempDir.appendingPathComponent("empty.txt")
		try Data().write(to: file)

		let hasher = BLAKE3Hasher()
		let digest = try hasher.hash(fileAt: file)
		XCTAssertEqual(digest, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
	}

	// BLAKE3 of "hello\n"
	func testHash_knownContent() throws {
		let file = tempDir.appendingPathComponent("hello.txt")
		try "hello\n".data(using: .utf8)!.write(to: file)

		let hasher = BLAKE3Hasher()
		let digest = try hasher.hash(fileAt: file)
		XCTAssertEqual(digest, "8e4c7c1b99dbfd50e7a95185fead5ee1448fa904a2fdd778eaf5f2dbfd629a99")
	}

	func testHash_deterministicForSameContent() throws {
		let file = tempDir.appendingPathComponent("test.bin")
		let data = Data(repeating: 0xAB, count: 1024)
		try data.write(to: file)

		let hasher = BLAKE3Hasher()
		let d1 = try hasher.hash(fileAt: file)
		let d2 = try hasher.hash(fileAt: file)
		XCTAssertEqual(d1, d2)
	}

	func testHash_differentForDifferentContent() throws {
		let file1 = tempDir.appendingPathComponent("a.bin")
		let file2 = tempDir.appendingPathComponent("b.bin")
		try Data(repeating: 0xAA, count: 512).write(to: file1)
		try Data(repeating: 0xBB, count: 512).write(to: file2)

		let hasher = BLAKE3Hasher()
		let d1 = try hasher.hash(fileAt: file1)
		let d2 = try hasher.hash(fileAt: file2)
		XCTAssertNotEqual(d1, d2)
	}

	func testHash_multiChunkFile() throws {
		// Write a file larger than the 4MB chunk size to exercise the streaming path
		let file = tempDir.appendingPathComponent("large.bin")
		let data = Data(repeating: 0x42, count: 5 * 4 * 1024 * 1024 + 100)
		try data.write(to: file)

		let hasher = BLAKE3Hasher()
		let digest = try hasher.hash(fileAt: file)
		XCTAssertEqual(digest.count, 64)  // 256 bits = 32 bytes = 64 hex chars
	}

	func testHash_outputIsHex() throws {
		let file = tempDir.appendingPathComponent("hex.txt")
		try "test".data(using: .utf8)!.write(to: file)

		let hasher = BLAKE3Hasher()
		let digest = try hasher.hash(fileAt: file)
		XCTAssertEqual(digest.count, 64)
		XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
	}

	func testHash_throwsOnMissingFile() {
		let missing = tempDir.appendingPathComponent("does-not-exist.txt")
		let hasher = BLAKE3Hasher()
		XCTAssertThrowsError(try hasher.hash(fileAt: missing))
	}

	func testHasherFactory_blake3() throws {
		let hasher = try HasherFactory.make(for: "blake3")
		XCTAssertEqual(hasher.algorithmName, "blake3")
	}

	func testAlgorithmName() {
		let hasher = BLAKE3Hasher()
		XCTAssertEqual(hasher.algorithmName, "blake3")
	}

	// ============================================================================
	/// Regression guard for the autorelease leak: hashing a 512 MiB file must not
	/// grow resident memory by anything close to the file size.
	func testHash_largeFileDoesNotRetainChunks() throws {
		let file = tempDir.appendingPathComponent("sparse-512mib.bin")
		let byteCount = 512 * 1024 * 1024
		try ResidentMemory.makeSparseFile(at: file, byteCount: byteCount)

		let hasher = BLAKE3Hasher()
		let before = ResidentMemory.currentBytes()
		let digest = try hasher.hash(fileAt: file)
		let after = ResidentMemory.currentBytes()

		XCTAssertEqual(digest.count, 64)
		guard after >= before else {
			return
		}
		XCTAssertLessThan(after &- before, UInt64(64 * 1024 * 1024))
	}

	// ============================================================================
	/// Progress is reported once per chunk with a monotonically increasing byte
	/// count and the fstat total size.
	func testHash_progressReportsMonotonicAndTotal() throws {
		let file = tempDir.appendingPathComponent("progress-10mib.bin")
		let mebibyte = 1024 * 1024
		try Data(repeating: 0x5A, count: 10 * mebibyte).write(to: file)

		let recorder = ProgressRecorder()
		let hasher = BLAKE3Hasher(chunkSize: 4 * mebibyte)
		_ = try hasher.hash(fileAt: file) { processed, total in
			recorder.record(processed: processed, total: total)
		}

		let expected: [[Int64]] = [
			[Int64(4 * mebibyte), Int64(10 * mebibyte)],
			[Int64(8 * mebibyte), Int64(10 * mebibyte)],
			[Int64(10 * mebibyte), Int64(10 * mebibyte)]
		]
		XCTAssertEqual(recorder.calls, expected)
	}
}

// ---------------------------------------------------------------------------
// MARK: - ProgressRecorder
// ---------------------------------------------------------------------------

/// Thread-safe collector for `HashProgressHandler` invocations.
private final class ProgressRecorder: @unchecked Sendable {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let lock = NSLock()
	private var storedCalls: [[Int64]] = []

	var calls: [[Int64]] {
		lock.lock()
		defer { lock.unlock() }
		return storedCalls
	}

	// ============================================================================
	func record(
		processed: Int64,
		total: Int64
	) {
		lock.lock()
		defer { lock.unlock() }
		storedCalls.append([processed, total])
	}
}
