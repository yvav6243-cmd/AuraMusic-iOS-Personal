import Foundation
import SwiftUI
import UIKit

public final class ArtworkCacheManager: ObservableObject, @unchecked Sendable {
    public static let shared = ArtworkCacheManager()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let paletteCache = NSCache<NSString, NSArray>()
    private let diskDirectory: URL

    private static let defaultPalette: [Color] = [
        Color(red: 0.98, green: 0.14, blue: 0.23),
        Color(red: 0.42, green: 0.09, blue: 0.38),
        Color(red: 0.12, green: 0.08, blue: 0.22),
        Color(red: 0.06, green: 0.06, blue: 0.10)
    ]

    private init() {
        memoryCache.countLimit = 300
        memoryCache.totalCostLimit = 96 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDirectory = caches.appendingPathComponent("AuraArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Instant O(1) main-thread-safe memory cache hit (pre-decoded GPU bitmap) so cells render on frame 0 with zero flicker
    public func cachedMemoryImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memoryCache.object(forKey: NSString(string: url.absoluteString))
    }

    /// Instant O(1) cached dominant color palette for the full-screen Apple Music mesh background
    public func cachedDominantColors(for url: URL?) -> [Color]? {
        guard let url else { return nil }
        let key = NSString(string: url.absoluteString)
        guard let cachedArray = paletteCache.object(forKey: key) as? [UIColor] else {
            return nil
        }
        return cachedArray.map(Color.init(uiColor:))
    }

    public func image(for url: URL) async -> UIImage? {
        let key = NSString(string: url.absoluteString)
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        let diskURL = diskFileURL(for: url)
        let cache = self.memoryCache

        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if url.isFileURL {
                guard let data = try? Data(contentsOf: url),
                      let rawImg = UIImage(data: data) else {
                    return nil
                }
                let decoded = rawImg.preparingForDisplay() ?? rawImg
                cache.setObject(decoded, forKey: key)
                return decoded
            }

            if FileManager.default.fileExists(atPath: diskURL.path),
               let data = try? Data(contentsOf: diskURL),
               let rawImg = UIImage(data: data) {
                let decoded = rawImg.preparingForDisplay() ?? rawImg
                cache.setObject(decoded, forKey: key)
                return decoded
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let rawImg = UIImage(data: data) else {
                    return nil
                }
                let decoded = rawImg.preparingForDisplay() ?? rawImg
                cache.setObject(decoded, forKey: key)
                try? data.write(to: diskURL, options: .atomic)
                return decoded
            } catch {
                return nil
            }
        }.value
    }

    /// Extracts dominant vibrant palette colors off the main thread for the Apple Music animated mesh background
    public func dominantColors(for url: URL?) async -> [Color] {
        guard let url else { return Self.defaultPalette }
        let key = NSString(string: url.absoluteString)
        if let cachedArray = paletteCache.object(forKey: key) as? [UIColor] {
            return cachedArray.map(Color.init(uiColor:))
        }

        guard let uiImage = await image(for: url),
              let cgImage = uiImage.cgImage else {
            return Self.defaultPalette
        }

        let pCache = self.paletteCache
        let extractedUIColors: [UIColor] = await Task.detached(priority: .utility) { () -> [UIColor] in
            let sampleSize = 16
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var rawData = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
            guard let context = CGContext(
                data: &rawData,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: sampleSize * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return []
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

            let quadrants: [(Int, Int)] = [(3, 3), (12, 4), (4, 12), (12, 12)]
            var result: [UIColor] = []
            for (qx, qy) in quadrants {
                let idx = (qy * sampleSize + qx) * 4
                let r = CGFloat(rawData[idx]) / 255.0
                let g = CGFloat(rawData[idx + 1]) / 255.0
                let b = CGFloat(rawData[idx + 2]) / 255.0
                result.append(UIColor(red: max(r, 0.08), green: max(g, 0.06), blue: max(b, 0.12), alpha: 1.0))
            }
            pCache.setObject(result as NSArray, forKey: key)
            return result
        }.value

        if extractedUIColors.count == 4 {
            return extractedUIColors.map(Color.init(uiColor:))
        }
        return Self.defaultPalette
    }

    public func clearCache() {
        memoryCache.removeAllObjects()
        paletteCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public func currentDiskCacheBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: diskDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func diskFileURL(for url: URL) -> URL {
        let safeName = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .prefix(80)
        return diskDirectory.appendingPathComponent(String(safeName) + ".img")
    }
}
