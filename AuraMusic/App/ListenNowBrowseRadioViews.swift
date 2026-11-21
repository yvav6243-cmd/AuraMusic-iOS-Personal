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

        let recentArtistSeed = PersistenceController.shared.recentHistory.first?.artist
            ?? PersistenceController.shared.libraryTracks.first?.artist
            ?? "The Weeknd Daft Punk"

        let creds = ProviderCredentialsStore.shared
        let hasYTMusic = creds.hasConfiguredAPI(for: .youtubeMusic)
        let hasAppleMusic = creds.hasConfiguredAPI(for: .appleMusic)

        let audius = audiusProvider
        let apple = appleProvider
        let ytMusic = ytMusicProvider

        if hasYTMusic {
            async let ytTrendingTask = (try? await ytMusic.searchTracks(query: "Top Hits 2026 Official Audio", limit: 15)) ?? []
            async let ytChartsTask = (try? await ytMusic.searchTracks(query: "Global Top 50 Songs Audio", limit: 15)) ?? []
            async let ytPersonalTask = (try? await ytMusic.searchTracks(query: recentArtistSeed, limit: 10)) ?? []
            async let albumsTask = (try? await apple.searchAlbums(query: "Top Albums 2026", limit: 12)) ?? []
            async let artistsTask = (try? await apple.searchArtists(query: recentArtistSeed, limit: 8)) ?? []

            let (ytTrending, ytCharts, ytPersonal, albums, artists) = await (
                ytTrendingTask,
                ytChartsTask,
                ytPersonalTask,
                albumsTask,
                artistsTask
            )

            self.trendingFullStreamTracks = ytTrending
            self.appleTopChartTracks = ytCharts
            self.recommendedAlbums = albums
            self.featuredArtists = artists
            self.personalizedTracks = ytPersonal.isEmpty ? Array(ytTrending.prefix(10)) : ytPersonal
            self.isLoading = false
            return
        }

        async let audiusTrendingTask = (try? await audius.fetchTopCharts(limit: 20)) ?? []
        async let appleChartsTask: [UniversalTrack] = hasAppleMusic ? ((try? await apple.fetchTopCharts(limit: 20)) ?? []) : []
        async let albumsTask = (try? await apple.searchAlbums(query: "Top Albums 2026", limit: 12)) ?? []
        async let artistsTask = (try? await apple.searchArtists(query: recentArtistSeed, limit: 8)) ?? []
        async let personalTask = (try? await audius.searchTracks(query: recentArtistSeed, limit: 12)) ?? []

        let (audiusTracks, appleCharts, albums, artists, personal) = await (
            audiusTrendingTask,
            appleChartsTask,
            albumsTask,
            artistsTask,
            personalTask
        )

        self.trendingFullStreamTracks = audiusTracks
        self.appleTopChartTracks = appleCharts
        self.recommendedAlbums = albums
        self.featuredArtists = artists
        self.personalizedTracks = personal.isEmpty ? Array(audiusTracks.prefix(10)) : personal
        self.isLoading = false
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
                    // Top Picks Hero Carousel (Signature Apple Music Home Cards)
                    AppleMusicSectionHeader(
                        title: "Top Picks for You",
                        subtitle: "Full-length streams & personalized recommendations"
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(discovery.trendingFullStreamTracks.prefix(6)) { track in
                                Button {
                                    player.play(track, queue: discovery.trendingFullStreamTracks)
                                } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(track.provider.displayName.uppercased() + " • FEATURED STREAM")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .padding(.bottom, 6)

                                        ZStack(alignment: .bottomLeading) {
                                            AuraArtworkView(url: track.artworkURL, size: 255, cornerRadius: 14)

                                            LinearGradient(
                                                colors: [.clear, .black.opacity(0.82)],
                                                startPoint: .center,
                                                endPoint: .bottom
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(track.title)
                                                    .font(.system(size: 17, weight: .bold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                Text(track.artist)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundStyle(.white.opacity(0.82))
                                                    .lineLimit(1)
                                            }
                                            .padding(14)
                                        }
                                        .frame(width: 255, height: 255)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, AuraTheme.horizontalMargin)
                    }

                    // Recently Played / Continue Listening
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

                    // Personalized Recommendations Based on Listening History
                    if !discovery.personalizedTracks.isEmpty {
                        AppleMusicSectionHeader(
                            title: "Made for Your Taste",
                            subtitle: "Inspired by your recent listening history"
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
        }
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
