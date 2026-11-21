import Foundation
import SwiftUI

// MARK: - Discovery ViewModel (Fetches Real Live Charts & Recommendations from Audius + Apple Music)

@MainActor
public final class MusicDiscoveryViewModel: ObservableObject {
    public static let shared = MusicDiscoveryViewModel()

    @Published public private(set) var trendingFullStreamTracks: [UniversalTrack] = []
    @Published public private(set) var appleTopChartTracks: [UniversalTrack] = []
    @Published public private(set) var recommendedAlbums: [UniversalAlbum] = []
    @Published public private(set) var featuredArtists: [UniversalArtist] = []
    @Published public private(set) var personalizedTracks: [UniversalTrack] = []
    @Published public private(set) var genreRecommendedTracks: [UniversalTrack] = []
    @Published public private(set) var producerRecommendedTracks: [UniversalTrack] = []
    @Published public private(set) var activeGenreTitle: String = "Your Favorite Genres"
    @Published public private(set) var activeProducerTitle: String = "Producers & Sound Creators"
    @Published public private(set) var isLoading: Bool = false

    private let audiusProvider = AudiusProvider()
    private let appleProvider = AppleMusicProvider()
    private let ytMusicProvider = YouTubeMusicProvider(providerType: .youtubeMusic)

    private init() {}

    public func loadInitialDiscoveryIfNeeded() async {
        guard trendingFullStreamTracks.isEmpty && !isLoading else { return }
        await refreshDiscovery()
    }

    public func refreshDiscovery() async {
        isLoading = true

        let persistence = PersistenceController.shared
        let favEntities = persistence.libraryTracks.filter(\.isFavorite)
        let historyEntities = persistence.recentHistory

        // 1. Determine user's favorite artist, genre, and producer/collaborator profile
        let primaryArtist = favEntities.first?.artist
            ?? historyEntities.first?.artist
            ?? persistence.libraryTracks.first?.artist
            ?? "The Weeknd"

        let secondaryArtist = favEntities.dropFirst().first?.artist
            ?? historyEntities.dropFirst().first?.artist
            ?? "Daft Punk"

        let primarySongTitle = favEntities.first?.title
            ?? historyEntities.first?.title
            ?? "Starboy"

        let detectedProfile = await resolveGenreAndProducerSeed(
            songTitle: primarySongTitle,
            artistName: primaryArtist,
            fallbackGenre: favEntities.first?.genre
        )

        self.activeGenreTitle = detectedProfile.genreDisplay
        self.activeProducerTitle = detectedProfile.producerDisplay

        let creds = ProviderCredentialsStore.shared
        let hasYTMusic = creds.hasConfiguredAPI(for: .youtubeMusic)
        let hasAppleMusic = creds.hasConfiguredAPI(for: .appleMusic)

        let audius = audiusProvider
        let apple = appleProvider
        let ytMusic = ytMusicProvider

        if hasYTMusic {
            let genreQuery = "\(detectedProfile.genreQuerySeed) \(primaryArtist) official audio"
            let producerQuery = "\(detectedProfile.producerQuerySeed) official audio"
            let tasteQuery = "\(primaryArtist) \(secondaryArtist) official audio"

            async let ytGenreTask = (try? await ytMusic.searchTracks(query: genreQuery, limit: 12)) ?? []
            async let ytProducerTask = (try? await ytMusic.searchTracks(query: producerQuery, limit: 12)) ?? []
            async let ytPersonalTask = (try? await ytMusic.searchTracks(query: tasteQuery, limit: 12)) ?? []
            async let ytTrendingTask = (try? await ytMusic.searchTracks(query: "Top Hits 2026 Official Audio", limit: 15)) ?? []
            async let ytChartsTask = (try? await ytMusic.searchTracks(query: "Global Top 50 Songs Audio", limit: 15)) ?? []
            async let albumsTask = (try? await apple.searchAlbums(query: primaryArtist, limit: 10)) ?? []
            async let artistsTask = (try? await apple.searchArtists(query: primaryArtist, limit: 8)) ?? []

            let (ytGenre, ytProducer, ytPersonal, ytTrending, ytCharts, albums, artists) = await (
                ytGenreTask,
                ytProducerTask,
                ytPersonalTask,
                ytTrendingTask,
                ytChartsTask,
                albumsTask,
                artistsTask
            )

            self.genreRecommendedTracks = ytGenre
            self.producerRecommendedTracks = ytProducer
            self.personalizedTracks = ytPersonal.isEmpty ? Array(ytTrending.prefix(10)) : ytPersonal
            self.trendingFullStreamTracks = ytTrending
            self.appleTopChartTracks = ytCharts
            self.recommendedAlbums = albums
            self.featuredArtists = artists
            self.isLoading = false
            return
        }

        async let audiusTrendingTask = (try? await audius.fetchTopCharts(limit: 20)) ?? []
        async let appleChartsTask: [UniversalTrack] = hasAppleMusic ? ((try? await apple.fetchTopCharts(limit: 20)) ?? []) : []
        async let albumsTask = (try? await apple.searchAlbums(query: primaryArtist, limit: 12)) ?? []
        async let artistsTask = (try? await apple.searchArtists(query: primaryArtist, limit: 8)) ?? []
        async let personalTask = (try? await audius.searchTracks(query: primaryArtist, limit: 12)) ?? []

        let (audiusTracks, appleCharts, albums, artists, personal) = await (
            audiusTrendingTask,
            appleChartsTask,
            albumsTask,
            artistsTask,
            personalTask
        )

        self.trendingFullStreamTracks = audiusTracks
        self.genreRecommendedTracks = personal
        self.producerRecommendedTracks = Array(audiusTracks.prefix(8))
        self.appleTopChartTracks = appleCharts
        self.recommendedAlbums = albums
        self.featuredArtists = artists
        self.personalizedTracks = personal.isEmpty ? Array(audiusTracks.prefix(10)) : personal
        self.isLoading = false
    }

    /// Analyzes song metadata via iTunes Catalog to determine exact Genre, Producer/Label style, and sonic seeds
    private func resolveGenreAndProducerSeed(
        songTitle: String,
        artistName: String,
        fallbackGenre: String?
    ) async -> (genreDisplay: String, genreQuerySeed: String, producerDisplay: String, producerQuerySeed: String) {
        let clean = LyricsService.extractCleanTitleAndArtist(rawTitle: songTitle, rawArtist: artistName)
        var detectedGenre = fallbackGenre ?? "Pop & Hip-Hop"
        var copyrightOrLabel = ""

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(clean.title) \(clean.artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "2")
        ]
        if let url = components.url,
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let first = results.first {
            if let g = first["primaryGenreName"] as? String, !g.isEmpty {
                detectedGenre = g
            }
            if let col = first["collectionName"] as? String {
                copyrightOrLabel = col
            }
        }

        // Map genre & artist to known producer/sound-architect seeds
        let lowerGenre = detectedGenre.lowercased()
        let producerSeed: String
        let producerDisplay: String
        if lowerGenre.contains("hip-hop") || lowerGenre.contains("rap") {
            producerSeed = "\(clean.artist) Metro Boomin Mike Dean produced"
            producerDisplay = "Hip-Hop Producers • \(clean.artist) & Similar"
        } else if lowerGenre.contains("r&b") || lowerGenre.contains("soul") {
            producerSeed = "\(clean.artist) Illangelo Kaytranada produced"
            producerDisplay = "R&B Producers • \(clean.artist) Sound"
        } else if lowerGenre.contains("electronic") || lowerGenre.contains("dance") {
            producerSeed = "\(clean.artist) Gesaffelstein Daft Punk electronic"
            producerDisplay = "Electronic Producers • \(clean.artist) Vibe"
        } else if lowerGenre.contains("rock") || lowerGenre.contains("alternative") {
            producerSeed = "\(clean.artist) Rick Rubin Nigel Godrich rock"
            producerDisplay = "Rock & Alternative • \(clean.artist) Style"
        } else {
            producerSeed = "\(clean.artist) Max Martin Jack Antonoff \(detectedGenre)"
            producerDisplay = "Producers & Collaborators • \(clean.artist)"
        }

        let genreQuery = "\(detectedGenre) \(clean.artist) \(copyrightOrLabel)".trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            genreDisplay: "\(detectedGenre) Recommendations",
            genreQuerySeed: genreQuery,
            producerDisplay: producerDisplay,
            producerQuerySeed: producerSeed
        )
    }
}

// MARK: - 1. Home / Listen Now Tab (Section 3)

public struct ListenNowTabView: View {
    @ObservedObject var discovery: MusicDiscoveryViewModel = .shared
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared

    @State private var showSettingsSheet: Bool = false
    @State private var showAppleImportSheet: Bool = false

    public init() {}

    private var favouriteTracks: [UniversalTrack] {
        persistence.libraryTracks
            .filter(\.isFavorite)
            .sorted { $0.addedAt > $1.addedAt }
            .map { $0.toUniversalTrack() }
    }

    private var recentlyPlayedTracks: [UniversalTrack] {
        var seen = Set<String>()
        var result: [UniversalTrack] = []
        let trackMap = Dictionary(uniqueKeysWithValues: persistence.libraryTracks.map { ($0.trackID, $0.toUniversalTrack()) })
        for entry in persistence.recentHistory {
            if !seen.contains(entry.trackID), let found = trackMap[entry.trackID] {
                seen.insert(entry.trackID)
                result.append(found)
            }
        }
        return result
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // 1. Favourite Songs Hero Playlist Section (Replaces "Top Picks for You")
                    AppleMusicSectionHeader(
                        title: "Favourite Songs",
                        subtitle: "Your starred songs playlist • Ready for instant playback"
                    )

                    favouriteSongsHeroCard
                        .padding(.horizontal, AuraTheme.horizontalMargin)

                    if !favouriteTracks.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(favouriteTracks.prefix(6)) { track in
                                TrackRowView(track: track, queueContext: favouriteTracks)
                                    .padding(.horizontal, AuraTheme.horizontalMargin)
                            }
                        }
                    }

                    // 2. Recommendations Based on Genre
                    if !discovery.genreRecommendedTracks.isEmpty {
                        AppleMusicSectionHeader(
                            title: discovery.activeGenreTitle,
                            subtitle: "Recommended songs based on the genres of your Favourite Songs"
                        )

                        VStack(spacing: 8) {
                            ForEach(discovery.genreRecommendedTracks.prefix(6)) { track in
                                TrackRowView(track: track, queueContext: discovery.genreRecommendedTracks)
                                    .padding(.horizontal, AuraTheme.horizontalMargin)
                            }
                        }
                    }

                    // 3. Recommendations Based on Producers & Sound Style
                    if !discovery.producerRecommendedTracks.isEmpty {
                        AppleMusicSectionHeader(
                            title: discovery.activeProducerTitle,
                            subtitle: "Curated by producers, beatmakers & collaborators of your favorite tracks"
                        )

                        VStack(spacing: 8) {
                            ForEach(discovery.producerRecommendedTracks.prefix(6)) { track in
                                TrackRowView(track: track, queueContext: discovery.producerRecommendedTracks)
                                    .padding(.horizontal, AuraTheme.horizontalMargin)
                            }
                        }
                    }

                    // 4. Recently Played / Continue Listening
                    if !recentlyPlayedTracks.isEmpty {
                        AppleMusicSectionHeader(
                            title: "Recently Played",
                            subtitle: "Continue listening where you left off"
                        )

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recentlyPlayedTracks.prefix(12)) { track in
                                    Button {
                                        player.play(track, queue: recentlyPlayedTracks)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            AuraArtworkView(url: track.artworkURL, size: 145, cornerRadius: 10)
                                            Text(track.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 145, alignment: .leading)
                                            Text(track.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .frame(width: 145, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, AuraTheme.horizontalMargin)
                        }
                    }

                    // 5. Personalized Recommendations Based on Listening History
                    if !discovery.personalizedTracks.isEmpty {
                        AppleMusicSectionHeader(
                            title: "Made for Your Taste",
                            subtitle: "Inspired by your favorite artists & listening history"
                        )

                        VStack(spacing: 8) {
                            ForEach(discovery.personalizedTracks.prefix(6)) { track in
                                TrackRowView(track: track, queueContext: discovery.personalizedTracks)
                                    .padding(.horizontal, AuraTheme.horizontalMargin)
                            }
                        }
                    }

                    // Recently Added Playlists
                    if !persistence.playlists.isEmpty {
                        AppleMusicSectionHeader(title: "Your Playlists")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(persistence.playlists, id: \.playlistID) { pl in
                                    NavigationLink {
                                        PlaylistDetailView(playlist: pl)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            AuraArtworkView(
                                                url: pl.coverArtworkURLString.flatMap(URL.init(string:)),
                                                size: 145,
                                                cornerRadius: 10,
                                                placeholderSymbol: pl.isSmartPlaylist ? "gearshape.2.fill" : "music.note.list"
                                            )
                                            Text(pl.name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 145, alignment: .leading)
                                            Text(pl.isSmartPlaylist ? "Smart Mix" : "\(pl.orderedTrackIDs.count) Songs")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 145, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, AuraTheme.horizontalMargin)
                        }
                    }

                    // Recommended Albums
                    if !discovery.recommendedAlbums.isEmpty {
                        AppleMusicSectionHeader(title: "Recommended Albums")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(discovery.recommendedAlbums) { album in
                                    NavigationLink {
                                        AlbumDetailPageView(album: album)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            AuraArtworkView(url: album.artworkURL, size: 150, cornerRadius: 10)
                                            Text(album.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 150, alignment: .leading)
                                            Text(album.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .frame(width: 150, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, AuraTheme.horizontalMargin)
                        }
                    }

                    // Favorite & Featured Artists
                    if !discovery.featuredArtists.isEmpty {
                        AppleMusicSectionHeader(title: "Favorite & Featured Artists")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 18) {
                                ForEach(discovery.featuredArtists) { artist in
                                    NavigationLink {
                                        ArtistDetailPageView(artist: artist)
                                    } label: {
                                        VStack(spacing: 6) {
                                            AuraArtworkView(
                                                url: artist.artworkURL,
                                                size: 104,
                                                cornerRadius: 52,
                                                placeholderSymbol: "music.mic"
                                            )
                                            Text(artist.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 104)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, AuraTheme.horizontalMargin)
                        }
                    }

                    Spacer().frame(height: 95)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Home")
            .refreshable {
                await discovery.refreshDiscovery()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showAppleImportSheet = true
                    } label: {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(AuraTheme.accentPink)
                    }

                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(AuraTheme.accentPink)
                    }
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsAndPersonalizationView()
            }
            .sheet(isPresented: $showAppleImportSheet) {
                AppleMusicPlaylistImportSheet()
            }
            .task {
                await discovery.loadInitialDiscoveryIfNeeded()
            }
            .onChange(of: favouriteTracks.count) { _, _ in
                Task {
                    await discovery.refreshDiscovery()
                }
            }
        }
    }

    private var favouriteSongsHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink {
                LibrarySongsListView(onlyFavorites: true)
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AuraTheme.accentPink,
                                        Color(red: 0.65, green: 0.06, blue: 0.28)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 86, height: 86)

                        if let firstArt = favouriteTracks.first?.artworkURL {
                            AuraArtworkView(url: firstArt, size: 86, cornerRadius: 14)
                                .overlay(
                                    ZStack {
                                        Color.black.opacity(0.28)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 32, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                )
                        } else {
                            Image(systemName: "star.fill")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("Favourite Songs")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.primary)
                            Image(systemName: "star.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(AuraTheme.accentPink)
                        }

                        Text(favouriteTracks.isEmpty
                             ? "Tap the star ★ on any song to add it here"
                             : "\(favouriteTracks.count) Starred Songs • Personal Playlist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if !favouriteTracks.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        if let first = favouriteTracks.first {
                            player.isShuffled = false
                            player.play(first, queue: favouriteTracks)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AuraTheme.accentPink)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        let shuffled = favouriteTracks.shuffled()
                        if let first = shuffled.first {
                            player.isShuffled = true
                            player.play(first, queue: shuffled)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AuraTheme.accentPink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AuraTheme.accentPink.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

// MARK: - 2. New / Browse Tab (Section 3)

public struct BrowseTabView: View {
    @ObservedObject var discovery: MusicDiscoveryViewModel = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // Trending Full-Length Open Catalog Songs
                    AppleMusicSectionHeader(
                        title: "Trending Tracks (Full Stream)",
                        subtitle: "Direct 320kbps full playback & offline download ready"
                    )

                    VStack(spacing: 8) {
                        ForEach(discovery.trendingFullStreamTracks.prefix(10)) { track in
                            TrackRowView(track: track, queueContext: discovery.trendingFullStreamTracks)
                                .padding(.horizontal, AuraTheme.horizontalMargin)
                        }
                    }

                    // Apple Music Daily Top Charts
                    if !discovery.appleTopChartTracks.isEmpty {
                        AppleMusicSectionHeader(
                            title: "Apple Music Top Charts",
                            subtitle: "Most played global chart songs"
                        )

                        VStack(spacing: 8) {
                            ForEach(Array(discovery.appleTopChartTracks.prefix(12).enumerated()), id: \.element.id) { idx, track in
                                HStack(spacing: 10) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(idx < 3 ? AuraTheme.accentPink : .secondary)
                                        .frame(width: 24)
                                    TrackRowView(track: track, queueContext: discovery.appleTopChartTracks)
                                }
                                .padding(.horizontal, AuraTheme.horizontalMargin)
                            }
                        }
                    }

                    // New Releases Albums
                    if !discovery.recommendedAlbums.isEmpty {
                        AppleMusicSectionHeader(title: "New & Essential Albums")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(discovery.recommendedAlbums) { album in
                                    NavigationLink {
                                        AlbumDetailPageView(album: album)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            AuraArtworkView(url: album.artworkURL, size: 155, cornerRadius: 10)
                                            Text(album.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 155, alignment: .leading)
                                            Text(album.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .frame(width: 155, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, AuraTheme.horizontalMargin)
                        }
                    }

                    Spacer().frame(height: 95)
                }
                .padding(.top, 8)
            }
            .navigationTitle("New")
            .refreshable {
                await discovery.refreshDiscovery()
            }
            .task {
                await discovery.loadInitialDiscoveryIfNeeded()
            }
        }
    }
}

// MARK: - 3. Radio Tab (Section 3)

public struct RadioTabView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @State private var directoryStations: [RadioStation] = []
    @State private var selectedGenreTag: String = "electronic"
    @State private var isLoadingDirectory: Bool = false

    private let radioProvider = LiveRadioProvider()
    private let genreTags = ["electronic", "pop", "jazz", "rock", "lofi", "classical", "ambient"]

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AppleMusicSectionHeader(
                        title: "Live Featured Stations",
                        subtitle: "Continuous 24/7 background internet radio streams"
                    )

                    VStack(spacing: 14) {
                        ForEach(LiveRadioProvider.featuredStations) { station in
                            let stationTrack = station.asUniversalTrack()
                            let isCurrent = (player.currentTrack?.id == stationTrack.id)

                            Button {
                                let allTracks = LiveRadioProvider.featuredStations.map { $0.asUniversalTrack() }
                                player.play(stationTrack, queue: allTracks)
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [AuraTheme.accentPink, Color(red: 0.25, green: 0.10, blue: 0.48)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 68, height: 68)

                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.system(size: 26, weight: .bold))
                                            .foregroundStyle(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            if isCurrent {
                                                NowPlayingEqualizerBars(isPlaying: player.isPlaying)
                                            }
                                            Text(station.name)
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.primary)
                                        }
                                        Text(station.subtitle)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text("LIVE • \(station.genre.uppercased()) • \(station.bitrateKbps) KBPS")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(AuraTheme.accentPink)
                                    }

                                    Spacer()

                                    Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 30))
                                        .foregroundStyle(AuraTheme.accentPink)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.secondary.opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AuraTheme.horizontalMargin)

                    // Global Radio Directory by Genre
                    AppleMusicSectionHeader(
                        title: "Stations by Genre",
                        subtitle: "Live global radio streams"
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(genreTags, id: \.self) { tag in
                                Button {
                                    selectedGenreTag = tag
                                    Task { await loadGenreStations(tag) }
                                } label: {
                                    Text(tag.capitalized)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(selectedGenreTag == tag ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule().fill(
                                                selectedGenreTag == tag
                                                    ? AuraTheme.accentPink
                                                    : Color.secondary.opacity(0.14)
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, AuraTheme.horizontalMargin)
                    }

                    if isLoadingDirectory {
                        HStack {
                            ProgressView()
                            Text("Loading live \(selectedGenreTag) stations…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, AuraTheme.horizontalMargin)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(directoryStations) { station in
                                let track = station.asUniversalTrack()
                                TrackRowView(
                                    track: track,
                                    queueContext: directoryStations.map { $0.asUniversalTrack() }
                                )
                                .padding(.horizontal, AuraTheme.horizontalMargin)
                            }
                        }
                    }

                    Spacer().frame(height: 95)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Radio")
            .task {
                await loadGenreStations(selectedGenreTag)
            }
        }
    }

    private func loadGenreStations(_ tag: String) async {
        isLoadingDirectory = true
        directoryStations = (try? await radioProvider.searchDirectoryStations(tagOrName: tag, limit: 12)) ?? []
        isLoadingDirectory = false
    }
}
