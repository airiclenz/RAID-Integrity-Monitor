import Foundation
import Darwin

// ---------------------------------------------------------------------------
// MARK: - ResidentMemory
// ---------------------------------------------------------------------------

/// Test support for memory-growth assertions: reads the current process's
/// resident set size and creates large sparse files cheaply.
enum ResidentMemory {

	// ============================================================================
	/// Returns the resident set size of the current process in bytes, as
	/// reported by `task_info(MACH_TASK_BASIC_INFO)`.
	static func currentBytes() -> UInt64 {
		var info = mach_task_basic_info()
		var count = mach_msg_type_number_t(
			MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
		)
		let result = withUnsafeMutablePointer(to: &info) { infoPointer in
			infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
				task_info(
					mach_task_self_,
					task_flavor_t(MACH_TASK_BASIC_INFO),
					reboundPointer,
					&count
				)
			}
		}
		guard result == KERN_SUCCESS else {
			return 0
		}
		return UInt64(info.resident_size)
	}

	// ============================================================================
	/// Creates a sparse file of `byteCount` bytes at `url`. The file is created
	/// first (an `O_CREAT` open) and then extended with `ftruncate`, so no data
	/// blocks are written.
	static func makeSparseFile(
		at url: URL,
		byteCount: Int
	) throws {
		let fileDescriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
		guard fileDescriptor >= 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		defer { Darwin.close(fileDescriptor) }

		guard ftruncate(fileDescriptor, off_t(byteCount)) == 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
	}
}
