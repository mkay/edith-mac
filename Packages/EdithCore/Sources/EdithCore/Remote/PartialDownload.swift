import Foundation

/// Where a download is written until it is complete.
///
/// Writing straight to the destination would truncate it up front, so a
/// failed or cancelled re-download of a file that is open in a tab would
/// destroy the local copy the tab is working from.
enum PartialDownload {
    static func url(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).edith-part")
    }

    /// Puts the finished file in place of whatever was there.
    static func finish(_ part: URL, as destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: destination)
        }
    }
}
