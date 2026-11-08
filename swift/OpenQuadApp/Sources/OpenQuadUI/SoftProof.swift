// Soft-proofing a colour print on screen: the photo is converted into a printer and paper
// ICC profile (relative colorimetric, as ColorSync prints by default), so colours the paper
// can't hold show as they will print; the screen then shows that through its own profile.
// It changes only the preview: the print itself is colour-managed by macOS.

import ColorSync
import CoreGraphics
import Foundation

/// A printer and paper (output) ICC profile found on this Mac.
public struct ProofProfile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public var id: URL { url }
}

public enum SoftProof {
    /// Where macOS and printer drivers keep ICC profiles.
    public static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/ColorSync/Profiles"),
                URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: "/Library/Printers")]
    }

    /// The output (printer) profiles in `folders` and below, by name.
    public static func profiles(in folders: [URL] = folders) -> [ProofProfile] {
        var found: [URL: ProofProfile] = [:]
        for folder in folders {
            guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
                guard isOutputProfile(url) else { continue }
                let resolved = url.resolvingSymlinksInPath()
                found[resolved] = ProofProfile(url: resolved, name: name(of: resolved))
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// An ICC profile of class "prtr" (output) for RGB or CMYK: one a print can be proofed with.
    static func isOutputProfile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        let space = header.subdata(in: 16..<20), kind = header.subdata(in: 12..<16)
        return kind == Data("prtr".utf8) && (space == Data("RGB ".utf8) || space == Data("CMYK".utf8))
    }

    /// The profile's own description (as ColorSync shows it), else its file name.
    static func name(of url: URL) -> String {
        if let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
           let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?,
           !description.isEmpty {
            return description
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The image as it will print on the profile's printer and paper, or nil if the profile
    /// can't be used.
    public static func proof(_ image: CGImage, with profile: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: profile), let space = CGColorSpace(iccData: data as CFData) else { return nil }
        let alpha: CGImageAlphaInfo
        switch space.model {
        case .rgb: alpha = .noneSkipLast
        case .cmyk: alpha = .none
        default: return nil
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: alpha.rawValue) else { return nil }
        context.setRenderingIntent(.relativeColorimetric)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
