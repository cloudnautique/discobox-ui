import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Writes an executable fixture through a close-on-exec descriptor. Tests run
/// in parallel and spawn children; a child forked while this file is open for
/// writing must not keep it open, or exec'ing the fixture fails with ETXTBSY.
func writeExecutable(_ text: String, to url: URL, mode: mode_t = 0o700) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let bytes = Array(text.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
    _ = fchmod(fd, mode)
}
