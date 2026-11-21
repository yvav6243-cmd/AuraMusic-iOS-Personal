import Foundation
import SwiftUI
import WebKit

// MARK: - 1. Audius Open Hi-Fi Catalog Provider (Zero-Key Full Track Streaming & Legal Downloads)

public final class AudiusProvider: MusicProviderProtocol, @unchecked Sendable {
    public let providerType: MusicProviderType = .audius
    private let session: URLSession
    private var cachedEndpoint: String?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public var isConfigured: Bool { true }

    private func activeHost() async throws -> String {
        if let cachedEndpoint { return cachedEndpoint }
        let discoveryURL = URL(string: "https://api.audius.co")!
        let (data, _) = try await session.data(from: discoveryURL)
        let decoded = try JSONDecoder().decode(AudiusHostResponse.self, from: data)
        let safeHost = decoded.data.first { candidate in
            guard let url = URL(string: candidate),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty,
                  host != "localhost",
                  !host.hasPrefix("127."),
                  !host.hasPrefix("10."),
                  !host.hasPrefix("192.168.") else {
                return false
            }
            return true
        } ?? "https://discoveryprovider.audius.co"
        self.cachedEndpoint = safeHost
        return safeHost
    }

    public func searchTracks(query: String, limit: Int = 20) async throws -> [UniversalTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let host = try await activeHost()
        var components = URLComponents(string: "\(host)/v1/tracks/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "app_name", value: "AuraMusic")
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(AudiusTracksResponse.self, from: data)
        return decoded.data
            .filter { $0.is_streamable != false }
            .prefix(limit)
            .map { mapTrack($0, host: host) }
    }

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [UniversalAlbum] {
        let tracks = try await searchTracks(query: query, limit: limit * 2)
        return tracks.prefix(limit).map { track in
            UniversalAlbum(
                provider: .audius,
                providerAlbumID: track.providerTrackID,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                genre: track.genre,
                trackCount: 1,
                tracks: [track]
            )
        }
    }

    public func searchArtists(query: String, limit: Int = 10) async throws -> [UniversalArtist] {
        let tracks = try await searchTracks(query: query, limit: 20)
        var grouped: [String: [UniversalTrack]] = [:]
        for t in tracks {
            grouped[t.artist, default: []].append(t)
        }
        return grouped.prefix(limit).map { name, artistTracks in
            UniversalArtist(
                provider: .audius,
                providerArtistID: name.lowercased(),
                name: name,
                artworkURL: artistTracks.first?.artworkURL,
                genres: Array(Set(artistTracks.compactMap(\.genre))),
                topTracks: artistTracks
            )
        }
    }

    public func fetchTopCharts(limit: Int = 25) async throws -> [UniversalTrack] {
        let host = try await activeHost()
        var components = URLComponents(string: "\(host)/v1/tracks/trending")!
        components.queryItems = [URLQueryItem(name: "app_name", value: "AuraMusic")]
        guard let url = components.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(AudiusTracksResponse.self, from: data)
        return decoded.data
            .filter { $0.is_streamable != false }
            .prefix(limit)
            .map { mapTrack($0, host: host) }
    }

    public func resolvePlayableStreamURL(for track: UniversalTrack) async throws -> URL? {
        if let existing = track.streamURL { return existing }
        let host = try await activeHost()
        return URL(string: "\(host)/v1/tracks/\(track.providerTrackID)/stream?app_name=AuraMusic")
    }

    private func mapTrack(_ item: AudiusTracksResponse.TrackItem, host: String) -> UniversalTrack {
        let streamURL = URL(string: "\(host)/v1/tracks/\(item.id)/stream?app_name=AuraMusic")
        let artString = item.artwork?.x480 ?? item.artwork?.x150
        return UniversalTrack(
            provider: .audius,
            providerTrackID: item.id,
            title: item.title,
            artist: item.user.name,
            album: item.genre ?? "Audius Single",
            artworkURL: artString.flatMap(URL.init(string:)),
            duration: Double(item.duration ?? 0),
            genre: item.genre,
            streamURL: streamURL,
            isStreamable: true,
            isDownloadPermitted: true,
            audioQualityBadge: "320K HI-FI"
        )
    }
}

private struct AudiusHostResponse: Codable {
    var data: [String]
}

private struct AudiusTracksResponse: Codable {
    struct Artwork: Codable {
        var x150: String?
        var x480: String?
        enum CodingKeys: String, CodingKey {
            case x150 = "150x150"
            case x480 = "480x480"
        }
    }
    struct User: Codable {
        var name: String
    }
    struct TrackItem: Codable {
        var id: String
        var title: String
        var user: User
        var duration: Int?
        var genre: String?
        var artwork: Artwork?
        var is_streamable: Bool?
    }
    var data: [TrackItem]
}

// MARK: - 2. YouTube Music (Studio Audio Mode) & YouTube Official Data API v3 Provider

public final class YouTubeMusicProvider: MusicProviderProtocol, @unchecked Sendable {
    public let providerType: MusicProviderType
    private let session: URLSession

    public init(providerType: MusicProviderType = .youtubeMusic, session: URLSession = .shared) {
        self.providerType = providerType
        self.session = session
    }

    public var isConfigured: Bool {
        !(ProviderCredentialsStore.readKeychain(key: "aura.token.youtube") ?? "").isEmpty
    }

    public func searchTracks(query: String, limit: Int = 15) async throws -> [UniversalTrack] {
        // 1. Primary: Unlimited YouTube Music InnerTube catalog search (zero daily quota limit, authentic studio audio + 600x600 square covers)
        let preferVideos = (providerType == .youtube)
        var innerTubeResults = await searchYouTubeMusicInnerTube(query: query, limit: limit, videosOnly: preferVideos)
        if innerTubeResults.isEmpty && !preferVideos {
            innerTubeResults = await searchYouTubeMusicInnerTube(query: query, limit: limit, videosOnly: true)
        }
        if !innerTubeResults.isEmpty {
            return innerTubeResults
        }

        // 2. Fallback: Official YouTube Data API v3 search if InnerTube is unavailable
        guard let apiKey = ProviderCredentialsStore.readKeychain(key: "aura.token.youtube"),
              !apiKey.isEmpty else {
            return []
        }

        // For YouTube Music, query specifically for official studio audio / Topic tracks
        let searchQuery = providerType == .youtubeMusic
            ? "\(query) official audio"
            : query

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"), // Music category
            URLQueryItem(name: "maxResults", value: String(min(limit, 25))),
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(YouTubeSearchListResponse.self, from: data)

        let videoIDs = decoded.items.compactMap(\.id.videoId)
        let durationsByID = await fetchVideoDurations(videoIDs: videoIDs, apiKey: apiKey)

        let tracks = decoded.items.compactMap { item -> UniversalTrack? in
            guard let videoID = item.id.videoId else { return nil }
            let rawTitle = Self.decodeHTMLEntities(item.snippet.title)
            let cleanTitle = providerType == .youtubeMusic ? Self.cleanStudioTrackTitle(rawTitle) : rawTitle
            let rawChannel = Self.decodeHTMLEntities(item.snippet.channelTitle)
            let isTopicOrAudio = rawChannel.contains("- Topic") || rawTitle.localizedCaseInsensitiveContains("Audio") || rawTitle.localizedCaseInsensitiveContains("Lyrics")
            let channel = rawChannel
                .replacingOccurrences(of: " - Topic", with: "")
                .replacingOccurrences(of: "VEVO", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let deepLinkScheme = providerType == .youtubeMusic
                ? "youtubemusic://watch?v=\(videoID)"
                : "https://www.youtube.com/watch?v=\(videoID)"
            let thumb = item.snippet.thumbnails.high?.url ?? item.snippet.thumbnails.medium?.url
            let exactDuration = durationsByID[videoID] ?? 210

            return UniversalTrack(
                provider: providerType,
                providerTrackID: videoID,
                title: cleanTitle,
                artist: channel,
                album: isTopicOrAudio ? "YouTube Music Studio Audio" : (providerType == .youtubeMusic ? "YouTube Music" : "YouTube Video"),
                artworkURL: thumb.flatMap(URL.init(string:)),
                duration: exactDuration,
                externalDeepLink: URL(string: deepLinkScheme),
                isStreamable: true,
                isDownloadPermitted: true,
                audioQualityBadge: isTopicOrAudio ? "STUDIO AUDIO" : (providerType == .youtubeMusic ? "YT MUSIC" : "VIDEO")
            )
        }

        // Prioritize studio "- Topic" / Audio tracks over VEVO music videos for reliable playback
        if providerType == .youtubeMusic {
            return tracks.sorted { lhs, rhs in
                let lhsScore = (lhs.audioQualityBadge == "STUDIO AUDIO") ? 1 : 0
                let rhsScore = (rhs.audioQualityBadge == "STUDIO AUDIO") ? 1 : 0
                return lhsScore > rhsScore
            }
        }
        return tracks
    }

    /// Queries YouTube Music's native search endpoint directly (no daily API quota limit, returns studio songs + 600x600 artwork + exact durations)
    private func searchYouTubeMusicInnerTube(query: String, limit: Int, videosOnly: Bool) async -> [UniversalTrack] {
        guard let endpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            return []
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.timeoutInterval = 10

        // EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D = Songs filter, EgWKAQIQAWoKEAkQBRAKEAMQBA%3D%3D = Videos filter
        let filterParams = videosOnly
            ? "EgWKAQIQAWoKEAkQBRAKEAMQBA%3D%3D"
            : "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": "1.20250101.01.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "query": query,
            "params": filterParams
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return []
        }
        request.httpBody = bodyData

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = root["contents"] as? [String: Any],
              let tabbed = contents["tabbedSearchResultsRenderer"] as? [String: Any],
              let tabs = tabbed["tabs"] as? [[String: Any]] else {
            return []
        }

        var results: [UniversalTrack] = []
        var seenVideoIDs = Set<String>()

        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let tabContent = tabRenderer["content"] as? [String: Any],
                  let sectionList = tabContent["sectionListRenderer"] as? [String: Any],
                  let sections = sectionList["contents"] as? [[String: Any]] else {
                continue
            }

            for section in sections {
                guard let shelf = section["musicShelfRenderer"] as? [String: Any],
                      let items = shelf["contents"] as? [[String: Any]] else {
                    continue
                }

                for itemDict in items {
                    guard let renderer = itemDict["musicResponsiveListItemRenderer"] as? [String: Any] else {
                        continue
                    }
                    guard let videoID = Self.extractInnerTubeVideoID(from: renderer),
                          !videoID.isEmpty,
                          !seenVideoIDs.contains(videoID) else {
                        continue
                    }

                    guard let flexColumns = renderer["flexColumns"] as? [[String: Any]], !flexColumns.isEmpty else {
                        continue
                    }

                    let title = Self.extractFlexColumnText(flexColumns[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }

                    let subtitle = flexColumns.count > 1 ? Self.extractFlexColumnText(flexColumns[1]) : ""
                    let meta = Self.parseYouTubeMusicSubtitle(subtitle)

                    // Upgrade square Google thumbnail URL to 600x600 high resolution
                    var thumbURL: URL? = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
                    if let thumbObj = renderer["thumbnail"] as? [String: Any],
                       let musicThumb = thumbObj["musicThumbnailRenderer"] as? [String: Any],
                       let innerThumb = musicThumb["thumbnail"] as? [String: Any],
                       let thumbs = innerThumb["thumbnails"] as? [[String: Any]],
                       let lastThumbStr = thumbs.last?["url"] as? String {
                        let hiResStr = Self.upgradeGoogleThumbTo600(lastThumbStr)
                        thumbURL = URL(string: hiResStr) ?? URL(string: lastThumbStr)
                    }

                    let deepLinkScheme = providerType == .youtubeMusic
                        ? "youtubemusic://watch?v=\(videoID)"
                        : "https://www.youtube.com/watch?v=\(videoID)"

                    seenVideoIDs.insert(videoID)
                    results.append(
                        UniversalTrack(
                            provider: providerType,
                            providerTrackID: videoID,
                            title: videosOnly ? Self.cleanStudioTrackTitle(title) : title,
                            artist: meta.artist.isEmpty ? "YouTube Music" : meta.artist,
                            album: meta.album.isEmpty ? (videosOnly ? "YouTube Video" : "YouTube Music") : meta.album,
                            artworkURL: thumbURL,
                            duration: meta.duration > 0 ? meta.duration : 210,
                            externalDeepLink: URL(string: deepLinkScheme),
                            isStreamable: true,
                            isDownloadPermitted: true,
                            audioQualityBadge: videosOnly ? "VIDEO" : "STUDIO AUDIO"
                        )
                    )

                    if results.count >= limit {
                        return results
                    }
                }
            }
        }
        return results
    }

    private static func extractInnerTubeVideoID(from renderer: [String: Any]) -> String? {
        if let playlistData = renderer["playlistItemData"] as? [String: Any],
           let vid = playlistData["videoId"] as? String,
           !vid.isEmpty {
            return vid
        }
        if let overlay = renderer["overlay"] as? [String: Any],
           let thumbOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = thumbOverlay["content"] as? [String: Any],
           let playBtn = content["musicPlayButtonRenderer"] as? [String: Any],
           let nav = playBtn["playNavigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any],
           let vid = watch["videoId"] as? String,
           !vid.isEmpty {
            return vid
        }
        return nil
    }

    private static func extractFlexColumnText(_ col: [String: Any]) -> String {
        guard let renderer = col["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let textObj = renderer["text"] as? [String: Any],
              let runs = textObj["runs"] as? [[String: Any]] else {
            return ""
        }
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    private static func parseYouTubeMusicSubtitle(_ subtitle: String) -> (artist: String, album: String, duration: TimeInterval) {
        let parts = subtitle
            .components(separatedBy: " • ")
            .flatMap { $0.components(separatedBy: " · ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var duration: TimeInterval = 210
        var metadataParts: [String] = []

        for part in parts {
            if let parsedDur = parseColonDuration(part) {
                duration = parsedDur
                continue
            }
            let lower = part.lowercased()
            if lower == "song" || lower == "video" || lower == "single" || lower == "episode" ||
                lower.contains(" views") || lower.contains(" plays") {
                continue
            }
            metadataParts.append(part)
        }

        let artist = metadataParts.first ?? "YouTube Music"
        let album = metadataParts.count >= 2 ? metadataParts[1] : "YouTube Music"
        return (artist, album, duration)
    }

    private static func parseColonDuration(_ text: String) -> TimeInterval? {
        let comps = text.split(separator: ":").compactMap { Double($0) }
        guard comps.count == 2 || comps.count == 3 else { return nil }
        if comps.count == 2 {
            return comps[0] * 60 + comps[1]
        }
        return comps[0] * 3600 + comps[1] * 60 + comps[2]
    }

    private static func upgradeGoogleThumbTo600(_ urlString: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "=w\\d+-h\\d+") else {
            return urlString
        }
        let range = NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
        return regex.stringByReplacingMatches(in: urlString, range: range, withTemplate: "=w600-h600")
    }

    private func fetchVideoDurations(videoIDs: [String], apiKey: String) async -> [String: TimeInterval] {
        guard !videoIDs.isEmpty else { return [:] }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "id", value: videoIDs.prefix(25).joined(separator: ",")),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let decoded = try? JSONDecoder().decode(YouTubeVideoDetailsResponse.self, from: data) else {
            return [:]
        }
        var map: [String: TimeInterval] = [:]
        for item in decoded.items {
            map[item.id] = Self.parseISO8601Duration(item.contentDetails.duration)
        }
        return map
    }

    private static func parseISO8601Duration(_ iso: String) -> TimeInterval {
        // Parses e.g. "PT3M42S" or "PT1H2M10S"
        let pattern = "PT(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: iso, range: NSRange(iso.startIndex..<iso.endIndex, in: iso)) else {
            return 210
        }
        var total: TimeInterval = 0
        if let r = Range(match.range(at: 1), in: iso), let h = Double(iso[r]) { total += h * 3600 }
        if let r = Range(match.range(at: 2), in: iso), let m = Double(iso[r]) { total += m * 60 }
        if let r = Range(match.range(at: 3), in: iso), let s = Double(iso[r]) { total += s }
        return total > 0 ? total : 210
    }

    private static func cleanStudioTrackTitle(_ raw: String) -> String {
        var result = raw
        let suffixes = [
            "(Official Audio)", "[Official Audio]",
            "(Official Music Video)", "[Official Music Video]",
            "(Official Video)", "[Official Video]",
            "(Official Lyric Video)", "[Official Lyric Video]",
            "(Lyric Video)", "[Lyric Video]",
            "(Audio)", "[Audio]",
            "(Visualizer)", "[Visualizer]"
        ]
        for s in suffixes {
            result = result.replacingOccurrences(of: s, with: "", options: .caseInsensitive)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static let iosPlayerUserAgent = "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)"

    /// Extracts an 11-character YouTube video ID from any youtube.com, youtu.be, or music.youtube.com link
    public static func extractYouTubeVideoID(from rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains("youtu.be") || trimmed.lowercased().contains("youtube.com") else {
            return nil
        }
        if let components = URLComponents(string: trimmed) {
            if let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value,
               vParam.count >= 11 {
                return String(vParam.prefix(11))
            }
            let pathParts = components.path.split(separator: "/").map(String.init)
            if let host = components.host?.lowercased(), host.contains("youtu.be"), let first = pathParts.first, first.count >= 11 {
                return String(first.prefix(11))
            }
            if let idx = pathParts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" || $0 == "v" }),
               pathParts.count > idx + 1 {
                return String(pathParts[idx + 1].prefix(11))
            }
        }
        let pattern = "(?:v=|youtu\\.be/|embed/|shorts/)([A-Za-z0-9_-]{11})"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
           let r = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[r])
        }
        return nil
    }

    /// Resolves a pasted YouTube / YouTube Music URL into a full UniversalTrack with clean title, artist, cover, and lyrics compatibility
    public func resolveTrackFromYouTubeURL(_ rawURLString: String) async -> UniversalTrack? {
        guard let videoID = Self.extractYouTubeVideoID(from: rawURLString) else {
            return nil
        }
        let apiKey = ProviderCredentialsStore.readKeychain(key: "aura.token.youtube") ?? "AIzaSyCHoPSdrgYinPSDvIn1dbIFyWjnLdgJ8ww"

        var rawTitle = "YouTube Track"
        var rawChannel = "YouTube Music"
        var thumbURL: URL? = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        var durationSeconds: TimeInterval = 210

        // 1. Query official YouTube Data API v3 /videos endpoint for exact title, channel, and duration
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet,contentDetails"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if let url = components.url,
           let (data, _) = try? await session.data(from: url),
           let decoded = try? JSONDecoder().decode(YouTubeFullVideoListResponse.self, from: data),
           let item = decoded.items.first {
            rawTitle = Self.decodeHTMLEntities(item.snippet.title)
            rawChannel = Self.decodeHTMLEntities(item.snippet.channelTitle)
            if let hi = item.snippet.thumbnails.high?.url ?? item.snippet.thumbnails.medium?.url,
               let parsedThumb = URL(string: hi) {
                thumbURL = parsedThumb
            }
            if let isoDur = item.contentDetails?.duration {
                durationSeconds = Self.parseISO8601Duration(isoDur)
            }
        } else {
            // 2. Fallback to YouTube's official oEmbed metadata endpoint
            var oembed = URLComponents(string: "https://www.youtube.com/oembed")!
            oembed.queryItems = [
                URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
                URLQueryItem(name: "format", value: "json")
            ]
            if let oURL = oembed.url,
               let (oData, _) = try? await session.data(from: oURL),
               let oJSON = try? JSONSerialization.jsonObject(with: oData) as? [String: Any] {
                if let t = oJSON["title"] as? String { rawTitle = t }
                if let a = oJSON["author_name"] as? String { rawChannel = a }
                if let th = oJSON["thumbnail_url"] as? String, let u = URL(string: th) { thumbURL = u }
            }
        }

        let cleaned = LyricsService.extractCleanTitleAndArtist(
            rawTitle: Self.cleanStudioTrackTitle(rawTitle),
            rawArtist: rawChannel
        )

        var albumName = "YouTube Music"
        // Try upgrading to crisp 600x600 square default album cover from catalog metadata
        if let appleMatches = try? await AppleMusicProvider().searchTracks(query: "\(cleaned.title) \(cleaned.artist)", limit: 1),
           let match = appleMatches.first {
            if let sqArt = match.artworkURL {
                thumbURL = sqArt
            }
            if match.album != "Single" {
                albumName = match.album
            }
        }

        return UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: videoID,
            title: cleaned.title,
            artist: cleaned.artist,
            album: albumName,
            artworkURL: thumbURL,
            duration: durationSeconds,
            externalDeepLink: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
            isStreamable: true,
            isDownloadPermitted: true,
            audioQualityBadge: "YT MUSIC"
        )
    }

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [UniversalAlbum] { [] }
    public func searchArtists(query: String, limit: Int = 10) async throws -> [UniversalArtist] { [] }
    public func fetchTopCharts(limit: Int = 15) async throws -> [UniversalTrack] {
        try await searchTracks(query: "Top Music Hits 2026", limit: limit)
    }
    public func resolvePlayableStreamURL(for track: UniversalTrack) async throws -> URL? {
        if let direct = await resolveDirectYouTubeAudioStream(videoID: track.providerTrackID) {
            return direct.url
        }
        return track.externalDeepLink
    }

    /// Resolves a direct native audio/mp4 (AAC) stream URL for AVPlayer playback
    public func resolveDirectYouTubeAudioStream(videoID: String) async -> (url: URL, duration: TimeInterval)? {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.iosPlayerUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "20.03.02",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.2.1.22C161"
                ]
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(YouTubeIOSPlayerResponse.self, from: data)

            // Prefer audio/mp4 (AAC) adaptive stream for native AVPlayer
            let audioFormats = (decoded.streamingData?.adaptiveFormats ?? []).filter {
                $0.mimeType.lowercased().hasPrefix("audio/mp4") && $0.url != nil
            }
            let bestAudio = audioFormats.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
                ?? (decoded.streamingData?.adaptiveFormats ?? []).first(where: {
                    $0.mimeType.lowercased().hasPrefix("audio/") && $0.url != nil
                })

            if let format = bestAudio,
               let urlStr = format.url,
               let streamURL = URL(string: urlStr) {
                let durMs = Double(format.approxDurationMs ?? "") ?? 0
                let durSec = durMs > 0 ? (durMs / 1000.0) : Double(decoded.videoDetails?.lengthSeconds ?? "") ?? 0
                return (streamURL, durSec)
            }

            if let hlsStr = decoded.streamingData?.hlsManifestUrl,
               let hlsURL = URL(string: hlsStr) {
                let durSec = Double(decoded.videoDetails?.lengthSeconds ?? "") ?? 0
                return (hlsURL, durSec)
            }
        } catch {
            return nil
        }
        return nil
    }
}

private struct YouTubeIOSPlayerResponse: Codable {
    struct AdaptiveFormat: Codable {
        var url: String?
        var mimeType: String
        var bitrate: Int?
        var approxDurationMs: String?
    }
    struct StreamingData: Codable {
        var hlsManifestUrl: String?
        var adaptiveFormats: [AdaptiveFormat]?
    }
    struct VideoDetails: Codable {
        var lengthSeconds: String?
    }
    var streamingData: StreamingData?
    var videoDetails: VideoDetails?
}

private struct YouTubeSearchListResponse: Codable {
    struct VideoID: Codable {
        var videoId: String?
    }
    struct Thumb: Codable {
        var url: String?
    }
    struct Thumbnails: Codable {
        var medium: Thumb?
        var high: Thumb?
    }
    struct Snippet: Codable {
        var title: String
        var channelTitle: String
        var thumbnails: Thumbnails
    }
    struct Item: Codable {
        var id: VideoID
        var snippet: Snippet
    }
    var items: [Item]
}

private struct YouTubeVideoDetailsResponse: Codable {
    struct ContentDetails: Codable {
        var duration: String
    }
    struct Item: Codable {
        var id: String
        var contentDetails: ContentDetails
    }
    var items: [Item]
}

private struct YouTubeFullVideoListResponse: Codable {
    struct ContentDetails: Codable {
        var duration: String
    }
    struct Item: Codable {
        var id: String
        var snippet: YouTubeSearchListResponse.Snippet
        var contentDetails: ContentDetails?
    }
    var items: [Item]
}

// MARK: - Full-Length Mobile YouTube Music WebKit Audio/Video Engine Bridge

public struct AuthorizedYouTubeIFramePlayerView: UIViewRepresentable {
    public let videoID: String
    @ObservedObject var playerEngine: UniversalAudioPlayerEngine = .shared

    public init(videoID: String) {
        self.videoID = videoID
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(playerEngine: playerEngine)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 1. Early script at document start: lock unmuted autoplay, block background visibility pause, and intercept audio stream URLs
        let unmuteLockScriptSource = """
        (function() {
          try {
            var origMutedDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
            window._auraOrigMutedDesc = origMutedDesc;
            Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
              get: function() { return false; },
              set: function(v) {
                try {
                  this.removeAttribute('muted');
                  if (origMutedDesc && origMutedDesc.set) { origMutedDesc.set.call(this, false); }
                } catch(e) {}
              },
              configurable: true
            });
            Object.defineProperty(HTMLMediaElement.prototype, 'defaultMuted', {
              get: function() { return false; },
              set: function(v) {},
              configurable: true
            });
            Object.defineProperty(document, 'hidden', { get: function() { return false; }, configurable: true });
            Object.defineProperty(document, 'webkitHidden', { get: function() { return false; }, configurable: true });
            Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; }, configurable: true });
            Object.defineProperty(document, 'webkitVisibilityState', { get: function() { return 'visible'; }, configurable: true });
            document.hasFocus = function() { return true; };

            var bgEvents = ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'blur', 'mozvisibilitychange'];
            bgEvents.forEach(function(evt) {
              window.addEventListener(evt, function(e) { e.stopImmediatePropagation(); e.stopPropagation(); }, true);
              document.addEventListener(evt, function(e) { e.stopImmediatePropagation(); e.stopPropagation(); }, true);
            });

            var origPause = HTMLMediaElement.prototype.pause;
            window._auraOrigPause = origPause;
            HTMLMediaElement.prototype.pause = function() {
              var inBgProtect = Date.now() < (window._auraBgProtectUntil || 0);
              if (!inBgProtect || window._auraAllowPause === true || window._auraUserPaused === true || this.ended) {
                return origPause.apply(this, arguments);
              }
              var self = this;
              setTimeout(function() {
                if (!window._auraUserPaused && Date.now() < (window._auraBgProtectUntil || 0)) {
                  try { self.play(); } catch(e) {}
                }
              }, 25);
            };

            function reportCapturedAudioURL(rawUrl) {
              if (!rawUrl || typeof rawUrl !== 'string') return;
              if (rawUrl.indexOf('googlevideo.com/videoplayback') !== -1 &&
                  (rawUrl.indexOf('mime=audio') !== -1 || rawUrl.indexOf('mime%3Daudio') !== -1)) {
                var clean = rawUrl.replace(/&range=[^&]+/g, '').replace(/&rn=[^&]+/g, '').replace(/&rbuf=[^&]+/g, '');
                if (window._lastReportedAudioUrl !== clean && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.auraYT) {
                  window._lastReportedAudioUrl = clean;
                  window.webkit.messageHandlers.auraYT.postMessage({
                    type: 'audioStream',
                    audioURL: clean,
                    currentTime: 0,
                    duration: 0,
                    state: 1
                  });
                }
              }
            }

            var origFetch = window.fetch;
            if (origFetch) {
              window.fetch = function(input, init) {
                try {
                  var u = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
                  reportCapturedAudioURL(u);
                } catch(e) {}
                return origFetch.apply(this, arguments);
              };
            }

            var origXHROpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
              try { reportCapturedAudioURL(url); } catch(e) {}
              return origXHROpen.apply(this, arguments);
            };
          } catch(e) {}
        })();
        """
        let unmuteScript = WKUserScript(
            source: unmuteLockScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(unmuteScript)

        // 2. Main audio bridge at document end
        let bridgeScriptSource = """
        (function() {
          if (window._auraBridgeInstalled) return;
          window._auraBridgeInstalled = true;

          var style = document.createElement('style');
          style.innerHTML = `
            html, body, video {
              margin: 0 !important;
              padding: 0 !important;
              background: transparent !important;
              opacity: 0.001 !important;
              overflow: hidden !important;
              pointer-events: none !important;
            }
          `;
          if (document.head) {
            document.head.appendChild(style);
          } else {
            document.addEventListener('DOMContentLoaded', function() {
              if (document.head) document.head.appendChild(style);
            });
          }

          function forceUnmuteAndPlayIfNeeded(v, forceUnmute) {
            try {
              // Respect user pause strictly — never auto-resume when user paused in app or from Lock Screen / Control Center / AirPods
              if (window._auraUserPaused === true) return;
              v.setAttribute('playsinline', '');
              v.setAttribute('webkit-playsinline', '');
              var mp = document.getElementById('movie_player');
              var realMuted = (window._auraOrigMutedDesc && window._auraOrigMutedDesc.get)
                ? window._auraOrigMutedDesc.get.call(v)
                : false;
              var mpMuted = (mp && typeof mp.isMuted === 'function') ? mp.isMuted() : false;
              var unmuteBtn = document.querySelector('.ytp-unmute, button[aria-label*="Unmute"], button[aria-label*="unmute"], button[aria-label*="Включить звук"], button[aria-label*="включить звук"], button[aria-label*="Tap to unmute"]');

              if (forceUnmute || !v._auraUnmutedOnce || realMuted || mpMuted || v.hasAttribute('muted') || v.volume === 0 || unmuteBtn) {
                v._auraUnmutedOnce = true;
                v.muted = false;
                v.defaultMuted = false;
                v.removeAttribute('muted');
                if (window._auraOrigMutedDesc && window._auraOrigMutedDesc.set) {
                  window._auraOrigMutedDesc.set.call(v, false);
                }
                var targetVol = (window._auraTargetVol !== undefined) ? window._auraTargetVol : 100;
                if (v.volume === 0) v.volume = Math.max(0.05, targetVol / 100.0);
                if (mp) {
                  if (mp.unMute) mp.unMute();
                  if (mp.setVolume) mp.setVolume(targetVol);
                }
                if (unmuteBtn) { try { unmuteBtn.click(); } catch(e) {} }
              }

              // Start playback if not yet playing; once actively playing (!v.paused && currentTime > 0.15 && readyState >= 2), skip playVideo()/play() so audio never stutters
              if (!window._auraUserPaused && !v.ended) {
                var isActuallyPlaying = (!v.paused && v.currentTime > 0.15 && v.readyState >= 2);
                if (!isActuallyPlaying) {
                  v._auraStartAttempts = (v._auraStartAttempts || 0) + 1;
                  if (mp && mp.playVideo) { try { mp.playVideo(); } catch(e) {} }
                  try { v.play().catch(function(){}); } catch(e) {}
                  if (v.paused && v.currentTime === 0 && v._auraStartAttempts >= 4) {
                    var bigPlayBtn = document.querySelector('.ytp-large-play-button');
                    if (bigPlayBtn) { try { bigPlayBtn.click(); } catch(e) {} }
                  }
                }
              }
            } catch(e) {}
          }

          function postMessageToSwift(payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.auraYT) {
              window.webkit.messageHandlers.auraYT.postMessage(payload);
            }
          }

          window.auraControl = {
            play: function() {
              window._auraUserPaused = false;
              window._auraAllowPause = false;
              window._auraPendingUserResumeUntil = Date.now() + 2000;
              try { if (navigator.mediaSession) navigator.mediaSession.playbackState = 'playing'; } catch(e) {}
              var v = document.querySelector('video');
              if (v) {
                forceUnmuteAndPlayIfNeeded(v, true);
              }
            },
            pause: function() {
              window._auraUserPaused = true;
              window._auraAllowPause = true;
              window._auraBgProtectUntil = 0;
              window._auraPendingUserResumeUntil = 0;
              try { if (navigator.mediaSession) navigator.mediaSession.playbackState = 'paused'; } catch(e) {}
              var v = document.querySelector('video');
              if (v) {
                try {
                  if (window._auraOrigPause) { window._auraOrigPause.call(v); }
                  else { v.pause(); }
                } catch(e) {}
              }
              var mp = document.getElementById('movie_player');
              if (mp && mp.pauseVideo) { try { mp.pauseVideo(); } catch(e) {} }
              if (v) {
                postMessageToSwift({
                  type: 'tick',
                  currentTime: v.currentTime || 0,
                  duration: (isFinite(v.duration) && v.duration > 0) ? v.duration : 0,
                  state: 2,
                  userPaused: true,
                  userResumed: false
                });
              }
            },
            resume: function() {
              var wasPaused = (window._auraUserPaused === true);
              window._auraUserPaused = false;
              window._auraAllowPause = false;
              window._auraPendingUserResumeUntil = Date.now() + 2000;
              try { if (navigator.mediaSession) navigator.mediaSession.playbackState = 'playing'; } catch(e) {}
              var v = document.querySelector('video');
              if (v) {
                forceUnmuteAndPlayIfNeeded(v, wasPaused);
                if (v.paused && !v.ended) {
                  var mp = document.getElementById('movie_player');
                  if (mp && mp.playVideo) { try { mp.playVideo(); } catch(e) {} }
                  try { v.play().catch(function(){}); } catch(e) {}
                }
              }
            },
            enterBackgroundProtect: function(ms) {
              if (window._auraUserPaused === true) return;
              window._auraBgProtectUntil = Date.now() + (ms || 900);
              var v = document.querySelector('video');
              if (v && v.paused && !v.ended) {
                forceUnmuteAndPlayIfNeeded(v, false);
              }
            },
            seek: function(sec) {
              var v = document.querySelector('video');
              if (v) {
                v.currentTime = sec;
                if (!window._auraUserPaused && v.paused) {
                  forceUnmuteAndPlayIfNeeded(v, false);
                }
              }
            },
            setVolume: function(vol) {
              window._auraTargetVol = vol;
              var v = document.querySelector('video');
              if (v) {
                v.volume = Math.max(0.0, Math.min(1.0, vol / 100.0));
              }
              var mp = document.getElementById('movie_player');
              if (mp && mp.setVolume) { try { mp.setVolume(vol); } catch(e) {} }
            }
          };

          function installMediaSessionHandlers() {
            try {
              if (!navigator.mediaSession || !navigator.mediaSession.setActionHandler) return;
              navigator.mediaSession.setActionHandler('pause', function() {
                window._auraBgProtectUntil = 0;
                window.auraControl.pause();
                postMessageToSwift({ type: 'remotePause' });
              });
              navigator.mediaSession.setActionHandler('play', function() {
                // Notify Swift BEFORE resuming so Swift immediately clears isUserPaused and keeps background audio session active
                window._auraPendingUserResumeUntil = Date.now() + 2500;
                postMessageToSwift({ type: 'remotePlay' });
                window.auraControl.resume();
              });
              navigator.mediaSession.setActionHandler('nexttrack', function() {
                postMessageToSwift({ type: 'remoteNext' });
              });
              navigator.mediaSession.setActionHandler('previoustrack', function() {
                postMessageToSwift({ type: 'remotePrev' });
              });
            } catch(e) {}
          }
          installMediaSessionHandlers();

          function postCurrentVideoTick(v, extraFlags) {
            if (!v) return;
            var cur = v.currentTime || 0;
            var dur = v.duration || 0;
            var st = 1;
            if (v.ended) {
              st = 0;
            } else if (v.paused) {
              st = (!window._auraUserPaused && (cur <= 0.05 || v.readyState < 3)) ? 3 : 2;
            }
            var pendingResume = Date.now() < (window._auraPendingUserResumeUntil || 0);
            var payload = {
              type: 'tick',
              currentTime: cur,
              duration: (isFinite(dur) && dur > 0) ? dur : 0,
              state: st,
              userPaused: window._auraUserPaused === true,
              userResumed: pendingResume && st === 1
            };
            if (extraFlags) {
              if (extraFlags.userPaused !== undefined) payload.userPaused = extraFlags.userPaused;
              if (extraFlags.userResumed !== undefined) payload.userResumed = extraFlags.userResumed;
            }
            postMessageToSwift(payload);
          }

          var ticksWithoutVideo = 0;
          var mediaSessionTickCounter = 0;
          setInterval(function() {
            mediaSessionTickCounter++;
            if (mediaSessionTickCounter % 10 === 0) {
              installMediaSessionHandlers();
            }

            var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
            if (skipBtn) { try { skipBtn.click(); } catch(e) {} }

            var errBox = document.querySelector('.player-error-message-container, ytm-playability-error-supported-renderers');
            if (errBox && errBox.offsetParent !== null && errBox.innerText && errBox.innerText.trim().length > 3) {
              postMessageToSwift({ type: 'error', currentTime: 0, duration: 0, state: -99 });
              return;
            }

            var v = document.querySelector('video');
            if (!v) {
              ticksWithoutVideo++;
              if (ticksWithoutVideo > 40) {
                ticksWithoutVideo = 0;
                postMessageToSwift({ type: 'error', currentTime: 0, duration: 0, state: -99 });
              }
              return;
            }
            ticksWithoutVideo = 0;

            if (!v._auraListenersAttached) {
              v._auraListenersAttached = true;
              v.addEventListener('timeupdate', function() {
                if (!v.paused && v.currentTime > 0.25) { v._auraHasPlayedOnce = true; }
                postCurrentVideoTick(v);
              });
              v.addEventListener('play', function() {
                var wasUserPaused = (window._auraUserPaused === true);
                window._auraUserPaused = false;
                window._auraAllowPause = false;
                try { if (navigator.mediaSession) navigator.mediaSession.playbackState = 'playing'; } catch(e) {}
                if (wasUserPaused) {
                  window._auraPendingUserResumeUntil = Date.now() + 2500;
                  postMessageToSwift({ type: 'remotePlay' });
                  postCurrentVideoTick(v, { userPaused: false, userResumed: true });
                }
              });
              v.addEventListener('playing', function() {
                var wasUserPaused = (window._auraUserPaused === true) || (Date.now() < (window._auraPendingUserResumeUntil || 0));
                v._auraHasPlayedOnce = true;
                window._auraUserPaused = false;
                window._auraAllowPause = false;
                try { if (navigator.mediaSession) navigator.mediaSession.playbackState = 'playing'; } catch(e) {}
                postCurrentVideoTick(v, { userPaused: false, userResumed: wasUserPaused });
              });
              v.addEventListener('pause', function() {
                if (v.ended) {
                  postCurrentVideoTick(v);
                  return;
                }
                var inBgProtect = Date.now() < (window._auraBgProtectUntil || 0);
                if (inBgProtect && !window._auraUserPaused) {
                  // iOS tried to auto-pause right when minimizing the app — immediately keep playing smoothly
                  forceUnmuteAndPlayIfNeeded(v, false);
                  return;
                }
                if (v._auraHasPlayedOnce && v.currentTime > 0.25) {
                  // Genuine pause triggered from Lock Screen, Control Center, AirPods, or user tap — honor it and stay paused!
                  window._auraUserPaused = true;
                  window._auraAllowPause = true;
                  window._auraPendingUserResumeUntil = 0;
                  try { if (navigator.mediaSession) navigator.mediaSession.playbackState = 'paused'; } catch(e) {}
                  var mp = document.getElementById('movie_player');
                  if (mp && mp.pauseVideo) { try { mp.pauseVideo(); } catch(e) {} }
                  postCurrentVideoTick(v, { userPaused: true, userResumed: false });
                } else {
                  postCurrentVideoTick(v);
                }
              });
              v.addEventListener('ended', function() { postCurrentVideoTick(v); });
            }

            if (!v.paused && v.currentTime > 0.25) {
              v._auraHasPlayedOnce = true;
            }

            forceUnmuteAndPlayIfNeeded(v, false);
            postCurrentVideoTick(v);
          }, 180);
        })();
        """

        let userScript = WKUserScript(
            source: bridgeScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "auraYT")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        context.coordinator.webView = webView
        playerEngine.registerYouTubeWebView(webView)
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let safeVideoID = String(videoID.unicodeScalars.filter { allowed.contains($0) }.prefix(24))
        guard !safeVideoID.isEmpty else { return }

        if context.coordinator.loadedVideoID != safeVideoID {
            context.coordinator.loadedVideoID = safeVideoID
            playerEngine.registerYouTubeWebView(webView)
            if let watchURL = URL(string: "https://m.youtube.com/watch?v=\(safeVideoID)") {
                var request = URLRequest(url: watchURL)
                request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
                webView.load(request)
            }
        }
    }

    public final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var playerEngine: UniversalAudioPlayerEngine?
        weak var webView: WKWebView?
        var loadedVideoID: String?

        init(playerEngine: UniversalAudioPlayerEngine) {
            self.playerEngine = playerEngine
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            if let msgType = dict["type"] as? String {
                switch msgType {
                case "audioStream":
                    if let audioURLString = dict["audioURL"] as? String,
                       let audioURL = URL(string: audioURLString),
                       let vid = loadedVideoID {
                        Task { @MainActor in
                            self.playerEngine?.recordCapturedYouTubeAudioStreamURL(audioURL, forVideoID: vid)
                        }
                    }
                    return
                case "remotePause":
                    Task { @MainActor in self.playerEngine?.pause() }
                    return
                case "remotePlay":
                    Task { @MainActor in self.playerEngine?.resume() }
                    return
                case "remoteNext":
                    Task { @MainActor in self.playerEngine?.skipToNext() }
                    return
                case "remotePrev":
                    Task { @MainActor in self.playerEngine?.skipToPrevious() }
                    return
                default:
                    break
                }
            }
            let cur = (dict["currentTime"] as? Double) ?? 0
            let dur = (dict["duration"] as? Double) ?? 0
            let st = (dict["state"] as? Int) ?? -1
            let userPaused = (dict["userPaused"] as? Bool) ?? false
            let userResumed = (dict["userResumed"] as? Bool) ?? false
            Task { @MainActor in
                self.playerEngine?.handleYouTubePlayerEvent(
                    currentTime: cur,
                    duration: dur,
                    stateCode: st,
                    userPaused: userPaused,
                    userResumed: userResumed
                )
            }
        }
    }
}

// MARK: - 3. Official Spotify Web API Provider

public final class SpotifyProvider: MusicProviderProtocol, @unchecked Sendable {
    public let providerType: MusicProviderType = .spotify
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public var isConfigured: Bool {
        !(ProviderCredentialsStore.readKeychain(key: "aura.token.spotifyAccess") ?? "").isEmpty
    }

    public func searchTracks(query: String, limit: Int = 15) async throws -> [UniversalTrack] {
        guard let token = ProviderCredentialsStore.readKeychain(key: "aura.token.spotifyAccess"),
              !token.isEmpty else {
            return []
        }
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(min(limit, 25)))
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(SpotifySearchResponse.self, from: data)

        return decoded.tracks.items.map { item in
            let artistName = item.artists.map(\.name).joined(separator: ", ")
            let artURL = item.album.images.first.flatMap { URL(string: $0.url) }
            let previewURL = item.preview_url.flatMap(URL.init(string:))
            let deepLink = URL(string: "spotify:track:\(item.id)") ?? URL(string: "https://open.spotify.com/track/\(item.id)")
            return UniversalTrack(
                provider: .spotify,
                providerTrackID: item.id,
                title: item.name,
                artist: artistName,
                album: item.album.name,
                artworkURL: artURL,
                duration: Double(item.duration_ms) / 1000.0,
                isrc: item.external_ids?.isrc,
                explicit: item.explicit,
                streamURL: previewURL,
                previewURL: previewURL,
                externalDeepLink: deepLink,
                isStreamable: previewURL != nil,
                isDownloadPermitted: false,
                audioQualityBadge: previewURL != nil ? "SPOTIFY PREVIEW" : "SPOTIFY LINK"
            )
        }
    }

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [UniversalAlbum] { [] }
    public func searchArtists(query: String, limit: Int = 10) async throws -> [UniversalArtist] { [] }
    public func fetchTopCharts(limit: Int = 15) async throws -> [UniversalTrack] { [] }
    public func resolvePlayableStreamURL(for track: UniversalTrack) async throws -> URL? {
        track.previewURL
    }
}

private struct SpotifySearchResponse: Codable {
    struct Artist: Codable { var name: String }
    struct ImageItem: Codable { var url: String }
    struct Album: Codable {
        var name: String
        var images: [ImageItem]
    }
    struct ExternalIDs: Codable {
        var isrc: String?
    }
    struct TrackItem: Codable {
        var id: String
        var name: String
        var duration_ms: Int
        var explicit: Bool
        var preview_url: String?
        var artists: [Artist]
        var album: Album
        var external_ids: ExternalIDs?
    }
    struct TracksContainer: Codable {
        var items: [TrackItem]
    }
    var tracks: TracksContainer
}

// MARK: - 4. Official SoundCloud API Provider

public final class SoundCloudProvider: MusicProviderProtocol, @unchecked Sendable {
    public let providerType: MusicProviderType = .soundCloud
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public var isConfigured: Bool {
        !(ProviderCredentialsStore.readKeychain(key: "aura.token.soundcloud") ?? "").isEmpty
    }

    public func searchTracks(query: String, limit: Int = 15) async throws -> [UniversalTrack] {
        guard let token = ProviderCredentialsStore.readKeychain(key: "aura.token.soundcloud"),
              !token.isEmpty else {
            return []
        }

        var components = URLComponents(string: "https://api.soundcloud.com/tracks")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(limit, 25))),
            URLQueryItem(name: "access", value: "playable")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let items = try JSONDecoder().decode([SoundCloudTrackDTO].self, from: data)
        return items.map { item in
            let hiResArt = item.artwork_url?.replacingOccurrences(of: "-large", with: "-t500x500")
            let streamURL = item.stream_url.flatMap { URL(string: "\($0)?client_id=\(token)") }
            return UniversalTrack(
                provider: .soundCloud,
                providerTrackID: String(item.id),
                title: item.title,
                artist: item.user.username,
                album: item.genre ?? "SoundCloud",
                artworkURL: hiResArt.flatMap(URL.init(string:)),
                duration: Double(item.duration) / 1000.0,
                genre: item.genre,
                streamURL: streamURL,
                externalDeepLink: item.permalink_url.flatMap(URL.init(string:)),
                isStreamable: item.streamable ?? true,
                isDownloadPermitted: item.downloadable ?? false,
                audioQualityBadge: "SOUNDCLOUD"
            )
        }
    }

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [UniversalAlbum] { [] }
    public func searchArtists(query: String, limit: Int = 10) async throws -> [UniversalArtist] { [] }
    public func fetchTopCharts(limit: Int = 15) async throws -> [UniversalTrack] { [] }
    public func resolvePlayableStreamURL(for track: UniversalTrack) async throws -> URL? {
        track.streamURL
    }
}

private struct SoundCloudTrackDTO: Codable {
    struct User: Codable { var username: String }
    var id: Int
    var title: String
    var duration: Int
    var genre: String?
    var artwork_url: String?
    var stream_url: String?
    var permalink_url: String?
    var streamable: Bool?
    var downloadable: Bool?
    var user: User
}

// MARK: - 5. Live Internet Radio Provider (Curated Apple Music-Style Stations + Radio-Browser Directory)

public final class LiveRadioProvider: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static let featuredStations: [RadioStation] = [
        RadioStation(
            id: "somafm-groovesalad",
            name: "Aura 1 • Chill & Ambient",
            subtitle: "Downtempo Electronica & Warm Synths • Live 24/7",
            genre: "Electronic / Chill",
            streamURL: URL(string: "https://ice2.somafm.com/groovesalad-128-mp3")!,
            bitrateKbps: 128,
            countryCode: "US"
        ),
        RadioStation(
            id: "somafm-defcon",
            name: "Aura Club • Electronic Pulse",
            subtitle: "Future Beats, Synthwave & Night Drive",
            genre: "Electronic",
            streamURL: URL(string: "https://ice2.somafm.com/defcon-128-mp3")!,
            bitrateKbps: 128,
            countryCode: "US"
        ),
        RadioStation(
            id: "somafm-indiepop",
            name: "Aura Indie • Alternative & Pop",
            subtitle: "Fresh Indie Pop, Bedroom Pop & Classic Shoegaze",
            genre: "Indie Pop",
            streamURL: URL(string: "https://ice2.somafm.com/indiepop-128-mp3")!,
            bitrateKbps: 128,
            countryCode: "US"
        ),
        RadioStation(
            id: "somafm-lush",
            name: "Aura Vocal • Dream Pop & Acoustic",
            subtitle: "Mellow Female Vocals & Atmospheric Soul",
            genre: "Dream Pop",
            streamURL: URL(string: "https://ice2.somafm.com/lush-128-mp3")!,
            bitrateKbps: 128,
            countryCode: "US"
        ),
        RadioStation(
            id: "somafm-secretagent",
            name: "Aura Lounge • Jazz & Bossa Nova",
            subtitle: "Cool Vintage Lounge, Jazz Grooves & Film Soundtracks",
            genre: "Jazz / Lounge",
            streamURL: URL(string: "https://ice2.somafm.com/secretagent-128-mp3")!,
            bitrateKbps: 128,
            countryCode: "US"
        ),
        RadioStation(
            id: "somafm-vaporwaves",
            name: "Aura Tokyo • Vaporwave & Future Funk",
            subtitle: "City Pop, Synth Boogie & Lo-Fi Beats",
            genre: "City Pop / Lo-Fi",
            streamURL: URL(string: "https://ice2.somafm.com/vaporwaves-128-mp3")!,
            bitrateKbps: 128,
            countryCode: "JP"
        )
    ]

    public func searchDirectoryStations(tagOrName: String, limit: Int = 15) async throws -> [RadioStation] {
        var components = URLComponents(string: "https://de1.api.radio-browser.info/json/stations/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: tagOrName),
            URLQueryItem(name: "limit", value: String(min(limit, 25))),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let items = try JSONDecoder().decode([RadioBrowserStationDTO].self, from: data)
        return items.compactMap { dto -> RadioStation? in
            guard let stream = URL(string: dto.url_resolved),
                  dto.url_resolved.hasPrefix("https://") else {
                return nil
            }
            return RadioStation(
                id: dto.stationuuid,
                name: dto.name.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: dto.country.isEmpty ? "Global Internet Radio" : dto.country,
                genre: dto.tags.split(separator: ",").first.map(String.init)?.capitalized ?? "Radio",
                streamURL: stream,
                artworkURL: dto.favicon.flatMap(URL.init(string:)),
                bitrateKbps: max(dto.bitrate, 128),
                countryCode: dto.countrycode
            )
        }
    }
}

private struct RadioBrowserStationDTO: Codable {
    var stationuuid: String
    var name: String
    var url_resolved: String
    var favicon: String?
    var tags: String
    var country: String
    var countrycode: String
    var bitrate: Int
}
