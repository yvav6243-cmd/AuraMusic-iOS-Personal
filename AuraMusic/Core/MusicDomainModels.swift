import Foundation
import SwiftUI

// MARK: - Music Provider Type

public enum MusicProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleMusic = "apple_music"
    case youtubeMusic = "youtube_music"
    case youtube = "youtube"
    case soundCloud = "soundcloud"
    case spotify = "spotify"
    case audius = "audius"
    case radio = "internet_radio"
    case localFile = "local_file"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .youtubeMusic: return "YouTube Music"
        case .youtube: return "YouTube"
        case .soundCloud: return "SoundCloud"
        case .spotify: return "Spotify"
        case .audius: return "Audius Open Catalog"
        case .radio: return "Live Radio"
        case .localFile: return "On My iPhone"
        }
    }

    public var shortBadgeName: String {
        switch self {
        case .appleMusic: return "APPLE MUSIC"
        case .youtubeMusic: return "YT MUSIC"
        case .youtube: return "YOUTUBE"
        case .soundCloud: return "SOUNDCLOUD"
        case .spotify: return "SPOTIFY"
        case .audius: return "AUDIUS HI-FI"
        case .radio: return "LIVE RADIO"
        case .localFile: return "LOCAL FILE"
        }
    }

    public var systemIconName: String {
        switch self {
        case .appleMusic: return "apple.logo"
        case .youtubeMusic: return "play.circle.fill"
        case .youtube: return "play.rectangle.fill"
        case .soundCloud: return "cloud.fill"
        case .spotify: return "waveform.circle.fill"
        case .audius: return "waveform.badge.plus"
        case .radio: return "dot.radiowaves.left.and.right"
        case .localFile: return "iphone"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .appleMusic: return Color(red: 0.98, green: 0.18, blue: 0.28)
        case .youtubeMusic: return Color(red: 1.0, green: 0.0, blue: 0.2)
        case .youtube: return Color(red: 0.92, green: 0.12, blue: 0.12)
        case .soundCloud: return Color(red: 1.0, green: 0.33, blue: 0.0)
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .audius: return Color(red: 0.49, green: 0.11, blue: 0.88)
        case .radio: return Color(red: 0.20, green: 0.60, blue: 1.0)
        case .localFile: return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }

    public var supportsLegalOfflineDownload: Bool {
        switch self {
        case .audius, .localFile, .youtubeMusic, .youtube, .soundCloud:
            return true
        case .appleMusic, .spotify, .radio:
            return false
        }
    }

    public var limitationExplanation: String {
        switch self {
        case .appleMusic:
            return "Uses official MusicKit & Apple Music API. Full playback requires an active Apple Music subscription on this iPhone; otherwise plays official 30-second AAC previews or matches full audio from available open providers."
        case .youtubeMusic, .youtube:
            return "Uses official YouTube Data API v3. Plays via authorized YouTube IFrame Player or opens directly in YouTube Music. Raw audio extraction and DRM/ad bypass are prohibited by YouTube Terms of Service."
        case .soundCloud:
            return "Uses SoundCloud API. Plays authorized progressive/HLS streams for tracks permitted by the rights holder; restricted tracks open via SoundCloud deep link."
        case .spotify:
            return "Uses official Spotify Web API for catalog search, artwork, ISRC matching, and 30s preview streams where available. Full-track streaming requires launching the Spotify app or automatic cross-provider matching."
        case .audius:
            return "Official open music catalog providing full-length DRM-free 320kbps MP3 streaming, background playback, and legal offline downloads with no API key required."
        case .radio:
            return "Live Icecast/HLS internet radio stations supporting continuous background audio playback."
        case .localFile:
            return "Personal DRM-free audio files (MP3, FLAC, WAV, AAC, M4A, ALAC, AIFF) imported from the iOS Files app or AirDrop."
        }
    }
}

// MARK: - Playback Availability & Resolution

public enum PlaybackCapability: String, Codable, Hashable, Sendable {
    case directFullAudio = "Full Track"
    case appleMusicKit = "MusicKit"
    case preview30s = "30s Preview"
    case embeddedVideo = "Inline Video"
    case externalApp = "External App"
    case offlineFile = "Offline"

    /// Concise single-line label for song row badges so pills NEVER wrap vertically or squish artist names.
    public var shortPillLabel: String? {
        switch self {
        case .offlineFile: return "OFFLINE"
        case .preview30s: return "30S"
        case .directFullAudio, .appleMusicKit, .embeddedVideo, .externalApp:
            return nil
        }
    }
}

// MARK: - Persistent Song Trim Range (Custom Start / End Cut)

public struct TrackTrimRange: Codable, Equatable, Hashable, Sendable {
    public static let minimumSegmentLength: TimeInterval = 5.0

    public var startSeconds: TimeInterval
    public var endSeconds: TimeInterval?

    public init(startSeconds: TimeInterval = 0, endSeconds: TimeInterval? = nil) {
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = endSeconds
    }

    /// Clamps start & end safely inside `[0, totalDuration]` while preserving at least 5 seconds of playable audio.
    public func normalized(for totalDuration: TimeInterval) -> TrackTrimRange {
        let safeTotal = max(0, totalDuration)
        guard safeTotal > Self.minimumSegmentLength else {
            return TrackTrimRange(startSeconds: 0, endSeconds: nil)
        }
        let maxStart = max(0, safeTotal - Self.minimumSegmentLength)
        let clampedStart = max(0, min(startSeconds, maxStart))
        var clampedEnd: TimeInterval? = nil
        if let rawEnd = endSeconds, rawEnd.isFinite {
            let minEnd = min(safeTotal, clampedStart + Self.minimumSegmentLength)
            let bounded = max(minEnd, min(rawEnd, safeTotal))
            if bounded < safeTotal - 0.5 {
                clampedEnd = bounded
            }
        }
        return TrackTrimRange(startSeconds: clampedStart, endSeconds: clampedEnd)
    }

    public func isEffectivelyTrimmed(for totalDuration: TimeInterval) -> Bool {
        let norm = normalized(for: totalDuration)
        if norm.startSeconds >= 0.5 { return true }
        if let end = norm.endSeconds, totalDuration > 0, end < totalDuration - 0.5 {
            return true
        }
        return false
    }

    public func effectiveEnd(for totalDuration: TimeInterval) -> TimeInterval {
        let norm = normalized(for: totalDuration)
        return norm.endSeconds ?? max(0, totalDuration)
    }

    public func effectiveDuration(for totalDuration: TimeInterval) -> TimeInterval {
        let norm = normalized(for: totalDuration)
        let end = norm.endSeconds ?? max(0, totalDuration)
        return max(0, end - norm.startSeconds)
    }

    public func formattedRange(for totalDuration: TimeInterval) -> String {
        let norm = normalized(for: totalDuration)
        let end = norm.endSeconds ?? max(0, totalDuration)
        return "\(Self.formatClock(norm.startSeconds))–\(Self.formatClock(end))"
    }

    public static func formatClock(_ value: TimeInterval) -> String {
        guard value.isFinite && value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Universal Track

public struct UniversalTrack: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: MusicProviderType
    public let providerTrackID: String
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?
    public var duration: TimeInterval
    public var isrc: String?
    public var genre: String?
    public var releaseDate: Date?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var explicit: Bool
    public var streamURL: URL?
    public var previewURL: URL?
    public var externalDeepLink: URL?
    public var localFileRelativePath: String?
    public var isStreamable: Bool
    public var isDownloadPermitted: Bool
    public var audioQualityBadge: String?

    public init(
        id: String? = nil,
        provider: MusicProviderType,
        providerTrackID: String,
        title: String,
        artist: String,
        album: String = "Single",
        artworkURL: URL? = nil,
        duration: TimeInterval = 0,
        isrc: String? = nil,
        genre: String? = nil,
        releaseDate: Date? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        explicit: Bool = false,
        streamURL: URL? = nil,
        previewURL: URL? = nil,
        externalDeepLink: URL? = nil,
        localFileRelativePath: String? = nil,
        isStreamable: Bool = true,
        isDownloadPermitted: Bool = false,
        audioQualityBadge: String? = nil
    ) {
        self.id = id ?? "\(provider.rawValue):\(providerTrackID)"
        self.provider = provider
        self.providerTrackID = providerTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.isrc = isrc
        self.genre = genre
        self.releaseDate = releaseDate
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.explicit = explicit
        self.streamURL = streamURL
        self.previewURL = previewURL
        self.externalDeepLink = externalDeepLink
        self.localFileRelativePath = localFileRelativePath
        self.isStreamable = isStreamable
        self.isDownloadPermitted = isDownloadPermitted
        self.audioQualityBadge = audioQualityBadge
    }

    public var playbackCapability: PlaybackCapability {
        if localFileRelativePath != nil {
            return .offlineFile
        }
        switch provider {
        case .localFile:
            return .offlineFile
        case .audius, .radio:
            return .directFullAudio
        case .soundCloud:
            if streamURL != nil && isStreamable {
                return .directFullAudio
            } else if previewURL != nil {
                return .preview30s
            }
            return .externalApp
        case .appleMusic:
            if isStreamable {
                return .appleMusicKit
            } else if previewURL != nil {
                return .preview30s
            }
            return .externalApp
        case .youtubeMusic:
            return .directFullAudio
        case .youtube:
            return .embeddedVideo
        case .spotify:
            if previewURL != nil {
                return .preview30s
            }
            return .externalApp
        }
    }

    public var formattedDuration: String {
        guard duration > 0 && duration.isFinite else { return "LIVE" }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Grouped Multi-Provider Track Result

public struct TrackVariantGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public var primaryTrack: UniversalTrack
    public var variants: [UniversalTrack]

    public init(primaryTrack: UniversalTrack, variants: [UniversalTrack]) {
        self.id = primaryTrack.id
        self.primaryTrack = primaryTrack
        self.variants = variants
    }

    public var availableProviders: [MusicProviderType] {
        var seen = Set<MusicProviderType>()
        var result: [MusicProviderType] = []
        for variant in variants {
            if !seen.contains(variant.provider) {
                seen.insert(variant.provider)
                result.append(variant.provider)
            }
        }
        return result
    }

    /// Automatically inspects which APIs are configured and picks the best full-track playable variant
    public var bestPlayableVariant: UniversalTrack {
        let sorted = variants.sorted { lhs, rhs in
            priorityScore(for: lhs) > priorityScore(for: rhs)
        }
        return sorted.first ?? primaryTrack
    }

    private func priorityScore(for track: UniversalTrack) -> Int {
        if track.localFileRelativePath != nil || track.provider == .localFile {
            return 100
        }
        let hasYouTubeKey = !(ProviderCredentialsStore.readKeychain(key: "aura.token.youtube") ?? "").isEmpty
        let hasSoundCloudKey = !(ProviderCredentialsStore.readKeychain(key: "aura.token.soundcloud") ?? "").isEmpty

        switch track.provider {
        case .localFile:
            return 100
        case .youtubeMusic:
            return hasYouTubeKey ? 99 : 40
        case .youtube:
            return hasYouTubeKey ? 95 : 30
        case .audius, .radio:
            return 92
        case .soundCloud:
            return (hasSoundCloudKey && track.isStreamable) ? 90 : 35
        case .appleMusic:
            return track.isStreamable ? 85 : 50
        case .spotify:
            return track.previewURL != nil ? 45 : 20
        }
    }
}

// MARK: - Universal Album

public struct UniversalAlbum: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: MusicProviderType
    public let providerAlbumID: String
    public var title: String
    public var artist: String
    public var artworkURL: URL?
    public var releaseYear: Int?
    public var genre: String?
    public var trackCount: Int
    public var isExplicit: Bool
    public var editorialNotes: String?
    public var tracks: [UniversalTrack]

    public init(
        id: String? = nil,
        provider: MusicProviderType,
        providerAlbumID: String,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        releaseYear: Int? = nil,
        genre: String? = nil,
        trackCount: Int = 0,
        isExplicit: Bool = false,
        editorialNotes: String? = nil,
        tracks: [UniversalTrack] = []
    ) {
        self.id = id ?? "\(provider.rawValue):album:\(providerAlbumID)"
        self.provider = provider
        self.providerAlbumID = providerAlbumID
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.releaseYear = releaseYear
        self.genre = genre
        self.trackCount = trackCount > 0 ? trackCount : tracks.count
        self.isExplicit = isExplicit
        self.editorialNotes = editorialNotes
        self.tracks = tracks
    }
}

// MARK: - Universal Artist

public struct UniversalArtist: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: MusicProviderType
    public let providerArtistID: String
    public var name: String
    public var artworkURL: URL?
    public var genres: [String]
    public var biography: String?
    public var topTracks: [UniversalTrack]
    public var albums: [UniversalAlbum]
    public var relatedArtists: [String]

    public init(
        id: String? = nil,
        provider: MusicProviderType,
        providerArtistID: String,
        name: String,
        artworkURL: URL? = nil,
        genres: [String] = [],
        biography: String? = nil,
        topTracks: [UniversalTrack] = [],
        albums: [UniversalAlbum] = [],
        relatedArtists: [String] = []
    ) {
        self.id = id ?? "\(provider.rawValue):artist:\(providerArtistID)"
        self.provider = provider
        self.providerArtistID = providerArtistID
        self.name = name
        self.artworkURL = artworkURL
        self.genres = genres
        self.biography = biography
        self.topTracks = topTracks
        self.albums = albums
        self.relatedArtists = relatedArtists
    }
}

// MARK: - Radio Station

public struct RadioStation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var subtitle: String
    public var genre: String
    public var streamURL: URL
    public var artworkURL: URL?
    public var bitrateKbps: Int
    public var countryCode: String

    public init(
        id: String,
        name: String,
        subtitle: String,
        genre: String,
        streamURL: URL,
        artworkURL: URL? = nil,
        bitrateKbps: Int = 192,
        countryCode: String = "US"
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.genre = genre
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.bitrateKbps = bitrateKbps
        self.countryCode = countryCode
    }

    public func asUniversalTrack() -> UniversalTrack {
        UniversalTrack(
            id: "radio:\(id)",
            provider: .radio,
            providerTrackID: id,
            title: name,
            artist: subtitle,
            album: "\(genre) • \(bitrateKbps) kbps Live Radio",
            artworkURL: artworkURL,
            duration: 0,
            genre: genre,
            streamURL: streamURL,
            isStreamable: true,
            isDownloadPermitted: false,
            audioQualityBadge: "LIVE \(bitrateKbps)K"
        )
    }
}

// MARK: - Smart Playlist Rules

public enum SmartPlaylistField: String, Codable, CaseIterable, Identifiable, Sendable {
    case artist = "Artist"
    case genre = "Genre"
    case provider = "Provider"
    case minimumPlays = "Play Count At Least"
    case isFavorite = "Favorites Only"
    case isOffline = "Downloaded Only"

    public var id: String { rawValue }
}

public struct SmartPlaylistRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var field: SmartPlaylistField
    public var stringValue: String
    public var intValue: Int

    public init(
        id: UUID = UUID(),
        field: SmartPlaylistField,
        stringValue: String = "",
        intValue: Int = 1
    ) {
        self.id = id
        self.field = field
        self.stringValue = stringValue
        self.intValue = intValue
    }
}

// MARK: - Playback & Audio Settings Models

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one

    public var symbolName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

public enum AudioStreamingQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case dataSaver = "High Efficiency (AAC 96 kbps)"
    case highQuality = "High Quality (AAC/MP3 256-320 kbps)"
    case lossless = "Lossless when available (ALAC/FLAC up to 24-bit/48kHz)"

    public var id: String { rawValue }
}

public enum EqualizerPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat = "Flat"
    case acoustic = "Acoustic"
    case bassBooster = "Bass Booster"
    case classical = "Classical"
    case electronic = "Electronic"
    case hipHop = "Hip-Hop"
    case lateNight = "Late Night"
    case rock = "Rock"
    case vocalBooster = "Vocal Booster"

    public var id: String { rawValue }

    /// 6-band EQ gains in dB: [60Hz, 150Hz, 400Hz, 1kHz, 2.4kHz, 15kHz]
    public var bandGainsDB: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0]
        case .acoustic: return [3.5, 3.0, 1.5, 1.0, 2.5, 3.0]
        case .bassBooster: return [6.5, 5.0, 2.0, 0.0, 0.0, 0.0]
        case .classical: return [3.5, 2.5, -1.0, 1.5, 3.0, 4.0]
        case .electronic: return [4.5, 3.5, 0.0, -1.5, 2.5, 4.5]
        case .hipHop: return [5.5, 4.5, 1.0, -1.0, 1.5, 3.0]
        case .lateNight: return [-2.0, -1.0, 1.5, 2.5, 1.5, -1.5]
        case .rock: return [4.5, 3.0, -1.5, -0.5, 2.5, 4.0]
        case .vocalBooster: return [-1.5, -0.5, 3.0, 4.5, 3.0, 0.5]
        }
    }
}
