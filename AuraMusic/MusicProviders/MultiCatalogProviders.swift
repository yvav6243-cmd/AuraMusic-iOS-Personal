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

        return decoded.items.compactMap { item -> UniversalTrack? in
            guard let videoID = item.id.videoId else { return nil }
            let rawTitle = Self.decodeHTMLEntities(item.snippet.title)
            let cleanTitle = providerType == .youtubeMusic ? Self.cleanStudioTrackTitle(rawTitle) : rawTitle
            let channel = Self.decodeHTMLEntities(item.snippet.channelTitle)
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
                album: providerType == .youtubeMusic ? "YouTube Music Audio" : "YouTube Video",
                artworkURL: thumb.flatMap(URL.init(string:)),
                duration: exactDuration,
                externalDeepLink: URL(string: deepLinkScheme),
                isStreamable: true,
                isDownloadPermitted: false,
                audioQualityBadge: providerType == .youtubeMusic ? "YT MUSIC AUDIO" : "VIDEO"
            )
        }
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

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [UniversalAlbum] { [] }
    public func searchArtists(query: String, limit: Int = 10) async throws -> [UniversalArtist] { [] }
    public func fetchTopCharts(limit: Int = 15) async throws -> [UniversalTrack] {
        try await searchTracks(query: "Top Music Hits", limit: limit)
    }
    public func resolvePlayableStreamURL(for track: UniversalTrack) async throws -> URL? {
        track.externalDeepLink
    }
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

// MARK: - Apple Music-Integrated YouTube IFrame JS Audio & Video Engine Bridge

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
        config.userContentController.add(context.coordinator, name: "auraYT")

        let webView = WKWebView(frame: .zero, configuration: config)
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

            let embedHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
              body, html { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
              #player { width: 100%; height: 100%; border: 0; }
            </style>
            </head>
            <body>
            <div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
              var ytPlayer = null;
              var timerId = null;
              function onYouTubeIframeAPIReady() {
                ytPlayer = new YT.Player('player', {
                  width: '100%',
                  height: '100%',
                  videoId: '\(safeVideoID)',
                  playerVars: {
                    'playsinline': 1,
                    'autoplay': 1,
                    'controls': 0,
                    'rel': 0,
                    'modestbranding': 1,
                    'fs': 0,
                    'iv_load_policy': 3
                  },
                  events: {
                    'onReady': function(e) {
                      e.target.playVideo();
                      startProgressTimer();
                    },
                    'onStateChange': function(e) {
                      postState(e.data);
                    }
                  }
                });
              }
              function startProgressTimer() {
                if (timerId) clearInterval(timerId);
                timerId = setInterval(function() {
                  if (ytPlayer && ytPlayer.getCurrentTime) {
                    var cur = ytPlayer.getCurrentTime() || 0;
                    var dur = ytPlayer.getDuration() || 0;
                    var st = ytPlayer.getPlayerState ? ytPlayer.getPlayerState() : -1;
                    window.webkit.messageHandlers.auraYT.postMessage({
                      type: 'tick',
                      currentTime: cur,
                      duration: dur,
                      state: st
                    });
                  }
                }, 260);
              }
              function postState(st) {
                var cur = (ytPlayer && ytPlayer.getCurrentTime) ? ytPlayer.getCurrentTime() : 0;
                var dur = (ytPlayer && ytPlayer.getDuration) ? ytPlayer.getDuration() : 0;
                window.webkit.messageHandlers.auraYT.postMessage({
                  type: 'state',
                  currentTime: cur,
                  duration: dur,
                  state: st
                });
              }
              window.auraControl = {
                play: function() { if (ytPlayer && ytPlayer.playVideo) ytPlayer.playVideo(); },
                pause: function() { if (ytPlayer && ytPlayer.pauseVideo) ytPlayer.pauseVideo(); },
                seek: function(sec) { if (ytPlayer && ytPlayer.seekTo) ytPlayer.seekTo(sec, true); },
                setVolume: function(vol) { if (ytPlayer && ytPlayer.setVolume) ytPlayer.setVolume(vol); }
              };
            </script>
            </body>
            </html>
            """
            webView.loadHTMLString(embedHTML, baseURL: URL(string: "https://www.youtube.com"))
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
            let cur = (dict["currentTime"] as? Double) ?? 0
            let dur = (dict["duration"] as? Double) ?? 0
            let st = (dict["state"] as? Int) ?? -1
            Task { @MainActor in
                self.playerEngine?.handleYouTubePlayerEvent(currentTime: cur, duration: dur, stateCode: st)
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
