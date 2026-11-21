import Foundation

// MARK: - Provider Protocol

public protocol MusicProviderProtocol: Sendable {
    var providerType: MusicProviderType { get }
    var isConfigured: Bool { get }

    func searchTracks(query: String, limit: Int) async throws -> [UniversalTrack]
    func searchAlbums(query: String, limit: Int) async throws -> [UniversalAlbum]
    func searchArtists(query: String, limit: Int) async throws -> [UniversalArtist]
    func fetchTopCharts(limit: Int) async throws -> [UniversalTrack]
    func resolvePlayableStreamURL(for track: UniversalTrack) async throws -> URL?
}

// MARK: - Intelligent Cross-Provider Song Matcher

public struct TrackMatchingEngine: Sendable {
    public init() {}

    /// Groups tracks across multiple providers that represent the same song
    /// using ISRC, normalized title, artist tokens, album similarity, and duration proximity.
    public func groupMatchingTracks(_ tracks: [UniversalTrack]) -> [TrackVariantGroup] {
        var groups: [TrackVariantGroup] = []

        for track in tracks {
            if let matchIndex = groups.firstIndex(where: { isSameSong(track, $0.primaryTrack) }) {
                var existing = groups[matchIndex]
                if !existing.variants.contains(where: { $0.id == track.id }) {
                    existing.variants.append(track)
                }
                // Upgrade primary track artwork/metadata if the new variant has higher completeness
                if existing.primaryTrack.artworkURL == nil, let art = track.artworkURL {
                    existing.primaryTrack.artworkURL = art
                }
                if existing.primaryTrack.isrc == nil, let isrc = track.isrc {
                    existing.primaryTrack.isrc = isrc
                }
                if existing.primaryTrack.duration <= 0 && track.duration > 0 {
                    existing.primaryTrack.duration = track.duration
                }
                groups[matchIndex] = existing
            } else {
                groups.append(TrackVariantGroup(primaryTrack: track, variants: [track]))
            }
        }

        return groups
    }

    /// Computes similarity score (0.0 ... 1.0) between a query track and a candidate track
    public func similarityScore(_ lhs: UniversalTrack, _ rhs: UniversalTrack) -> Double {
        if let isrcA = lhs.isrc?.uppercased(),
           let isrcB = rhs.isrc?.uppercased(),
           !isrcA.isEmpty,
           isrcA == isrcB {
            return 1.0
        }

        let normTitleA = Self.normalizeTitle(lhs.title)
        let normTitleB = Self.normalizeTitle(rhs.title)
        let titleSim = Self.tokenSimilarity(normTitleA, normTitleB)

        let normArtistA = Self.normalizeArtist(lhs.artist)
        let normArtistB = Self.normalizeArtist(rhs.artist)
        let artistSim = Self.tokenSimilarity(normArtistA, normArtistB)

        var score = (titleSim * 0.62) + (artistSim * 0.30)

        if lhs.duration > 0 && rhs.duration > 0 {
            let delta = abs(lhs.duration - rhs.duration)
            if delta <= 3.0 {
                score += 0.08
            } else if delta <= 8.0 {
                score += 0.04
            } else if delta > 35.0 {
                score -= 0.20
            }
        } else {
            score += 0.04
        }

        return min(max(score, 0.0), 1.0)
    }

    public func isSameSong(_ lhs: UniversalTrack, _ rhs: UniversalTrack) -> Bool {
        if let isrcA = lhs.isrc?.uppercased(),
           let isrcB = rhs.isrc?.uppercased(),
           !isrcA.isEmpty,
           isrcA == isrcB {
            return true
        }

        let normTitleA = Self.normalizeTitle(lhs.title)
        let normTitleB = Self.normalizeTitle(rhs.title)
        guard !normTitleA.isEmpty && !normTitleB.isEmpty else { return false }

        let titleSim = Self.tokenSimilarity(normTitleA, normTitleB)
        guard titleSim >= 0.78 else { return false }

        let normArtistA = Self.normalizeArtist(lhs.artist)
        let normArtistB = Self.normalizeArtist(rhs.artist)
        let artistSim = Self.tokenSimilarity(normArtistA, normArtistB)
        guard artistSim >= 0.55 else { return false }

        if lhs.duration > 0 && rhs.duration > 0 {
            let delta = abs(lhs.duration - rhs.duration)
            if delta > 20.0 && titleSim < 0.95 {
                return false
            }
        }

        return similarityScore(lhs, rhs) >= 0.76
    }

    // MARK: - String Normalization Helpers

    public static func normalizeTitle(_ raw: String) -> String {
        var text = raw.lowercased()
        let noisePatterns = [
            "\\(official\\s*(music\\s*)?video\\)",
            "\\[official\\s*(music\\s*)?video\\]",
            "\\(official\\s*audio\\)",
            "\\[official\\s*audio\\]",
            "\\(lyric\\s*video\\)",
            "\\[lyric\\s*video\\]",
            "\\(remastered[^)]*\\)",
            "\\[remastered[^\\]]*\\]",
            "\\(feat\\.?[^)]*\\)",
            "\\[feat\\.?[^\\]]*\\]",
            "\\(ft\\.?[^)]*\\)"
        ]
        for pattern in noisePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
            }
        }
        return cleanAlphanumeric(text)
    }

    public static func normalizeArtist(_ raw: String) -> String {
        var text = raw.lowercased()
        text = text.replacingOccurrences(of: " - topic", with: "")
        text = text.replacingOccurrences(of: "vevo", with: "")
        text = text.replacingOccurrences(of: "feat.", with: " ")
        text = text.replacingOccurrences(of: "ft.", with: " ")
        text = text.replacingOccurrences(of: "&", with: " ")
        return cleanAlphanumeric(text)
    }

    private static func cleanAlphanumeric(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = input.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }
        return String(filtered)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        if a.contains(b) || b.contains(a) {
            let shorter = Double(min(a.count, b.count))
            let longer = Double(max(a.count, b.count))
            return max(0.82, shorter / longer)
        }
        let tokensA = Set(a.split(separator: " ").map(String.init))
        let tokensB = Set(b.split(separator: " ").map(String.init))
        guard !tokensA.isEmpty && !tokensB.isEmpty else { return 0.0 }
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return Double(intersection) / Double(union)
    }
}
