import XCTest
@testable import IntegrityMonitor
import Foundation

final class ChunkedFileReaderTests: XCTestCase {

	private var tempDir: URL!

	override func setUp() {
		super.setUp()
		tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ChunkedFileReaderTests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: tempDir)
		super.tearDown()
	}

	// ============================================================================
	func testForEachChunk_emptyFile_neverCallsBodyAndReturnsZero() throws {
		let file = tempDir.appendingPathComponent("empty.bin")
		try Data().write(to: file)
		var bodyCallCount = 0

		let totalSize = try ChunkedFileReader.forEachChunk(of: file, chunkSize: 4096) { _, _ in
			bodyCallCount += 1
		}

		XCTAssertEqual(bodyCallCount, 0)
		XCTAssertEqual(totalSize, 0)
	}

	// ============================================================================
	func testForEachChunk_multiChunkFile_deliversFullAndShortChunksInOrder() throws {
		let file = tempDir.appendingPathComponent("ten-thousand.bin")
		let content = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
		try content.write(to: file)
		var chunkSizes: [Int] = []
		var reportedTotalSizes: [Int64] = []
		var concatenated = Data()

		let totalSize = try ChunkedFileReader.forEachChunk(of: file, chunkSize: 4096) { chunk, reportedTotal in
			chunkSizes.append(chunk.count)
			reportedTotalSizes.append(reportedTotal)
			concatenated.append(contentsOf: chunk)
		}

		XCTAssertEqual(chunkSizes, [4096, 4096, 1808])
		XCTAssertEqual(concatenated, content)
		XCTAssertEqual(totalSize, 10_000)
		XCTAssertEqual(reportedTotalSizes, [10_000, 10_000, 10_000])
	}

	// ============================================================================
	func testForEachChunk_missingFile_throwsFileAccess() {
		let missing = tempDir.appendingPathComponent("does-not-exist.bin")

		XCTAssertThrowsError(
			try ChunkedFileReader.forEachChunk(of: missing, chunkSize: 4096) { _, _ in }
		) { error in
			guard case AppError.fileAccess(let path, let underlying) = error else {
				return XCTFail("Expected AppError.fileAccess, got \(error)")
			}
			XCTAssertEqual(path, missing.path)
			XCTAssertEqual((underlying as NSError).domain, NSPOSIXErrorDomain)
			XCTAssertEqual((underlying as NSError).code, Int(ENOENT))
		}
	}

	// ============================================================================
	func testForEachChunk_bodyThrows_propagatesError() throws {
		struct BodyFailure: Error, Equatable {}
		let file = tempDir.appendingPathComponent("data.bin")
		try Data(repeating: 0xAB, count: 8192).write(to: file)
		var bodyCallCount = 0

		XCTAssertThrowsError(
			try ChunkedFileReader.forEachChunk(of: file, chunkSize: 4096) { _, _ in
				bodyCallCount += 1
				throw BodyFailure()
			}
		) { error in
			XCTAssertEqual(error as? BodyFailure, BodyFailure())
		}
		XCTAssertEqual(bodyCallCount, 1)
	}
}
