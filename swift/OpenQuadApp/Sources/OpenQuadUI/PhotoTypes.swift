// The photo files the app opens: TIFF, PNG and JPEG, JPEG 2000 (read at full depth through
// OpenJPEG) and GIMP's XCF (merged by GIMP 3).

import UniformTypeIdentifiers

enum PhotoTypes {
    /// JPEG 2000 and XCF, by their usual file extensions (GIMP may not have declared XCF).
    static let extra: [UTType] = ["jp2", "j2k", "jpx", "jpf", "xcf"].compactMap { UTType(filenameExtension: $0) }
    /// Everything Open Photo… offers.
    static let all: [UTType] = [.tiff, .png, .jpeg] + extra
}
