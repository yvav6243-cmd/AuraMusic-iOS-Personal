import Foundation
import SwiftUI

public enum UnifiedSearchScope: String, CaseIterable, Identifiable {
    case all = "Top Results"
    case songs = "Songs"
    case artists = "Artists"
    case albums = "Albums"
    case lyrics = "By Lyrics"

    public var id: String { rawValue }
}

@MainActor
public final class UnifiedSearchViewModel: ObservableObject {
    @Published public var query: String = ""
    @Published public var selectedScope: UnifiedSearchScope = .all
    @Published public var selectedProviderFilter: MusicProviderType? = nil
    @Published public private(set) var groupedTrackResults: [TrackVariantGroup] = []
    @Published public private(set) var albumResults: [UniversalAlbum] = []
    @Published public private(set) var artistResults: [UniversalArtist] = []
    @Published public private(set) var lyricMatchResults: [LRCLIBEntryDTO] = []
    @Published public private(set) var isSearching: Bool = false

    private let appleProvider = AppleMusicProvider()
    private let audiusProvider = AudiusProvider()
    private let ytMusicProvider = YouTubeMusicProvider(providerType: .youtubeMusic)
    private let ytVideoProvider = YouTubeMusicProvider(providerType: .youtube)
    private let spotifyProvider = SpotifyProvider()
    private let soundCloudProvider = SoundCloudProvider()
    private let matcher = TrackMatchingEngine()
    private var searchTask: Task<Void, Never>?

    public init() {}

    public func clearResults() {
        searchTask?.cancel()
        groupedTrackResults = []
        albumResults = []
        artistResults = []
        lyricMatchResults = []
        isSearching = false
    }

    public func submitManualSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }
        searchTask = Task {
            await executeSearch(for: trimmed)
        }
    }

    public func executeSearch(for term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        PersistenceController.shared.addSearchQuery(trimmed)

        let localMatches = PersistenceController.shared.libraryTracks
            .filter {
                $0.title.localizedCaseInsensitiveContains(trimmed) ||
                $0.artist.localizedCaseInsensitiveContains(trimmed) ||
                $0.album.localizedCaseInsensitiveContains(trimmed)
            }
            .map { $0.toUniversalTrack() }

        let creds = ProviderCredentialsStore.shared
        let useAppleTracks = creds.hasConfiguredAPI(for: .appleMusic)
        let useAudiusTracks = creds.hasConfiguredAPI(for: .audius)
        let useYTMusic = creds.hasConfiguredAPI(for: .youtubeMusic)
        let useYTVideo = creds.hasConfiguredAPI(for: .youtube)
        let useSpotify = creds.hasConfiguredAPI(for: .spotify)
        let useSoundCloud = creds.hasConfiguredAPI(for: .soundCloud)

        let apple = appleProvider
        let audius = audiusProvider
        let ytMusic = ytMusicProvider
        let ytVideo = ytVideoProvider
        let spotify = spotifyProvider
        let soundCloud = soundCloudProvider

        async let appleTracksTask: [UniversalTrack] = useAppleTracks ? ((try? await apple.searchTracks(query: trimmed, limit: 20)) ?? []) : []
        async let audiusTracksTask: [UniversalTrack] = useAudiusTracks ? ((try? await audius.searchTracks(query: trimmed, limit: 20)) ?? []) : []
        async let ytMusicTracksTask: [UniversalTrack] = useYTMusic ? ((try? await ytMusic.searchTracks(query: trimmed, limit: 15)) ?? []) : []
        async let ytVideoTracksTask: [UniversalTrack] = useYTVideo ? ((try? await ytVideo.searchTracks(query: trimmed, limit: 8)) ?? []) : []
        async let spotifyTracksTask: [UniversalTrack] = useSpotify ? ((try? await spotify.searchTracks(query: trimmed, limit: 15)) ?? []) : []
        async let soundCloudTracksTask: [UniversalTrack] = useSoundCloud ? ((try? await soundCloud.searchTracks(query: trimmed, limit: 15)) ?? []) : []
        async let albumsTask = (try? await apple.searchAlbums(query: trimmed, limit: 14)) ?? []
        async let artistsTask = (try? await apple.searchArtists(query: trimmed, limit: 10)) ?? []
        async let lyricsTask = (try? await LyricsService.shared.manualLyricsSearch(songTitle: trimmed, artistName: "")) ?? []

        let (
            appleTracks,
            audiusTracks,
            ytMusicTracks,
            ytVideoTracks,
            spotifyTracks,
            soundCloudTracks,
            fetchedAlbums,
            fetchedArtists,
            fetchedLyrics
        ) = await (
            appleTracksTask,
            audiusTracksTask,
            ytMusicTracksTask,
            ytVideoTracksTask,
            spotifyTracksTask,
            soundCloudTracksTask,
            albumsTask,
            artistsTask,
            lyricsTask
        )

        guard !Task.isCancelled else { return }

        // Only show songs from providers whose API is actually configured
        var combinedTracks: [UniversalTrack] = []
        combinedTracks.append(contentsOf: localMatches)
        combinedTracks.append(contentsOf: ytMusicTracks)
        combinedTracks.append(contentsOf: appleTracks)
        combinedTracks.append(contentsOf: soundCloudTracks)
        combinedTracks.append(contentsOf: spotifyTracks)
        combinedTracks.append(contentsOf: audiusTracks)
        combinedTracks.append(contentsOf: ytVideoTracks)

        self.groupedTrackResults = matcher.groupMatchingTracks(combinedTracks)
        self.albumResults = fetchedAlbums
        self.artistResults = fetchedArtists
        self.lyricMatchResults = fetchedLyrics
        self.isSearching = false
    }
}

// MARK: - Unified Multi-Provider Search View

public struct UnifiedSearchView: View {
    @StateObject private var viewModel = UnifiedSearchViewModel()
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared

    private let browseCategories: [(title: String, query: String, gradient: [Color], symbol: String)] = [
        ("Spatial & Hi-Fi", "Electronic Pop", [Color(red: 0.96, green: 0.16, blue: 0.36), Color(red: 0.55, green: 0.08, blue: 0.35)], "waveform"),
        ("Today's Hits", "Top Hits 2026", [Color(red: 0.98, green: 0.36, blue: 0.18), Color(red: 0.85, green: 0.12, blue: 0.28)], "flame.fill"),
        ("J-Pop & Anime", "YOASOBI Kenshi Yonezu", [Color(red: 0.25, green: 0.45, blue: 0.95), Color(red: 0.14, green: 0.20, blue: 0.65)], "sparkles"),
        ("K-Pop Essentials", "NewJeans BTS Stray Kids", [Color(red: 0.72, green: 0.20, blue: 0.92), Color(red: 0.38, green: 0.08, blue: 0.65)], "star.circle.fill"),
        ("Hip-Hop & R&B", "Hip Hop R&B", [Color(red: 0.18, green: 0.68, blue: 0.52), Color(red: 0.06, green: 0.38, blue: 0.32)], "beats.headphones"),
        ("Chill & Lo-Fi", "Lofi Chill Beats", [Color(red: 0.20, green: 0.58, blue: 0.85), Color(red: 0.10, green: 0.28, blue: 0.52)], "moon.stars.fill"),
        ("Rock Classics", "Classic Rock Alternative", [Color(red: 0.82, green: 0.22, blue: 0.18), Color(red: 0.45, green: 0.08, blue: 0.10)], "guitars.fill"),
        ("Classical & Piano", "Ludovico Einaudi Hans Zimmer", [Color(red: 0.52, green: 0.42, blue: 0.28), Color(red: 0.26, green: 0.20, blue: 0.14)], "pianokeys")
    ]

    public init() {}

    private var filteredGroups: [TrackVariantGroup] {
        guard let providerFilter = viewModel.selectedProviderFilter else {
            return viewModel.groupedTrackResults
        }
        return viewModel.groupedTrackResults.filter { group in
            group.variants.contains { $0.provider == providerFilter }
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            viewModel.submitManualSearch()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Search \"\(viewModel.query)\"")
                                    .font(.system(size: 15, weight: .bold))
                                    .lineLimit(1)
                                Spacer()
                                Text("Tap or press Search")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(0.85)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(AuraTheme.accentPink)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, AuraTheme.horizontalMargin)
                    }

                    if viewModel.groupedTrackResults.isEmpty && viewModel.albumResults.isEmpty && viewModel.artistResults.isEmpty && !viewModel.isSearching {
                        emptyQueryDiscoveryContent
                    } else {
                        activeSearchResultsContent
                    }
                    Spacer().frame(height: 95)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Search")
            .searchable(
                text: $viewModel.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Apple Music, Audius, YouTube, Spotify, Lyrics…"
            )
            .onChange(of: viewModel.query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.clearResults()
                }
            }
            .onSubmit(of: .search) {
                viewModel.submitManualSearch()
            }
        }
    }

    // MARK: - Discovery & Search History View

    private var emptyQueryDiscoveryContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !persistence.searchHistory.isEmpty {
                AppleMusicSectionHeader(
                    title: "Recent Searches",
                    actionTitle: "Clear"
                ) {
                    persistence.clearSearchHistory()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(persistence.searchHistory, id: \.self) { recent in
                            Button {
                                viewModel.query = recent
                                Task { await viewModel.executeSearch(for: recent) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 12))
                                    Text(recent)
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AuraTheme.horizontalMargin)
                }
            }

            AppleMusicSectionHeader(
                title: "Browse Categories",
                subtitle: "Search simultaneously across all configured music catalogs"
            )

            let columns = [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ]
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(browseCategories, id: \.title) { category in
                    Button {
                        viewModel.query = category.query
                        Task { await viewModel.executeSearch(for: category.query) }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: category.gradient,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(height: 98)

                            Image(systemName: category.symbol)
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(.white.opacity(0.22))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(12)

                            Text(category.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AuraTheme.horizontalMargin)
        }
    }

    // MARK: - Active Unified Results Content

    private var activeSearchResultsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Scope Picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(UnifiedSearchScope.allCases) { scope in
                        Button {
                            viewModel.selectedScope = scope
                        } label: {
                            Text(scope.rawValue)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(viewModel.selectedScope == scope ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(
                                        viewModel.selectedScope == scope
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

            // Provider Filter Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.selectedProviderFilter = nil
                    } label: {
                        Text("All Providers")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(viewModel.selectedProviderFilter == nil ? .white : .secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    viewModel.selectedProviderFilter == nil
                                        ? Color.primary.opacity(0.75)
                                        : Color.secondary.opacity(0.12)
                                )
                            )
                    }
                    .buttonStyle(.plain)

                    ForEach(ProviderCredentialsStore.shared.configuredCatalogProviders) { provider in
                        Button {
                            viewModel.selectedProviderFilter = (viewModel.selectedProviderFilter == provider) ? nil : provider
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: provider.systemIconName)
                                    .font(.system(size: 10))
                                Text(provider.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(viewModel.selectedProviderFilter == provider ? .white : provider.badgeColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    viewModel.selectedProviderFilter == provider
                                        ? provider.badgeColor
                                        : provider.badgeColor.opacity(0.14)
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AuraTheme.horizontalMargin)
            }

            if viewModel.isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching & matching across providers…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AuraTheme.horizontalMargin)
                .padding(.top, 12)
            }

            // Render Sections Based on Scope
            if viewModel.selectedScope == .all || viewModel.selectedScope == .songs {
                if !filteredGroups.isEmpty {
                    AppleMusicSectionHeader(
                        title: "Songs (Grouped by Match)",
                        subtitle: "Tap a provider badge on any song to play from that specific source"
                    )
                    VStack(spacing: 10) {
                        ForEach(filteredGroups) { group in
                            GroupedTrackResultCard(
                                group: group,
                                allQueueTracks: filteredGroups.map(\.bestPlayableVariant)
                            )
                        }
                    }
                    .padding(.horizontal, AuraTheme.horizontalMargin)
                }
            }

            if viewModel.selectedScope == .all || viewModel.selectedScope == .artists {
                if !viewModel.artistResults.isEmpty {
                    AppleMusicSectionHeader(title: "Artists")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(viewModel.artistResults) { artist in
                                NavigationLink {
                                    ArtistDetailPageView(artist: artist)
                                } label: {
                                    VStack(spacing: 6) {
                                        AuraArtworkView(
                                            url: artist.artworkURL,
                                            size: 98,
                                            cornerRadius: 49,
                                            placeholderSymbol: "music.mic"
                                        )
                                        Text(artist.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 98)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, AuraTheme.horizontalMargin)
                    }
                }
            }

            if viewModel.selectedScope == .all || viewModel.selectedScope == .albums {
                if !viewModel.albumResults.isEmpty {
                    AppleMusicSectionHeader(title: "Albums")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(viewModel.albumResults) { album in
                                NavigationLink {
                                    AlbumDetailPageView(album: album)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        AuraArtworkView(url: album.artworkURL, size: 145, cornerRadius: 10)
                                        Text(album.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 145, alignment: .leading)
                                        Text(album.artist)
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
            }

            if viewModel.selectedScope == .all || viewModel.selectedScope == .lyrics {
                if !viewModel.lyricMatchResults.isEmpty {
                    AppleMusicSectionHeader(
                        title: "Matched by Lyrics",
                        subtitle: "Original script lyrics matches from LRCLIB"
                    )
                    VStack(spacing: 8) {
                        ForEach(viewModel.lyricMatchResults.prefix(8)) { lyricDTO in
                            Button {
                                viewModel.query = "\(lyricDTO.trackName) \(lyricDTO.artistName)"
                                viewModel.selectedScope = .songs
                                Task {
                                    await viewModel.executeSearch(for: viewModel.query)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(lyricDTO.trackName)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text("\(lyricDTO.artistName) • \(lyricDTO.albumName ?? "Single")")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(lyricDTO.syncedLyrics != nil ? "SYNCED LRC" : "LYRICS")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(AuraTheme.accentPink)
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AuraTheme.horizontalMargin)
                }
            }
        }
    }
}

// MARK: - Grouped Multi-Provider Track Result Card (Section 4 Requirement)

public struct GroupedTrackResultCard: View {
    public let group: TrackVariantGroup
    public let allQueueTracks: [UniversalTrack]

    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject var persistence: PersistenceController = .shared
    @State private var selectedVariant: UniversalTrack?
    @State private var showPlaylistPicker: Bool = false

    private var activeVariant: UniversalTrack {
        selectedVariant ?? group.bestPlayableVariant
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AuraArtworkView(url: activeVariant.artworkURL ?? group.primaryTrack.artworkURL, size: 54, cornerRadius: 9)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if player.currentTrack?.id == activeVariant.id {
                            NowPlayingEqualizerBars(isPlaying: player.isPlaying)
                        }
                        Text(activeVariant.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(player.currentTrack?.id == activeVariant.id ? AuraTheme.accentPink : .primary)
                            .lineLimit(1)
                    }

                    Text("\(activeVariant.artist) • \(activeVariant.album)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\(activeVariant.formattedDuration) • \(activeVariant.playbackCapability.rawValue)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    ForEach(group.variants) { variant in
                        Button {
                            selectedVariant = variant
                            player.play(variant, queue: allQueueTracks)
                        } label: {
                            Label(
                                "Play via \(variant.provider.displayName) (\(variant.playbackCapability.rawValue))",
                                systemImage: variant.provider.systemIconName
                            )
                        }
                    }

                    Divider()

                    Button {
                        player.playNext(activeVariant)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        persistence.toggleFavorite(activeVariant)
                    } label: {
                        Label("Favorite", systemImage: "star")
                    }

                    Button {
                        persistence.upsertTrack(activeVariant, addToLibrary: true)
                    } label: {
                        Label("Add to Library", systemImage: "plus")
                    }

                    Button {
                        showPlaylistPicker = true
                    } label: {
                        Label("Add to Playlist…", systemImage: "text.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                player.play(activeVariant, queue: allQueueTracks)
            }

            // Provider Switcher Chips when song exists across multiple providers
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group.variants) { variant in
                        let isSelected = (activeVariant.id == variant.id)
                        Button {
                            selectedVariant = variant
                            player.play(variant, queue: allQueueTracks)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: variant.provider.systemIconName)
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(variant.provider.shortBadgeName) • \(variant.playbackCapability.rawValue)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(isSelected ? .white : variant.provider.badgeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? variant.provider.badgeColor
                                        : variant.provider.badgeColor.opacity(0.14)
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .sheet(isPresented: $showPlaylistPicker) {
            AddToPlaylistPickerSheet(track: activeVariant)
        }
    }
}
