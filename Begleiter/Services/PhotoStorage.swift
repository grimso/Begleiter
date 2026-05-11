import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// On-disk storage for Befund photos.
///
/// Layout: `Documents/photos/<entryId.uuidString>/<index>.jpg`
/// The directory is excluded from iCloud / iTunes backup so the spec's
/// "everything stays on the iPhone" guarantee is honoured.
enum PhotoStorage {

    enum StorageError: Error, LocalizedError {
        case encodingFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Bild konnte nicht als JPEG kodiert werden."
            case .writeFailed(let detail):
                return "Bild konnte nicht gespeichert werden: \(detail)"
            }
        }
    }

    /// Write `imageData` (raw bytes from PhotosPicker or UIImage→jpegData)
    /// to disk under the entry's directory. Returns the **basename** of
    /// the saved file (e.g. `<uuid>/0.jpg`) so it can be stored on
    /// `JournalEntry.rawPhotoFilenames` and re-resolved later via
    /// `storedURL(for:)`.
    static func saveJPEG(_ imageData: Data, entryId: UUID, index: Int) throws -> String {
        #if canImport(UIKit)
        guard let image = UIImage(data: imageData),
              let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw StorageError.encodingFailed
        }
        #else
        let jpeg = imageData
        #endif

        let dir = try entryDirectory(for: entryId, create: true)
        let filename = "\(index).jpg"
        let url = dir.appendingPathComponent(filename)
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        return "\(entryId.uuidString)/\(filename)"
    }

    /// Resolve a stored relative path (e.g. `<uuid>/0.jpg`) back to a
    /// full URL for display. Returns nil if the file is missing.
    static func storedURL(for relativePath: String) -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let url = docs.appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Per-entry directory. Creates `Documents/photos/` and excludes it
    /// from backup on first call.
    private static func entryDirectory(for entryId: UUID, create: Bool) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let root = docs.appendingPathComponent("photos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path), create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        let dir = root.appendingPathComponent(entryId.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), create {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
