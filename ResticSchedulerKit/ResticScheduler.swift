import Foundation

@objc public protocol ResticSchedulerProtocol {
    func progressDidUpdate(percentDone: Float64, bytesDone: UInt64, totalBytes: UInt64, secondsElapsed: UInt64, secondsRemaining: UInt64, filesDone: UInt64, totalFiles: UInt64, errorCount: UInt64)
    func backupDidEncounterPermissionDeniedItems(_ items: [String])
    func backupDidFinishCopying()
}
