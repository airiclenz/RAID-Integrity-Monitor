import Foundation
import Darwin

// ---------------------------------------------------------------------------
// MARK: - ChunkedFileReader
// ---------------------------------------------------------------------------

/// Streams a file through a single reusable buffer using POSIX `open`/`read`/
/// `close`. No `FileHandle` and no `Data` are involved, so no autoreleased
/// chunk objects accumulate while a large file is being consumed.
enum ChunkedFileReader {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	/// Alignment of the reusable chunk buffer.
	private static let bufferAlignment = 16

	// ============================================================================
	/// Reads the file at `url` sequentially and calls `body` once per chunk with
	/// a view into the reusable buffer and the file's total size from `fstat`.
	///
	/// - A short read (`0 < n < chunkSize`) is delivered as an `n`-byte chunk and
	///   is not treated as end-of-file; only a zero-length read ends the loop.
	/// - `EINTR` during `read` is retried transparently.
	/// - `open`/`fstat`/`read` failures throw `AppError.fileAccess`; errors thrown
	///   by `body` propagate unchanged.
	/// - The chunk pointer is only valid for the duration of the `body` call.
	///
	/// - Returns: The total file size in bytes as reported by `fstat`.
	@discardableResult
	static func forEachChunk(
		of url: URL,
		chunkSize: Int,
		body: (_ chunk: UnsafeRawBufferPointer, _ totalSize: Int64) throws -> Void
	) throws -> Int64 {
		precondition(chunkSize > 0, "chunkSize must be positive")

		let fileDescriptor = try openForReading(path: url.path)
		defer { Darwin.close(fileDescriptor) }

		let totalSize = try fileSize(of: fileDescriptor, path: url.path)

		let buffer = UnsafeMutableRawBufferPointer.allocate(
			byteCount: chunkSize,
			alignment: bufferAlignment
		)
		defer { buffer.deallocate() }

		while true {
			let bytesRead = try readChunk(
				from: fileDescriptor,
				into: buffer,
				path: url.path
			)
			if bytesRead == 0 {
				break
			}
			let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<bytesRead])
			try body(chunk, totalSize)
		}

		return totalSize
	}

	// ============================================================================
	/// Opens `path` read-only and returns its file descriptor.
	private static func openForReading(
		path: String
	) throws -> Int32 {
		let fileDescriptor = Darwin.open(path, O_RDONLY)
		guard fileDescriptor >= 0 else {
			throw makeFileAccessError(path: path, errorNumber: errno)
		}
		return fileDescriptor
	}

	// ============================================================================
	/// Returns the size of the open file via `fstat`.
	private static func fileSize(
		of fileDescriptor: Int32,
		path: String
	) throws -> Int64 {
		var fileStatus = stat()
		guard fstat(fileDescriptor, &fileStatus) == 0 else {
			throw makeFileAccessError(path: path, errorNumber: errno)
		}
		return Int64(fileStatus.st_size)
	}

	// ============================================================================
	/// Reads up to `buffer.count` bytes into `buffer`, retrying on `EINTR`.
	/// Returns the number of bytes read; `0` means end-of-file.
	private static func readChunk(
		from fileDescriptor: Int32,
		into buffer: UnsafeMutableRawBufferPointer,
		path: String
	) throws -> Int {
		while true {
			let bytesRead = Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
			if bytesRead >= 0 {
				return bytesRead
			}
			if errno == EINTR {
				continue
			}
			throw makeFileAccessError(path: path, errorNumber: errno)
		}
	}

	// ============================================================================
	/// Wraps a POSIX `errno` value in `AppError.fileAccess` for `path`.
	private static func makeFileAccessError(
		path: String,
		errorNumber: Int32
	) -> AppError {
		let underlying = NSError(
			domain: NSPOSIXErrorDomain,
			code: Int(errorNumber)
		)
		return AppError.fileAccess(path: path, underlying: underlying)
	}
}
