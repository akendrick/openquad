// Printing through the standard macOS print panel. The image is laid out at its exact
// physical size (pixels / ppi inches), centred on the page, so the print matches the
// size OpenQuad reports; the printer, media and quality are chosen in the panel.

import AppKit
import OpenQuadCore

/// A view that draws one image filling its bounds, sized in points (1/72 in).
final class PrintImageView: NSView {
    let image: CGImage

    init(image: CGImage, widthInches: Double, heightInches: Double) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: widthInches * 72, height: heightInches * 72))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none  // the pixels are already final; don't smooth them
        context.draw(image, in: bounds)
    }
}

public enum NativePrint {
    /// The print operation for a rendered print: page set to the session's paper,
    /// image at its real size in the middle of the page.
    @MainActor
    public static func operation(for image: RGBImage, widthInches: Double, heightInches: Double,
                                 paper: String, title: String) -> NSPrintOperation? {
        guard let cgImage = image.cgImage(), let (paperWidth, paperHeight) = Paper.sizes[paper] else { return nil }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = NSSize(width: paperWidth * 72, height: paperHeight * 72)
        info.orientation = .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip  // never scale: the size is the point
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let view = PrintImageView(image: cgImage, widthInches: widthInches, heightInches: heightInches)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsCopies, .showsPaperSize, .showsPreview])
        return operation
    }
}
