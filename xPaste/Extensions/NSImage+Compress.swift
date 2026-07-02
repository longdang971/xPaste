import AppKit

extension NSImage {
    func compressedJPEGData(maxBytes: Int) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        var quality: Double = 0.85
        while quality > 0.09 {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               data.count <= maxBytes {
                return data
            }
            quality -= 0.25
        }
        return nil
    }
}
