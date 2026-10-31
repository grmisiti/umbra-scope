import Foundation
import Metal

/// One LUT file, filed under maker → camera (or log format) → profile.
struct LUTEntry: Hashable {
    var maker: String
    var camera: String
    var profile: String
    var url: URL

    /// Short name for titles: camera and profile ("Pocket 6K · Film to Video v4"), or just the profile when the
    /// camera adds nothing (utilities, own files).
    var displayName: String {
        maker == "Utilities" || maker == "My LUTs" || maker == "File" || camera.isEmpty || profile.hasPrefix(camera)
            ? profile : "\(camera) · \(profile)"
    }
}

/// Every LUT DaVinci Resolve ships (and the user's own, in the same folders), grouped for the LUT panel.
/// Folder names and file names are inconsistent across makers, so each maker has its own naming rule; anything
/// that is not a camera conversion goes under "Utilities", and the user's own folders under "My LUTs".
enum LUTLibrary {
    static let folders = [
        URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"),
    ]
    static let extensions: Set<String> = ["cube", "dat", "ilut", "olut"]

    /// Resolve's own maker folders, with the maker's display name.
    private static let makerFolders: [String: String] = [
        "Arri": "ARRI", "Blackmagic Design": "Blackmagic Design", "DJI": "DJI", "Sony": "Sony", "RED": "RED",
        "Panasonic": "Panasonic", "Olympus": "OM System / Olympus", "Leica": "Leica", "Samsung": "Samsung",
        "Astrodesign": "Astrodesign",
    ]
    /// Resolve's folders that are not camera conversions.
    private static let utilityFolders: Set<String> = ["VFX IO", "HDR ST 2084", "HDR Hybrid Log-Gamma", "DCI", "Film Looks", "ACES"]

    static func scan() -> [LUTEntry] {
        var out = [LUTEntry]()
        let fm = FileManager.default
        for root in folders {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where extensions.contains(url.pathExtension.lowercased()) {
                let parts = Array(url.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init))
                if let e = classify(parts, url: url) { out.append(e) }
            }
        }
        let order = { (e: LUTEntry) in (e.maker == "Utilities" ? 1 : e.maker == "My LUTs" ? 2 : 0, e.maker, e.camera, e.profile) }
        return out.sorted { order($0) < order($1) }
    }

    private static func classify(_ parts: [String], url: URL) -> LUTEntry? {
        let name = url.deletingPathExtension().lastPathComponent
        if parts.count == 1 {
            // Loose files in the LUT folder: Resolve's Canon / Sony 1D LUTs and a few utilities.
            if name.hasPrefix("Canon Log") { return LUTEntry(maker: "Canon", camera: "Canon Log", profile: name, url: url) }
            if let m = name.range(of: #"^Sony (SLog\d)"#, options: .regularExpression) {
                let log = String(name[m]).replacingOccurrences(of: "Sony SLog", with: "S-Log")
                return LUTEntry(maker: "Sony", camera: log, profile: name, url: url)
            }
            return LUTEntry(maker: "Utilities", camera: "General", profile: name, url: url)
        }
        let folder = parts[0]
        if utilityFolders.contains(folder) {
            return LUTEntry(maker: "Utilities", camera: folder, profile: name, url: url)
        }
        guard let maker = makerFolders[folder] else {
            // The user's own folders: top folder → first subfolder → file.
            let camera = parts.count > 2 ? parts[1] : "General"
            let rest = parts.count > 2 ? parts[2...].joined(separator: " / ") : parts.last!
            return LUTEntry(maker: "My LUTs", camera: parts.count > 2 ? "\(folder) · \(camera)" : folder,
                            profile: (rest as NSString).deletingPathExtension, url: url)
        }
        return LUTEntry(maker: maker, camera: camera(maker: maker, name: name), profile: profile(maker: maker, name: name), url: url)
    }

    /// Camera (or the log format it records) from a maker's file name.
    private static func camera(maker: String, name: String) -> String {
        func match(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern),
                  let m = r.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), m.numberOfRanges > 1,
                  let g = Range(m.range(at: 1), in: name) else { return nil }
            return String(name[g])
        }
        switch maker {
        case "Blackmagic Design":
            let cam = match(#"^Blackmagic (.+?) Film to"#) ?? "All cameras (Blackmagic Film)"
            return cam.isEmpty ? "All cameras (Blackmagic Film)" : cam
        case "DJI":
            let cam = match(#"^DJI_([A-Za-z]+\d*)_"#) ?? "DJI"
            // "Phantom4" -> "Phantom 4"; Zenmuse "X7" stays as is.
            return cam.replacingOccurrences(of: #"^Phantom(\d)"#, with: "Phantom $1", options: .regularExpression)
                .replacingOccurrences(of: #"^(X\d)$"#, with: "Zenmuse $1", options: .regularExpression)
        case "Sony": return name.hasPrefix("SLog3SGamut3.Cine") ? "S-Log3 / S-Gamut3.Cine" : "Sony"
        case "RED": return "Log3G10 / REDWideGamutRGB"
        case "ARRI": return "ALEXA (LogC)"
        case "Panasonic": return "V-Log"
        case "OM System / Olympus": return "OM-Log400"
        case "Leica": return "L-Log"
        case "Samsung": return "Samsung Log"
        case "Astrodesign": return "ALog"
        default: return maker
        }
    }

    /// Short profile name: what the LUT converts to.
    private static func profile(maker: String, name: String) -> String {
        switch maker {
        case "Blackmagic Design":
            if let r = name.range(of: "Film to ") { return "Film to " + name[r.upperBound...] }
            return name
        case "DJI":
            return name.split(separator: "_").dropFirst(2).joined(separator: " ").replacingOccurrences(of: "2", with: " to ")
        case "Sony":
            return name.replacingOccurrences(of: "SLog3SGamut3.CineTo", with: "to ")
        case "RED":
            return name.replacingOccurrences(of: "RWG_Log3G10_to_", with: "to ").replacingOccurrences(of: "_", with: " ")
        default: return name
        }
    }
}

/// A parsed LUT: an optional 1D shaper followed by an optional 3D cube, both on 0…1 code values after their input
/// ranges. Cube entries are stored red-fastest (the .cube order).
struct LUTData {
    var shaper: [SIMD3<Float>] = []
    var shaperRange = SIMD2<Float>(0, 1)
    var cube: [SIMD3<Float>] = []
    var cubeSize = 0
    var cubeRange = SIMD2<Float>(0, 1)

    enum ParseError: Error { case unreadable, badSize, wrongCount }

    static func load(_ url: URL) throws -> LUTData {
        // LUT files are text of a few MB at most; anything far larger is not a LUT.
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0, bytes < 64 << 20,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            throw ParseError.unreadable
        }
        switch url.pathExtension.lowercased() {
        case "dat": return try parseDat(text)
        case "ilut", "olut": return try parse1DIntegers(text)
        default: return try parseCube(text)
        }
    }

    /// Adobe / Resolve .cube: LUT_1D_SIZE and/or LUT_3D_SIZE, optional DOMAIN_* or LUT_*_INPUT_RANGE.
    private static func parseCube(_ text: String) throws -> LUTData {
        var d = LUTData()
        var size1 = 0, size3 = 0
        var values = [SIMD3<Float>]()
        var domainMin: Float = 0, domainMax: Float = 1
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let f = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let a = Float(f[0]) {
                guard f.count >= 3, let b = Float(f[1]), let c = Float(f[2]) else { continue }
                values.append(SIMD3(a, b, c))
                continue
            }
            switch f[0] {
            case "LUT_1D_SIZE": size1 = f.count > 1 ? Int(f[1]) ?? 0 : 0
            case "LUT_3D_SIZE": size3 = f.count > 1 ? Int(f[1]) ?? 0 : 0
            case "LUT_1D_INPUT_RANGE": if f.count > 2 { d.shaperRange = SIMD2(Float(f[1]) ?? 0, Float(f[2]) ?? 1) }
            case "LUT_3D_INPUT_RANGE": if f.count > 2 { d.cubeRange = SIMD2(Float(f[1]) ?? 0, Float(f[2]) ?? 1) }
            case "DOMAIN_MIN": if f.count > 1 { domainMin = Float(f[1]) ?? 0 }
            case "DOMAIN_MAX": if f.count > 1 { domainMax = Float(f[1]) ?? 1 }
            default: break
            }
        }
        guard size1 >= 0, size1 <= 16384, size3 == 0 || (size3 >= 2 && size3 <= 129), size1 + size3 > 0 else { throw ParseError.badSize }
        guard values.count == size1 + size3 * size3 * size3 else { throw ParseError.wrongCount }
        if domainMin != 0 || domainMax != 1 {
            if size3 > 0 { d.cubeRange = SIMD2(domainMin, domainMax) } else { d.shaperRange = SIMD2(domainMin, domainMax) }
        }
        d.shaper = Array(values[0..<size1])
        d.cube = Array(values[size1...])
        d.cubeSize = size3
        return d
    }

    /// Resolve / ARRI .dat: "3DLUTSIZE N" then N³ entries with blue varying fastest.
    private static func parseDat(_ text: String) throws -> LUTData {
        var n = 0
        var values = [SIMD3<Float>]()
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = f.first else { continue }
            if first == "3DLUTSIZE", f.count > 1 { n = Int(f[1]) ?? 0; continue }
            if f.count >= 3, let a = Float(f[0]), let b = Float(f[1]), let c = Float(f[2]) { values.append(SIMD3(a, b, c)) }
        }
        guard n >= 2, n <= 129 else { throw ParseError.badSize }
        guard values.count == n * n * n else { throw ParseError.wrongCount }
        var d = LUTData()
        d.cubeSize = n
        d.cube = [SIMD3<Float>](repeating: .zero, count: values.count)
        for r in 0..<n { for g in 0..<n { for b in 0..<n { d.cube[r + g * n + b * n * n] = values[b + g * n + r * n * n] } } }
        return d
    }

    /// Resolve .ilut / .olut: one line per input code (0…N−1), comma-separated output codes on the same scale.
    private static func parse1DIntegers(_ text: String) throws -> LUTData {
        var values = [SIMD3<Float>]()
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            if f.count >= 3 { values.append(SIMD3(f[0], f[1], f[2])) }
        }
        guard values.count >= 2, values.count <= 16384 else { throw ParseError.badSize }
        let scale = 1 / Float(values.count - 1)
        var d = LUTData()
        d.shaper = values.map { $0 * scale }
        return d
    }
}

/// A LUT uploaded to the GPU for the decode pass.
final class GPULUT {
    let entry: LUTEntry
    let shaper: MTLTexture?     // width = entries, height 1
    let cube: MTLTexture?       // size³
    let data: LUTData

    init(entry: LUTEntry, device: MTLDevice) throws {
        self.entry = entry
        data = try LUTData.load(entry.url)
        // 32-bit float keeps 10-bit precision near white; filterable on Apple GPUs that support it.
        let format: MTLPixelFormat = device.supports32BitFloatFiltering ? .rgba32Float : .rgba16Float
        func upload(_ values: [SIMD3<Float>], _ desc: MTLTextureDescriptor, bytesPerRow: Int, region: MTLRegion) -> MTLTexture? {
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            if format == .rgba32Float {
                var rgba = [Float](); rgba.reserveCapacity(values.count * 4)
                for v in values { rgba += [v.x, v.y, v.z, 1] }
                rgba.withUnsafeBytes { tex.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                                                   bytesPerRow: bytesPerRow * 16, bytesPerImage: bytesPerRow * 16 * region.size.height) }
            } else {
                var rgba = [Float16](); rgba.reserveCapacity(values.count * 4)
                for v in values { rgba += [Float16(v.x), Float16(v.y), Float16(v.z), 1] }
                rgba.withUnsafeBytes { tex.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                                                   bytesPerRow: bytesPerRow * 8, bytesPerImage: bytesPerRow * 8 * region.size.height) }
            }
            return tex
        }
        if data.shaper.isEmpty {
            shaper = nil
        } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: data.shaper.count, height: 1, mipmapped: false)
            d.usage = .shaderRead
            shaper = upload(data.shaper, d, bytesPerRow: data.shaper.count, region: MTLRegionMake2D(0, 0, data.shaper.count, 1))
        }
        if data.cubeSize > 0 {
            let n = data.cubeSize
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = format
            d.width = n; d.height = n; d.depth = n
            d.usage = .shaderRead
            cube = upload(data.cube, d, bytesPerRow: n, region: MTLRegionMake3D(0, 0, 0, n, n, n))
        } else {
            cube = nil
        }
    }
}
