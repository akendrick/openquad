// The contact sheet window: choose up to 16 photos, arrange them as thumbnails on one
// sheet (black or white, whole or cropped, with names and a greyscale wedge if wanted),
// then use the sheet as the photo to print, as an inkjet print or a digital negative.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ContactSheetModel {
    public struct Entry: Identifiable {
        public let id = UUID()
        public let url: URL
        /// Greyscale, shrunk to at most `longestSide` pixels (plenty for a thumbnail).
        public let photo: Photo
    }

    nonisolated static let longestSide = 2400
    static let noRoom = "No room for these photos on a sheet this small."

    public private(set) var entries: [Entry] = []
    public var layout = SheetLayout()
    public var landscape = false
    public var busy = false
    public var error: String?
    public private(set) var preview: CGImage?
    /// The printable room (width, height) in inches, portrait: the Print tab's page.
    public private(set) var room: (Double, Double)
    /// The Negative tab's room (inside its safe edge and outline), if different.
    public private(set) var negativeRoom: (Double, Double)?
    let folder: URL
    private var previewToken = 0

    public var units: LengthUnit

    static func portrait(_ room: (Double, Double)) -> (Double, Double) { (min(room.0, room.1), max(room.0, room.1)) }

    public init(room: (Double, Double), units: LengthUnit = .inches, folder: URL) {
        self.room = Self.portrait(room)
        self.units = units
        self.folder = folder
        applySize()
    }

    /// The sheet's size in inches, turned for landscape.
    public var size: (Double, Double) { size(for: .print) }

    /// The sheet's size for the Print or Negative tab's page.
    public func size(for role: TabRole) -> (Double, Double) {
        let room = role == .negative ? negativeRoom ?? room : room
        return landscape ? (room.1, room.0) : room
    }

    /// The Print and Negative tabs' pages, as they are now.
    public func setRooms(print: (Double, Double), negative: (Double, Double)) {
        let (print, negative) = (Self.portrait(print), Self.portrait(negative))
        guard print != room || negative != negativeRoom ?? room else { return }
        (room, negativeRoom) = (print, negative)
        applySize()
    }

    func applySize() {
        (layout.width, layout.height) = size
        refresh()
    }

    public func setLandscape(_ on: Bool) {
        landscape = on
        applySize()
    }

    public func update(_ change: (inout SheetLayout) -> Void) {
        change(&layout)
        refresh()
    }

    public var canAdd: Bool { entries.count + queue.count < ContactSheet.maxPhotos }

    /// Photos being opened: how many are done, of how many, since when.
    public struct Loading: Equatable {
        public var done: Int
        public var total: Int
        public let started: Date
        /// The file being opened now.
        public var current: String

        /// Seconds left, from the time per photo so far (nil until one is done).
        public func secondsLeft(now: Date = Date()) -> Double? {
            guard done > 0 else { return nil }
            return now.timeIntervalSince(started) / Double(done) * Double(total - done)
        }

        /// "Opening frame-03.tif (3 of 12) · about 8 s left".
        public func description(now: Date = Date()) -> String {
            var text = "Opening \(current) (\(done + 1) of \(total))"
            if let left = secondsLeft(now: now) {
                text += left < 60 ? " · about \(max(1, Int(left.rounded()))) s left"
                    : " · about \(Int((left / 60).rounded())) min left"
            }
            return text
        }
    }

    public private(set) var loading: Loading?
    private var queue: [URL] = []

    /// Add photos (up to 16 in all), opened one at a time in the background; each shows on
    /// the sheet as soon as it is ready.
    public func add(_ urls: [URL]) {
        let room = ContactSheet.maxPhotos - entries.count - queue.count
        let chosen = Array(urls.prefix(max(0, room)))
        if urls.count > room { error = "A contact sheet takes up to \(ContactSheet.maxPhotos) photos; the rest were left out." }
        guard !chosen.isEmpty else { return }
        queue += chosen
        if loading != nil {  // already opening: these join the queue
            loading?.total += chosen.count
            return
        }
        loading = Loading(done: 0, total: queue.count, started: Date(), current: queue[0].lastPathComponent)
        busy = true
        Task {
            while !queue.isEmpty {
                let url = queue.removeFirst()
                loading?.current = url.lastPathComponent
                let result = await Task.detached(priority: .userInitiated) { Result { try Self.shrunk(Photos.load(url)) } }.value
                switch result {
                case .success(let photo): entries.append(Entry(url: url, photo: photo))
                case .failure(let failure): error = "Couldn't open \(url.lastPathComponent): \(failure)"
                }
                loading?.done += 1
                refresh()
            }
            loading = nil
            busy = false
        }
    }

    nonisolated static func shrunk(_ photo: Photo) -> Photo {
        let long = max(photo.width, photo.height)
        guard long > longestSide else { return photo }
        let width = max(1, photo.width * longestSide / long), height = max(1, photo.height * longestSide / long)
        var small = photo
        small.pixels = ContactSheet.resize(photo.pixels, photoWidth: photo.width, region: (0, 0, photo.width, photo.height),
                                           size: (width, height))
        (small.width, small.height) = (width, height)
        return small
    }

    public func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        refresh()
    }

    public func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        refresh()
    }

    var photos: [([UInt16], Int, Int)] { entries.map { ($0.photo.pixels, $0.photo.width, $0.photo.height) } }
    var names: [String] { entries.map(\.url.lastPathComponent) }

    /// Redraw the preview (at screen resolution, off the main thread).
    func refresh() {
        previewToken += 1
        let token = previewToken, photos = photos, names = names, layout = layout
        guard !photos.isEmpty else {
            preview = nil
            return
        }
        let dpi = 900 / max(layout.width, layout.height)
        Task {
            let sheet = await Task.detached(priority: .userInitiated) {
                try? ContactSheet.make(photos, names: names, layout: layout, dpi: dpi)
            }.value
            guard token == previewToken else { return }
            preview = sheet.flatMap { Self.greyImage($0.pixels, width: $0.width, height: $0.height) }
            if sheet == nil {
                error = Self.noRoom
            } else if error == Self.noRoom {
                error = nil  // there's room again
            }
        }
    }

    nonisolated static func greyImage(_ pixels: [UInt16], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels.map { UInt8($0 >> 8) }) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Make the full sheet at 300 ppi for the Print or Negative tab's page, save it as a
    /// 16-bit TIFF in OpenQuad's contact sheets folder, and hand its file to `done`.
    public func make(dpi: Double = 300, for role: TabRole = .print, done: @escaping (URL) -> Void) {
        var sized = layout
        (sized.width, sized.height) = size(for: role)
        let photos = photos, names = names, landscape = landscape, layout = sized
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("contact-sheet-\(format.string(from: Date())).tif")
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    var sheet = try ContactSheet.make(photos, names: names, layout: layout, dpi: dpi)
                    if landscape {  // turned to stand up on the portrait page, like any landscape print
                        sheet = (ContactSheet.turnedLeft(sheet.pixels, width: sheet.width, height: sheet.height),
                                 sheet.height, sheet.width)
                    }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ImageFiles.saveGrey(url, GreyImage(width: sheet.width, height: sheet.height, pixels: sheet.pixels,
                                                           dpi: (dpi, dpi)))
                    return url
                }
            }.value
            busy = false
            switch result {
            case .success(let url): done(url)
            case .failure(let failure): error = "Couldn't make the sheet: \(failure)"
            }
        }
    }
}

public struct ContactSheetView: View {
    @Bindable var model: ContactSheetModel
    /// Hands the made sheet to the Print or Negative tab.
    let use: (URL, TabRole) -> Void
    /// Closes the window it is in; nil inside a tab (no Close button).
    let close: (() -> Void)?

    public init(model: ContactSheetModel, use: @escaping (URL, TabRole) -> Void, close: (() -> Void)? = nil) {
        self.model = model
        self.use = use
        self.close = close
    }

    public var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(radius: 4)
                        .padding(24)
                } else {
                    ContentUnavailableView("Add photos to begin", systemImage: "square.grid.3x3",
                                           description: Text("Up to \(ContactSheet.maxPhotos) photos, arranged on one sheet."))
                }
            }
            .frame(minWidth: 360)
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Form {
                Section("Photos (\(model.entries.count) of \(ContactSheet.maxPhotos))") {
                    Button("Add Photos…", action: addPhotos)
                        .disabled(!model.canAdd)
                    List {
                        ForEach(model.entries) { entry in
                            HStack {
                                Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    model.remove(entry)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from the sheet")
                            }
                        }
                        .onMove { model.move(from: $0, to: $1) }
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    Text("Drag to reorder, or drop photos on the sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Sheet") {
                    Picker("Orientation", selection: Binding(get: { model.landscape }, set: { model.setLandscape($0) })) {
                        Text("Portrait").tag(false)
                        Text("Landscape").tag(true)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Size", value: "\(model.units.size(model.size.0, model.size.1))")
                    Picker("Background", selection: Binding(get: { model.layout.background },
                                                            set: { value in model.update { $0.background = value } })) {
                        Text("Black").tag(SheetLayout.Background.black)
                        Text("White").tag(SheetLayout.Background.white)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Crop photos to fill their cells", isOn: Binding(get: { model.layout.crop },
                                                                           set: { value in model.update { $0.crop = value } }))
                    Toggle("File names", isOn: Binding(get: { model.layout.labels },
                                                       set: { value in model.update { $0.labels = value } }))
                    Toggle("Greyscale step wedge", isOn: Binding(get: { model.layout.wedge },
                                                                 set: { value in model.update { $0.wedge = value } }))
                    LengthStepper(title: "Space between", inches: model.layout.gap, range: 0...1, inchStep: 0.05, mmStep: 1,
                                  units: model.units) { value in model.update { $0.gap = value } }
                    Text("The sheet fills the Print or Negative tab's page, inside its margins (and the safe edge and "
                         + "outline, for a negative); a landscape sheet is turned to fit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            if let loading = model.loading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(loading.done), total: Double(max(loading.total, 1)))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(loading.description(now: context.date))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding([.horizontal, .top])
            }
            HStack {
                if model.busy && model.loading == nil { ProgressView().controlSize(.small) }
                Spacer()
                if let close { Button("Cancel", action: close) }
                Button("Make a Negative") { make(for: .negative) }
                    .disabled(model.entries.isEmpty || model.busy)
                    .help("Make the sheet for the Negative tab's page and open it there")
                Button("Print It") { make(for: .print) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.entries.isEmpty || model.busy)
                    .help("Make the sheet for the Print tab's page and open it there")
            }
            .padding()
        }
    }

    private func make(for role: TabRole) {
        model.make(for: role) { url in
            use(url, role)
            close?()
        }
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}
