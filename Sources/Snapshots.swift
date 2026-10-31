import AppKit
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

/// A still image (a saved snapshot or any picture dropped in the snapshots folder) as a frame source.
final class StillImageSource: FrameSource {
    let url: URL
    private var frame: SourceFrame?

    init(url: URL, device: MTLDevice) throws {
        self.url = url
        // Read the size from the header first: an image claiming an absurd size is refused before it is decoded.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= Int(UL_MAX_DIMENSION), h <= Int(UL_MAX_DIMENSION), w * h <= Int(UL_MAX_PIXELS) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        // Code values as stored (no sRGB decode): scopes measure the encoded signal, like Resolve's.
        let tex = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
            .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
        frame = SourceFrame(texture: tex, info: "\(tex.width)×\(tex.height) still")
    }

    var title: String { url.deletingPathExtension().lastPathComponent }
    var status: String { "snapshot" }

    func nextFrame() -> SourceFrame? {
        defer { frame = nil }
        return frame
    }
}

/// The snapshots folder: where captures are saved and where you can drop your own images.
final class SnapshotStore {
    static let shared = SnapshotStore()

    let folder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let folder = pictures.appendingPathComponent("Umbra Scope Snapshots", isDirectory: true)
        return folder
    }()

    /// Called on the main queue whenever files are added, renamed or removed in the folder.
    var onChange: (() -> Void)?
    private var watcher: DispatchSourceFileSystemObject?

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        startWatching()
    }

    /// Image files in the folder, newest first.
    func list() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .image)
        }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    /// Writes 16-bit RGBA pixels (top-down, 0..65535) as a 16-bit PNG and returns its URL.
    func save(pixels: [UInt16], width: Int, height: Int, label: String) throws -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        let safe = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // Two snapshots in the same second with the same label would overwrite each other: number the later ones.
        var url = folder.appendingPathComponent("\(stamp) \(safe).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stamp) \(safe) (\(n)).png")
            n += 1
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.itur_709),
              let img = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                                bytesPerRow: width * 8, space: space, bitmapInfo: info, provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Scopes", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not encode the snapshot"])
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Scopes", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
        }
        return url
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    private func startWatching() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                           queue: .main)
        src.setEventHandler { [weak self] in self?.onChange?() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}
