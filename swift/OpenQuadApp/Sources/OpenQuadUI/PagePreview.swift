// The negative on its page, as it will print: the paper, its margins (dashed) and the
// negative where it lands. Drag the negative to move it; it stays inside the margins.

import OpenQuadCore
import SwiftUI

struct PagePreview: View {
    @Bindable var model: AppModel
    let image: CGImage
    /// Where the negative was when the drag began (inches from the paper's left and top).
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let layout = model.pageLayout {
                let (paperWidth, paperHeight) = layout.paper
                // Points per inch: the whole page in view, with room round it for the shadow and
                // below it for the caption.
                let scale = max(0.1, min((geometry.size.width - 48) / paperWidth, (geometry.size.height - 96) / paperHeight))
                let negative = layout.negative
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.white)
                        .shadow(radius: 4)
                    Rectangle()
                        .strokeBorder(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: (paperWidth - 2 * layout.margin) * scale, height: (paperHeight - 2 * layout.margin) * scale)
                        .offset(x: layout.margin * scale, y: layout.margin * scale)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: negative.width * scale, height: negative.height * scale)
                        .offset(x: negative.minX * scale, y: negative.minY * scale)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let start = dragStart ?? negative.origin
                                if dragStart == nil { dragStart = start }
                                model.setPlacement((start.x + drag.translation.width / scale,
                                                    start.y + drag.translation.height / scale))
                            }
                            .onEnded { _ in dragStart = nil })
                        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                        .accessibilityLabel("The negative, \(model.positionDescription)")
                }
                .frame(width: paperWidth * scale, height: paperHeight * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
