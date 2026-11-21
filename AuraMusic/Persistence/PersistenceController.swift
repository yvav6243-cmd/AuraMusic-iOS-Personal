import Foundation
import SwiftData
import SwiftUI

// MARK: - SwiftData Entities

@Model
public final class PersistedTrackEntity {
    @Attribute(.unique) public var trackID: String
    public var providerRaw: String
    public var providerTrackID: String
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURLString: String?
    public var duration: Double
    public var isrc: String?
    public var genre: String?
    public var streamURLString: String?
    public var previewURLString: String?
    public var externalDeepLinkString: String?
    public var localFileRelativePath: String?
    public var isFavorite: Bool
    public var isInLibrary: Bool
    public var playCount: Int
    public var lastPlayedAt: Date?
    public var addedAt: Date
    public var customArtworkData: Data?

    public init(
        trackID: String,
        providerRaw: String,
        providerTrackID: String,
        title: String,
        artist: String,
        album: String,
        artworkURLString: String? = nil,
        duration: Double = 0,
        isrc: String? = nil,
        genre: String? = nil,
        streamURLString: String? = nil,
        previewURLString: String? = nil,
        externalDeepLinkString: String? = nil,
        localFileRelativePath: String? = nil,
        isFavorite: Bool = false,
        isInLibrary: Bool = true,
        playCount: Int = 0,
        lastPlayedAt: Date? = nil,
        addedAt: Date = .now
    ) {
        self.trackID = trackID
        self.providerRaw = providerRaw
        self.providerTrackID = providerTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURLString = artworkURLString
        self.duration = duration
        self.isrc = isrc
        self.genre = genre
        self.streamURLString = streamURLString
        self.previewURLString = previewURLString
        self.externalDeepLinkString = externalDeepLinkString
        self.localFileRelativePath = localFileRelativePath
        self.isFavorite = isFavorite
        self.isInLibrary = isInLibrary
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.addedAt = addedAt
    }

    public func toUniversalTrack() -> UniversalTrack {
        let provider = MusicProviderType(rawValue: providerRaw) ?? .audius
        return UniversalTrack(
            id: trackID,
            provider: provider,
            providerTrackID: providerTrackID,
            title: title,
            artist: artist,
            album: album,
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            duration: duration,
            isrc: isrc,
            genre: genre,
            streamURL: streamURLString.flatMap(URL.init(string:)),
            previewURL: previewURLString.flatMap(URL.init(string:)),
            externalDeepLink: externalDeepLinkString.flatMap(URL.init(string:)),
            localFileRelativePath: localFileRelativePath,
            isStreamable: true,
            isDownloadPermitted: provider.supportsLegalOfflineDownload
        )
    }
}

@Model
public final class PersistedPlaylistEntity {
    @Attribute(.unique) public var playlistID: String
    public var name: String
    public var playlistDescription: String
    public var coverArtworkURLString: String?
    public var customCoverImageData: Data?
    public var orderedTrackIDs: [String]
    public var isFavorite: Bool
    public var isSmartPlaylist: Bool
    public var smartRulesJSON: Data?
    public var sourceAppleMusicURL: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        playlistID: String = UUID().uuidString,
        name: String,
        playlistDescription: String = "",
        coverArtworkURLString: String? = nil,
        customCoverImageData: Data? = nil,
        orderedTrackIDs: [String] = [],
        isFavorite: Bool = false,
        isSmartPlaylist: Bool = false,
        smartRulesJSON: Data? = nil,
        sourceAppleMusicURL: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.playlistID = playlistID
        self.name = name
        self.playlistDescription = playlistDescription
        self.coverArtworkURLString = coverArtworkURLString
        self.customCoverImageData = customCoverImageData
        self.orderedTrackIDs = orderedTrackIDs
        self.isFavorite = isFavorite
        self.isSmartPlaylist = isSmartPlaylist
        self.smartRulesJSON = smartRulesJSON
        self.sourceAppleMusicURL = sourceAppleMusicURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var smartRules: [SmartPlaylistRule] {
        get {
            guard let data = smartRulesJSON else { return [] }
            return (try? JSONDecoder().decode([SmartPlaylistRule].self, from: data)) ?? []
        }
        set {
            smartRulesJSON = try? JSONEncoder().encode(newValue)
        }
    }
}

@Model
public final class PersistedListeningHistoryEntity {
    @Attribute(.unique) public var entryID: String
    public var trackID: String
    public var title: String
    public var artist: String
    public var album: String
    public var providerRaw: String
    public var artworkURLString: String?
    public var listenedSeconds: Double
    public var playedAt: Date

    public init(
        entryID: String = UUID().uuidString,
        trackID: String,
        title: String,
        artist: String,
        album: String,
        providerRaw: String,
        artworkURLString: String?,
        listenedSeconds: Double,
        playedAt: Date = .now
    ) {
        self.entryID = entryID
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.providerRaw = providerRaw
        self.artworkURLString = artworkURLString
        self.listenedSeconds = listenedSeconds
        self.playedAt = playedAt
    }
}

@Model
public final class PersistedCachedLyricsEntity {
    @Attribute(.unique) public var cacheKey: String
    public var trackTitle: String
    public var artistName: String
    public var syncedLRC: String?
    public var plainLyrics: String?
    public var languageCode: String?
    public var translatedLinesJSON: Data?
    public var cachedAt: Date

    public init(
        cacheKey: String,
        trackTitle: String,
        artistName: String,
        syncedLRC: String?,
        plainLyrics: String?,
        languageCode: String?,
        translatedLinesJSON: Data? = nil,
        cachedAt: Date = .now
    ) {
        self.cacheKey = cacheKey
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.syncedLRC = syncedLRC
        self.plainLyrics = plainLyrics
        self.languageCode = languageCode
        self.translatedLinesJSON = translatedLinesJSON
        self.cachedAt = cachedAt
    }
}

// MARK: - Backup & Restore Payload

public struct LibraryBackupPayload: Codable {
    public struct PlaylistRecord: Codable {
        public var playlistID: String
        public var name: String
        public var playlistDescription: String
        public var coverArtworkURLString: String?
        public var orderedTrackIDs: [String]
        public var isFavorite: Bool
        public var isSmartPlaylist: Bool
        public var smartRules: [SmartPlaylistRule]
        public var sourceAppleMusicURL: String?
        public var createdAt: Date
    }

    public struct TrackRecord: Codable {
        public var track: UniversalTrack
        public var isFavorite: Bool
        public var isInLibrary: Bool
        public var playCount: Int
        public var lastPlayedAt: Date?
        public var addedAt: Date
    }

    public var exportedAt: Date
    public var appVersion: String
    public var tracks: [TrackRecord]
    public var playlists: [PlaylistRecord]
    public var favoriteAlbumIDs: [String]
    public var searchHistory: [String]
}

// MARK: - Persistence Controller

@MainActor
public final class PersistenceController: ObservableObject {
    public static let shared = PersistenceController()

    public let container: ModelContainer
    @Published public private(set) var libraryTracks: [PersistedTrackEntity] = []
    @Published public private(set) var playlists: [PersistedPlaylistEntity] = []
    @Published public private(set) var recentHistory: [PersistedListeningHistoryEntity] = []
    @Published public var favoriteAlbumIDs: Set<String> = []
    @Published public var searchHistory: [String] = []

    private let defaults = UserDefaults.standard
    private let favoriteAlbumsKey = "aura.favoriteAlbums.v1"
    private let searchHistoryKey = "aura.searchHistory.v1"

    // O(1) in-memory lookup caches rebuilt once per reloadAll() to eliminate O(N) SwiftData scans inside ScrollView cells
    private var favoriteTrackIDs: Set<String> = []
    private var customArtworkURLByTrackID: [String: URL] = [:]
    private var customArtworkFlagTrackIDs: Set<String> = []

    public init(inMemory: Bool = false) {
        let schema = Schema([
            PersistedTrackEntity.self,
            PersistedPlaylistEntity.self,
            PersistedListeningHistoryEntity.self,
            PersistedCachedLyricsEntity.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }

        if let savedAlbums = defaults.stringArray(forKey: favoriteAlbumsKey) {
            self.favoriteAlbumIDs = Set(savedAlbums)
        }
        if let savedSearches = defaults.stringArray(forKey: searchHistoryKey) {
            self.searchHistory = savedSearches
        }

        reloadAll()
        seedDefaultSmartPlaylistsIfNeeded()
    }

    public var context: ModelContext {
        container.mainContext
    }

    public func reloadAll() {
        let trackDescriptor = FetchDescriptor<PersistedTrackEntity>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        let fetchedTracks = (try? context.fetch(trackDescriptor)) ?? []
        self.libraryTracks = fetchedTracks

        var favs = Set<String>()
        var customURLs: [String: URL] = [:]
        var customFlags = Set<String>()
        for entity in fetchedTracks {
            if entity.isFavorite {
                favs.insert(entity.trackID)
            }
            if let artStr = entity.artworkURLString,
               artStr.hasPrefix("file://"),
               let url = URL(string: artStr) {
                customURLs[entity.trackID] = url
                if entity.customArtworkData != nil {
                    customFlags.insert(entity.trackID)
                }
            }
        }
        self.favoriteTrackIDs = favs
        self.customArtworkURLByTrackID = customURLs
        self.customArtworkFlagTrackIDs = customFlags

        let playlistDescriptor = FetchDescriptor<PersistedPlaylistEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        self.playlists = (try? context.fetch(playlistDescriptor)) ?? []

        var historyDescriptor = FetchDescriptor<PersistedListeningHistoryEntity>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        historyDescriptor.fetchLimit = 150
        self.recentHistory = (try? context.fetch(historyDescriptor)) ?? []
    }

    private func seedDefaultSmartPlaylistsIfNeeded() {
        guard playlists.isEmpty else { return }
        let favoritesSmart = PersistedPlaylistEntity(
            name: "Favourite Songs",
            playlistDescription: "Automatically collects every song you mark with a star (Favourite) across all providers.",
            isFavorite: true,
            isSmartPlaylist: true
        )
        favoritesSmart.smartRules = [SmartPlaylistRule(field: .isFavorite, stringValue: "true", intValue: 1)]

        let heavyRotationSmart = PersistedPlaylistEntity(
            name: "Heavy Rotation",
            playlistDescription: "Smart playlist of songs played 3 or more times.",
            isFavorite: false,
            isSmartPlaylist: true
        )
        heavyRotationSmart.smartRules = [SmartPlaylistRule(field: .minimumPlays, stringValue: "", intValue: 3)]

        context.insert(favoritesSmart)
        context.insert(heavyRotationSmart)
        try? context.save()
        reloadAll()
    }

    // MARK: - Track Library Operations

    @discardableResult
    public func upsertTrack(
        _ track: UniversalTrack,
        addToLibrary: Bool = true,
        markFavorite: Bool? = nil,
        reload: Bool = true
    ) -> PersistedTrackEntity {
        let id = track.id
        let descriptor = FetchDescriptor<PersistedTrackEntity>(
            predicate: #Predicate { $0.trackID == id }
        )
        if let existing = try? context.fetch(descriptor).first {
            if addToLibrary { existing.isInLibrary = true }
            if let fav = markFavorite { existing.isFavorite = fav }
            if let path = track.localFileRelativePath {
                existing.localFileRelativePath = path
            }
            if existing.artworkURLString == nil, let art = track.artworkURL?.absoluteString {
                existing.artworkURLString = art
            }
            try? context.save()
            if reload { reloadAll() }
            return existing
        } else {
            let entity = PersistedTrackEntity(
                trackID: track.id,
                providerRaw: track.provider.rawValue,
                providerTrackID: track.providerTrackID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artworkURLString: track.artworkURL?.absoluteString,
                duration: track.duration,
                isrc: track.isrc,
                genre: track.genre,
                streamURLString: track.streamURL?.absoluteString,
                previewURLString: track.previewURL?.absoluteString,
                externalDeepLinkString: track.externalDeepLink?.absoluteString,
                localFileRelativePath: track.localFileRelativePath,
                isFavorite: markFavorite ?? false,
                isInLibrary: addToLibrary
            )
            context.insert(entity)
            try? context.save()
            if reload { reloadAll() }
            return entity
        }
    }

    public func toggleFavorite(_ track: UniversalTrack) {
        let id = track.id
        let descriptor = FetchDescriptor<PersistedTrackEntity>(
            predicate: #Predicate { $0.trackID == id }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.isFavorite.toggle()
            try? context.save()
            reloadAll()
        } else {
            upsertTrack(track, addToLibrary: true, markFavorite: true)
        }
    }

    /// Sets a custom user photo as the song's cover artwork, or pass nil to restore the default album cover
    @discardableResult
    public func setCustomTrackArtwork(imageData: Data?, for track: UniversalTrack, defaultArtworkURL: URL? = nil) -> URL? {
        let entity = upsertTrack(track, addToLibrary: true)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let coversDir = docs.appendingPathComponent("AuraLocalFiles/CustomCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)

        let safeID = track.id
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let fileURL = coversDir.appendingPathComponent("\(safeID)_custom.jpg")

        if let imageData, let uiImg = UIImage(data: imageData), let jpg = uiImg.jpegData(compressionQuality: 0.88) {
            // Store original remote URL in customArtworkData if needed so we can restore default cover later
            if entity.customArtworkData == nil,
               let currentArt = entity.artworkURLString,
               !currentArt.hasPrefix("file://") {
                entity.customArtworkData = Data(currentArt.utf8)
            }
            try? jpg.write(to: fileURL, options: .atomic)
            entity.artworkURLString = fileURL.absoluteString
            try? context.save()
            reloadAll()
            return fileURL
        } else {
            // Restore default album cover
            try? FileManager.default.removeItem(at: fileURL)
            if let savedOriginalData = entity.customArtworkData,
               let originalURLString = String(data: savedOriginalData, encoding: .utf8),
               !originalURLString.isEmpty {
                entity.artworkURLString = originalURLString
            } else if let defaultArtworkURL {
                entity.artworkURLString = defaultArtworkURL.absoluteString
            }
            entity.customArtworkData = nil
            try? context.save()
            reloadAll()
            return entity.artworkURLString.flatMap(URL.init(string:))
        }
    }

    public func hasCustomArtwork(for trackID: String) -> Bool {
        customArtworkFlagTrackIDs.contains(trackID)
    }

    public func effectiveArtworkURL(for track: UniversalTrack) -> URL? {
        customArtworkURLByTrackID[track.id] ?? track.artworkURL
    }

    public func isTrackFavorite(_ trackID: String) -> Bool {
        favoriteTrackIDs.contains(trackID)
    }

    public func removeTrackFromLibrary(_ trackID: String) {
        if let entity = libraryTracks.first(where: { $0.trackID == trackID }) {
            context.delete(entity)
            try? context.save()
            reloadAll()
        }
    }

    public func recordPlayback(of track: UniversalTrack, listenedSeconds: Double = 30) {
        let entity = upsertTrack(track, addToLibrary: false, reload: false)
        entity.playCount += 1
        entity.lastPlayedAt = .now

        let history = PersistedListeningHistoryEntity(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            providerRaw: track.provider.rawValue,
            artworkURLString: track.artworkURL?.absoluteString,
            listenedSeconds: max(listenedSeconds, track.duration > 0 ? min(track.duration, 180) : 120),
            playedAt: .now
        )
        context.insert(history)
        try? context.save()
        reloadAll()
    }

    // MARK: - Search History

    public func addSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        defaults.set(searchHistory, forKey: searchHistoryKey)
    }

    public func clearSearchHistory() {
        searchHistory.removeAll()
        defaults.removeObject(forKey: searchHistoryKey)
    }

    // MARK: - Album Favorites

    public func toggleFavoriteAlbum(_ albumID: String) {
        if favoriteAlbumIDs.contains(albumID) {
            favoriteAlbumIDs.remove(albumID)
        } else {
            favoriteAlbumIDs.insert(albumID)
        }
        defaults.set(Array(favoriteAlbumIDs), forKey: favoriteAlbumsKey)
    }

    // MARK: - Backup & Restore JSON

    public func exportBackupJSONData() throws -> Data {
        let trackRecords = libraryTracks.map { entity in
            LibraryBackupPayload.TrackRecord(
                track: entity.toUniversalTrack(),
                isFavorite: entity.isFavorite,
                isInLibrary: entity.isInLibrary,
                playCount: entity.playCount,
                lastPlayedAt: entity.lastPlayedAt,
                addedAt: entity.addedAt
            )
        }

        let playlistRecords = playlists.map { pl in
            LibraryBackupPayload.PlaylistRecord(
                playlistID: pl.playlistID,
                name: pl.name,
                playlistDescription: pl.playlistDescription,
                coverArtworkURLString: pl.coverArtworkURLString,
                orderedTrackIDs: pl.orderedTrackIDs,
                isFavorite: pl.isFavorite,
                isSmartPlaylist: pl.isSmartPlaylist,
                smartRules: pl.smartRules,
                sourceAppleMusicURL: pl.sourceAppleMusicURL,
                createdAt: pl.createdAt
            )
        }

        let payload = LibraryBackupPayload(
            exportedAt: .now,
            appVersion: "1.0.0",
            tracks: trackRecords,
            playlists: playlistRecords,
            favoriteAlbumIDs: Array(favoriteAlbumIDs),
            searchHistory: searchHistory
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public func importBackupJSONData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LibraryBackupPayload.self, from: data)

        for record in payload.tracks {
            let entity = upsertTrack(record.track, addToLibrary: record.isInLibrary, markFavorite: record.isFavorite)
            entity.playCount = max(entity.playCount, record.playCount)
            entity.lastPlayedAt = record.lastPlayedAt ?? entity.lastPlayedAt
        }

        for plRecord in payload.playlists {
            let id = plRecord.playlistID
            let descriptor = FetchDescriptor<PersistedPlaylistEntity>(
                predicate: #Predicate { $0.playlistID == id }
            )
            if let existing = try? context.fetch(descriptor).first {
                existing.name = plRecord.name
                existing.playlistDescription = plRecord.playlistDescription
                existing.orderedTrackIDs = plRecord.orderedTrackIDs
                existing.isFavorite = plRecord.isFavorite
            } else {
                let entity = PersistedPlaylistEntity(
                    playlistID: plRecord.playlistID,
                    name: plRecord.name,
                    playlistDescription: plRecord.playlistDescription,
                    coverArtworkURLString: plRecord.coverArtworkURLString,
                    orderedTrackIDs: plRecord.orderedTrackIDs,
                    isFavorite: plRecord.isFavorite,
                    isSmartPlaylist: plRecord.isSmartPlaylist,
                    sourceAppleMusicURL: plRecord.sourceAppleMusicURL,
                    createdAt: plRecord.createdAt
                )
                entity.smartRules = plRecord.smartRules
                context.insert(entity)
            }
        }

        favoriteAlbumIDs.formUnion(payload.favoriteAlbumIDs)
        defaults.set(Array(favoriteAlbumIDs), forKey: favoriteAlbumsKey)
        try? context.save()
        reloadAll()
    }
}
