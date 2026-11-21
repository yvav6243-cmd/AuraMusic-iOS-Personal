import Foundation
import SwiftUI
import UIKit

@MainActor
public final class ArtworkCacheManager: ObservableObject {
    public static let shared = ArtworkCacheManager()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let paletteCache = NSCache<NSString, NSArray>()
    private let fileManager = FileManager.default
    private let diskDirectory: URL

    private init() {
        memoryCache.countLimit = 250
        memoryCache.totalCostLimit = 64 * 1024 * 1024

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDirectory = caches.appendingPathComponent("AuraArtworkCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public func image(for url: URL) async -> UIImage? {
        let key = NSString(string: url.absoluteString)
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        if url.isFileURL {
            if let data = try? Data(contentsOf: url),
               let localImg = UIImage(data: data) {
                memoryCache.setObject(localImg, forKey: key)
                return localImg
            }
            return nil
        }

        let diskURL = diskFileURL(for: url)
        if fileManager.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL),
           let diskImage = UIImage(data: data) {
            memoryCache.setObject(diskImage, forKey: key)
            return diskImage
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let downloaded = UIImage(data: data) else {
                return nil
            }
            memoryCache.setObject(downloaded, forKey: key)
            try? data.write(to: diskURL, options: .atomic)
            return downloaded
        } catch {
            return nil
        }
    }

    /// Extracts dominant vibrant palette colors from album artwork for the Apple Music animated mesh background
    public func dominantColors(for url: URL?) async -> [Color] {
        let defaultPalette: [Color] = [
            Color(red: 0.98, green: 0.14, blue: 0.23),
            Color(red: 0.42, green: 0.09, blue: 0.38),
            Color(red: 0.12, green: 0.08, blue: 0.22),
            Color(red: 0.06, green: 0.06, blue: 0.10)
        ]
        guard let url else { return defaultPalette }
        let key = NSString(string: url.absoluteString)
        if let cachedArray = paletteCache.object(forKey: key) as? [UIColor] {
            return cachedArray.map(Color.init(uiColor:))
        }

        guard let uiImage = await image(for: url),
              let cgImage = uiImage.cgImage else {
            return defaultPalette
        }

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
            return defaultPalette
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        let quadrants: [(Int, Int)] = [(3, 3), (12, 4), (4, 12), (12, 12)]
        var extractedUIColors: [UIColor] = []
        for (qx, qy) in quadrants {
            let idx = (qy * sampleSize + qx) * 4
            let r = CGFloat(rawData[idx]) / 255.0
            let g = CGFloat(rawData[idx + 1]) / 255.0
            let b = CGFloat(rawData[idx + 2]) / 255.0
            let uiColor = UIColor(red: max(r, 0.08), green: max(g, 0.06), blue: max(b, 0.12), alpha: 1.0)
            extractedUIColors.append(uiColor)
        }

        paletteCache.setObject(extractedUIColors as NSArray, forKey: key)
        return extractedUIColors.map(Color.init(uiColor:))
    }

    public func clearCache() {
        memoryCache.removeAllObjects()
        paletteCache.removeAllObjects()
        try? fileManager.removeItem(at: diskDirectory)
        try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public func currentDiskCacheBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: diskDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
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
