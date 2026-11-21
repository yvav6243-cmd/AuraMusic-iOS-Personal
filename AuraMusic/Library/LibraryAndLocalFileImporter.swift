import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Local Audio File Importer & Metadata Extractor (Section 12)

@MainActor
public final class LocalAudioFileImporter: ObservableObject {
    public static let shared = LocalAudioFileImporter()

    private let fileManager = FileManager.default
    private let localDirectoryName = "AuraLocalFiles"

    public static let supportedContentTypes: [UTType] = [
        .audio,
        .mp3,
        .wav,
        .aiff,
        .mpeg4Audio,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "alac") ?? .audio,
        UTType(filenameExtension: "ogg") ?? .audio
    ]

    private init() {
        ensureDirectoryExists()
    }

    private var localDirectoryURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(localDirectoryName, isDirectory: true)
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
    }

    public func importAudioFiles(from urls: [URL]) async -> [UniversalTrack] {
        ensureDirectoryExists()
        var importedTracks: [UniversalTrack] = []

        for sourceURL in urls {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let fileName = sourceURL.lastPathComponent
            let relativePath = "\(localDirectoryName)/\(fileName)"
            let destinationURL = localDirectoryURL.appendingPathComponent(fileName)

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)

                let track = await extractAudioMetadata(from: destinationURL, relativePath: relativePath)
                PersistenceController.shared.upsertTrack(track, addToLibrary: true)
                importedTracks.append(track)
            } catch {
                continue
            }
        }
        return importedTracks
    }

    private func extractAudioMetadata(from fileURL: URL, relativePath: String) async -> UniversalTrack {
        let asset = AVURLAsset(url: fileURL)
        let ext = fileURL.pathExtension.uppercased()
        var title = fileURL.deletingPathExtension().lastPathComponent
        var artist = "Local Artist"
        var album = "Imported Files"
        var durationSeconds: TimeInterval = 0
        var artworkFileURL: URL? = nil

        if let cmDuration = try? await asset.load(.duration), cmDuration.seconds.isFinite {
            durationSeconds = cmDuration.seconds
        }

        if let metadataItems = try? await asset.load(.commonMetadata) {
            for item in metadataItems {
                guard let commonKey = item.commonKey else { continue }
                switch commonKey {
                case .commonKeyTitle:
                    if let val = try? await item.load(.stringValue), !val.isEmpty {
                        title = val
                    }
                case .commonKeyArtist, .commonKeyAuthor:
                    if let val = try? await item.load(.stringValue), !val.isEmpty {
                        artist = val
                    }
                case .commonKeyAlbumName:
                    if let val = try? await item.load(.stringValue), !val.isEmpty {
                        album = val
                    }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue),
                       let image = UIImage(data: data),
                       let pngData = image.jpegData(compressionQuality: 0.85) {
                        let artName = fileURL.deletingPathExtension().lastPathComponent + "_cover.jpg"
                        let artURL = localDirectoryURL.appendingPathComponent(artName)
                        try? pngData.write(to: artURL)
                        artworkFileURL = artURL
                    }
                default:
                    break
                }
            }
        }

        return UniversalTrack(
            provider: .localFile,
            providerTrackID: fileURL.lastPathComponent,
            title: title,
            artist: artist,
            album: album,
            artworkURL: artworkFileURL,
            duration: durationSeconds,
            streamURL: fileURL,
            localFileRelativePath: relativePath,
            isStreamable: true,
            isDownloadPermitted: true,
            audioQualityBadge: ext.isEmpty ? "LOCAL" : ext
        )
    }
}

// MARK: - Apple Music Library Tab View

public struct LibraryTabView: View {
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared

    @State private var showFileImporter: Bool = false
    @State private var showNewPlaylistAlert: Bool = false
    @State private var showSmartPlaylistSheet: Bool = false
    @State private var showAppleMusicImportSheet: Bool = false
    @State private var newPlaylistName: String = ""
    @State private var newPlaylistDescription: String = ""

    public init() {}

    private var allTracks: [UniversalTrack] {
        persistence.libraryTracks
            .filter(\.isInLibrary)
            .map { $0.toUniversalTrack() }
    }

    public var body: some View {
        NavigationStack {
            List {
                // Apple Music Category Rows
                Section {
                    NavigationLink {
                        PlaylistsListView(
                            showNewPlaylistAlert: $showNewPlaylistAlert,
                            showSmartPlaylistSheet: $showSmartPlaylistSheet,
                            showAppleMusicImportSheet: $showAppleMusicImportSheet
                        )
                    } label: {
                        libraryCategoryRow(title: "Playlists", symbol: "music.note.list")
                    }

                    NavigationLink {
                        LibraryArtistsListView()
                    } label: {
                        libraryCategoryRow(title: "Artists", symbol: "music.mic")
                    }

                    NavigationLink {
                        LibraryAlbumsListView()
                    } label: {
                        libraryCategoryRow(title: "Albums", symbol: "square.stack")
                    }

                    NavigationLink {
                        LibrarySongsListView(onlyFavorites: false)
                    } label: {
                        libraryCategoryRow(title: "Songs", symbol: "music.note")
                    }

                    NavigationLink {
                        LibrarySongsListView(onlyFavorites: true)
                    } label: {
                        libraryCategoryRow(title: "Favorite Songs", symbol: "star.fill")
                    }

                    NavigationLink {
                        DownloadsManagementView()
                    } label: {
                        libraryCategoryRow(title: "Downloaded", symbol: "arrow.down.circle")
                    }

                    NavigationLink {
                        ListeningReplayStatsView()
                    } label: {
                        libraryCategoryRow(title: "Replay & Listening Stats", symbol: "chart.bar.xaxis")
                    }
                }

                // Quick Import & Apple Music URL Import Banner
                Section {
                    Button {
                        showAppleMusicImportSheet = true
                    } label: {
                        Label("Import Apple Music Shared Playlist URL", systemImage: "link.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AuraTheme.accentPink)
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import Local Audio Files (MP3, FLAC, WAV, ALAC, M4A)", systemImage: "folder.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AuraTheme.accentPink)
                    }
                }

                // Recently Added Grid (Signature Apple Music 2-column grid)
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Recently Added")
                            .font(.system(size: 21, weight: .bold))

                        if allTracks.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "music.quarternote.3")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.secondary)
                                Text("Your Library is Empty")
                                    .font(.headline)
                                Text("Search across providers, import an Apple Music playlist URL, or add local audio files from the Files app.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            let columns = [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ]
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(allTracks.prefix(12)) { track in
                                    Button {
                                        player.play(track, queue: allTracks)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            AuraArtworkView(url: track.artworkURL, size: 158, cornerRadius: 10)
                                            Text(track.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowSeparator(.hidden)

                // Bottom Spacer for Floating Mini-Player
                Section {
                    Spacer().frame(height: 80)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showNewPlaylistAlert = true
                        } label: {
                            Label("New Playlist", systemImage: "music.note.list")
                        }
                        Button {
                            showSmartPlaylistSheet = true
                        } label: {
                            Label("New Smart Playlist", systemImage: "gearshape.2")
                        }
                        Button {
                            showAppleMusicImportSheet = true
                        } label: {
                            Label("Import Apple Music URL", systemImage: "link")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Import Audio from Files / AirDrop", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(AuraTheme.accentPink)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: LocalAudioFileImporter.supportedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task {
                        let imported = await LocalAudioFileImporter.shared.importAudioFiles(from: urls)
                        if let first = imported.first {
                            player.play(first, queue: imported)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAppleMusicImportSheet) {
                AppleMusicPlaylistImportSheet()
            }
            .sheet(isPresented: $showSmartPlaylistSheet) {
                SmartPlaylistBuilderSheet()
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist Name", text: $newPlaylistName)
                TextField("Description (optional)", text: $newPlaylistDescription)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                }
                Button("Create") {
                    PlaylistManager.shared.createPlaylist(
                        name: newPlaylistName,
                        description: newPlaylistDescription
                    )
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                }
            }
        }
    }

    private func libraryCategoryRow(title: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(AuraTheme.accentPink)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 19, weight: .regular))
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Subviews: Playlists, Artists, Albums, Songs, Smart Playlist Builder, Replay Stats

public struct PlaylistsListView: View {
    @ObservedObject var persistence: PersistenceController = .shared
    @Binding var showNewPlaylistAlert: Bool
    @Binding var showSmartPlaylistSheet: Bool
    @Binding var showAppleMusicImportSheet: Bool

    public var body: some View {
        List {
            Section {
                Button {
                    showNewPlaylistAlert = true
                } label: {
                    Label("New Playlist…", systemImage: "plus.square.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AuraTheme.accentPink)
                }

                Button {
                    showSmartPlaylistSheet = true
                } label: {
                    Label("New Smart Playlist…", systemImage: "gearshape.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AuraTheme.accentPink)
                }

                Button {
                    showAppleMusicImportSheet = true
                } label: {
                    Label("Import from Apple Music URL…", systemImage: "link.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AuraTheme.accentPink)
                }
            }

            Section("Your Playlists") {
                ForEach(persistence.playlists, id: \.playlistID) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 14) {
                            AuraArtworkView(
                                url: playlist.coverArtworkURLString.flatMap(URL.init(string:)),
                                size: 56,
                                cornerRadius: 8,
                                placeholderSymbol: playlist.isSmartPlaylist ? "gearshape.2.fill" : "music.note.list"
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(playlist.name)
                                        .font(.system(size: 16, weight: .semibold))
                                    if playlist.isFavorite {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(AuraTheme.accentPink)
                                    }
                                }
                                Text(playlist.isSmartPlaylist ? "Smart Playlist" : "\(playlist.orderedTrackIDs.count) Songs")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            PlaylistManager.shared.deletePlaylist(playlist)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
    }
}

public struct SmartPlaylistBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = "My Smart Mix"
    @State private var description: String = "Dynamic rule-based smart playlist"
    @State private var selectedField: SmartPlaylistField = .artist
    @State private var ruleValue: String = ""
    @State private var minPlays: Int = 2

    public var body: some View {
        NavigationStack {
            Form {
                Section("Smart Playlist Details") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)
                }

                Section("Dynamic Rule") {
                    Picker("Filter By", selection: $selectedField) {
                        ForEach(SmartPlaylistField.allCases) { field in
                            Text(field.rawValue).tag(field)
                        }
                    }
                    switch selectedField {
                    case .artist, .genre, .provider:
                        TextField("Contains value (e.g. Pop, Apple, Daft)", text: $ruleValue)
                    case .minimumPlays:
                        Stepper("Minimum Plays: \(minPlays)", value: $minPlays, in: 1...100)
                    case .isFavorite, .isOffline:
                        Text("Automatically includes matching tracks in your library.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Smart Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let rule = SmartPlaylistRule(
                            field: selectedField,
                            stringValue: ruleValue,
                            intValue: minPlays
                        )
                        PlaylistManager.shared.createPlaylist(
                            name: name,
                            description: description,
                            isSmart: true,
                            rules: [rule]
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

public struct LibrarySongsListView: View {
    public let onlyFavorites: Bool
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @State private var sortOrder: SongSortOption = .recentlyAdded
    @State private var filterText: String = ""

    public enum SongSortOption: String, CaseIterable, Identifiable {
        case recentlyAdded = "Recently Added"
        case title = "Title"
        case artist = "Artist"
        case mostPlayed = "Most Played"
        public var id: String { rawValue }
    }

    private var filteredTracks: [UniversalTrack] {
        var entities = persistence.libraryTracks.filter {
            onlyFavorites ? $0.isFavorite : $0.isInLibrary
        }
        if !filterText.isEmpty {
            entities = entities.filter {
                $0.title.localizedCaseInsensitiveContains(filterText) ||
                $0.artist.localizedCaseInsensitiveContains(filterText)
            }
        }
        switch sortOrder {
        case .recentlyAdded:
            entities.sort { $0.addedAt > $1.addedAt }
        case .title:
            entities.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            entities.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .mostPlayed:
            entities.sort { $0.playCount > $1.playCount }
        }
        return entities.map { $0.toUniversalTrack() }
    }

    public var body: some View {
        List {
            if !filteredTracks.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            if let first = filteredTracks.first {
                                player.play(first, queue: filteredTracks)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            let shuffled = filteredTracks.shuffled()
                            if let first = shuffled.first {
                                player.isShuffled = true
                                player.play(first, queue: shuffled)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                ForEach(filteredTracks) { track in
                    TrackRowView(track: track, queueContext: filteredTracks)
                }
            }
        }
        .searchable(text: $filterText, prompt: "Find in Songs")
        .navigationTitle(onlyFavorites ? "Favorite Songs" : "Songs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SongSortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                        .foregroundStyle(AuraTheme.accentPink)
                }
            }
        }
    }
}

public struct LibraryArtistsListView: View {
    @ObservedObject var persistence: PersistenceController = .shared

    private var groupedArtists: [(name: String, tracks: [UniversalTrack])] {
        var map: [String: [UniversalTrack]] = [:]
        for entity in persistence.libraryTracks {
            map[entity.artist, default: []].append(entity.toUniversalTrack())
        }
        return map.keys.sorted().map { ($0, map[$0] ?? []) }
    }

    public var body: some View {
        List(groupedArtists, id: \.name) { item in
            NavigationLink {
                ArtistDetailPageView(
                    artist: UniversalArtist(
                        provider: item.tracks.first?.provider ?? .appleMusic,
                        providerArtistID: item.name,
                        name: item.name,
                        artworkURL: item.tracks.first?.artworkURL,
                        topTracks: item.tracks
                    )
                )
            } label: {
                HStack(spacing: 14) {
                    AuraArtworkView(
                        url: item.tracks.first?.artworkURL,
                        size: 48,
                        cornerRadius: 24,
                        placeholderSymbol: "music.mic"
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(item.tracks.count) Songs")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Artists")
    }
}

public struct LibraryAlbumsListView: View {
    @ObservedObject var persistence: PersistenceController = .shared

    private var groupedAlbums: [UniversalAlbum] {
        var map: [String: [UniversalTrack]] = [:]
        for entity in persistence.libraryTracks {
            map[entity.album, default: []].append(entity.toUniversalTrack())
        }
        return map.keys.sorted().map { albumTitle in
            let tracks = map[albumTitle] ?? []
            return UniversalAlbum(
                provider: tracks.first?.provider ?? .appleMusic,
                providerAlbumID: albumTitle,
                title: albumTitle,
                artist: tracks.first?.artist ?? "Various Artists",
                artworkURL: tracks.first?.artworkURL,
                trackCount: tracks.count,
                tracks: tracks
            )
        }
    }

    public var body: some View {
        List(groupedAlbums) { album in
            NavigationLink {
                AlbumDetailPageView(album: album)
            } label: {
                HStack(spacing: 14) {
                    AuraArtworkView(url: album.artworkURL, size: 54, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.title)
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(album.artist) • \(album.trackCount) Songs")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Albums")
    }
}

// MARK: - Dedicated Artist & Album Pages (Section 13)

public struct ArtistDetailPageView: View {
    public let artist: UniversalArtist
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @State private var catalogTracks: [UniversalTrack] = []
    @State private var catalogAlbums: [UniversalAlbum] = []

    public init(artist: UniversalArtist) {
        self.artist = artist
    }

    private var allTracks: [UniversalTrack] {
        artist.topTracks.isEmpty ? catalogTracks : artist.topTracks
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 12) {
                    AuraArtworkView(
                        url: artist.artworkURL ?? allTracks.first?.artworkURL,
                        size: 150,
                        cornerRadius: 75,
                        placeholderSymbol: "music.mic"
                    )
                    Text(artist.name)
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.center)

                    Button {
                        if let first = allTracks.first {
                            player.play(first, queue: allTracks)
                        }
                    } label: {
                        Label("Play Top Songs", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(AuraTheme.accentPink))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

                AppleMusicSectionHeader(title: "Top Songs")
                VStack(spacing: 6) {
                    ForEach(allTracks.prefix(15)) { track in
                        TrackRowView(track: track, queueContext: allTracks)
                            .padding(.horizontal, AuraTheme.horizontalMargin)
                    }
                }

                if !catalogAlbums.isEmpty {
                    AppleMusicSectionHeader(title: "Albums")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(catalogAlbums) { album in
                                NavigationLink {
                                    AlbumDetailPageView(album: album)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        AuraArtworkView(url: album.artworkURL, size: 145, cornerRadius: 10)
                                        Text(album.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 145, alignment: .leading)
                                        if let year = album.releaseYear {
                                            Text(String(year))
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, AuraTheme.horizontalMargin)
                    }
                }

                Spacer().frame(height: 90)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let apple = AppleMusicProvider()
            if artist.topTracks.isEmpty {
                catalogTracks = (try? await apple.searchTracks(query: artist.name, limit: 15)) ?? []
            }
            catalogAlbums = (try? await apple.searchAlbums(query: artist.name, limit: 10)) ?? []
        }
    }
}

public struct AlbumDetailPageView: View {
    public let album: UniversalAlbum
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject var persistence: PersistenceController = .shared
    @State private var loadedTracks: [UniversalTrack] = []

    public init(album: UniversalAlbum) {
        self.album = album
    }

    private var tracks: [UniversalTrack] {
        album.tracks.isEmpty ? loadedTracks : album.tracks
    }

    public var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AuraArtworkView(url: album.artworkURL, size: 215, cornerRadius: 12)
                    Text(album.title)
                        .font(.system(size: 21, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(album.artist)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AuraTheme.accentPink)
                    HStack(spacing: 6) {
                        if let genre = album.genre {
                            Text(genre.uppercased())
                        }
                        if let year = album.releaseYear {
                            Text("• \(year)")
                        }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 14) {
                        Button {
                            if let first = tracks.first {
                                player.play(first, queue: tracks)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            let shuffled = tracks.shuffled()
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
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        Text("\(track.trackNumber ?? (index + 1))")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(player.currentTrack?.id == track.id ? AuraTheme.accentPink : .primary)
                            Text(track.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(track.formattedDuration)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(track, queue: tracks)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    persistence.toggleFavoriteAlbum(album.id)
                } label: {
                    Image(systemName: persistence.favoriteAlbumIDs.contains(album.id) ? "star.fill" : "star")
                        .foregroundStyle(AuraTheme.accentPink)
                }
            }
        }
        .task {
            if album.tracks.isEmpty && album.provider == .appleMusic {
                let apple = AppleMusicProvider()
                loadedTracks = (try? await apple.fetchAlbumTracks(collectionID: album.providerAlbumID)) ?? []
            }
        }
    }
}

// MARK: - Apple Music Replay & Listening Statistics View (Section 13)

public struct ListeningReplayStatsView: View {
    @ObservedObject var persistence: PersistenceController = .shared

    private var totalMinutesListened: Int {
        let totalSeconds = persistence.recentHistory.reduce(0.0) { $0 + $1.listenedSeconds }
        return max(Int(totalSeconds / 60.0), persistence.libraryTracks.reduce(0) { $0 + ($1.playCount * 3) })
    }

    private var topPlayedTracks: [PersistedTrackEntity] {
        persistence.libraryTracks
            .filter { $0.playCount > 0 }
            .sorted { $0.playCount > $1.playCount }
    }

    public var body: some View {
        List {
            Section("Personal Replay Summary") {
                HStack(spacing: 18) {
                    statCard(title: "Minutes Listened", value: "\(totalMinutesListened)", symbol: "clock.fill")
                    statCard(title: "Library Songs", value: "\(persistence.libraryTracks.count)", symbol: "music.note")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section("Most Played Songs") {
                if topPlayedTracks.isEmpty {
                    Text("Play songs across any provider to build your personal Replay statistics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topPlayedTracks.prefix(20), id: \.trackID) { entity in
                        HStack(spacing: 12) {
                            AuraArtworkView(url: entity.artworkURLString.flatMap(URL.init(string:)), size: 46, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.title)
                                    .font(.system(size: 15, weight: .semibold))
                                Text(entity.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(entity.playCount) plays")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                        }
                    }
                }
            }

            Section("Recent Listening History") {
                ForEach(persistence.recentHistory.prefix(30), id: \.entryID) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 14, weight: .semibold))
                            Text(entry.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.playedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Replay & Stats")
    }

    private func statCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(AuraTheme.accentPink)
                .font(.system(size: 18, weight: .bold))
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
    }
}

// MARK: - Reusable Apple Music Track Row with Context Menu & Actions

public struct TrackRowView: View {
    public let track: UniversalTrack
    public var queueContext: [UniversalTrack] = []

    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var downloadManager: OfflineDownloadManager = .shared
    @State private var showPlaylistPicker: Bool = false
    @State private var showShareSheet: Bool = false

    public init(track: UniversalTrack, queueContext: [UniversalTrack] = []) {
        self.track = track
        self.queueContext = queueContext
    }

    public var body: some View {
        HStack(spacing: 12) {
            AuraArtworkView(url: track.artworkURL, size: 50, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if player.currentTrack?.id == track.id {
                        NowPlayingEqualizerBars(isPlaying: player.isPlaying)
                    }
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(player.currentTrack?.id == track.id ? AuraTheme.accentPink : .primary)
                        .lineLimit(1)
                    if track.explicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2)))
                    }
                }

                HStack(spacing: 6) {
                    ProviderBadgePill(provider: track.provider, capability: track.playbackCapability)
                    Text("\(track.artist) • \(track.formattedDuration)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Menu {
                trackContextMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(track, queue: queueContext.isEmpty ? [track] : queueContext)
        }
        .contextMenu {
            trackContextMenuItems
        }
        .sheet(isPresented: $showPlaylistPicker) {
            AddToPlaylistPickerSheet(track: track)
        }
        .sheet(isPresented: $showShareSheet) {
            SystemShareSheet(activityItems: ["\(track.title) — \(track.artist) (\(track.provider.displayName))"])
        }
    }

    @ViewBuilder
    private var trackContextMenuItems: some View {
        Button {
            player.playNext(track)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            player.addToQueue(track)
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        Divider()

        Button {
            persistence.toggleFavorite(track)
        } label: {
            Label(
                persistence.isTrackFavorite(track.id) ? "Undo Favorite" : "Favorite",
                systemImage: persistence.isTrackFavorite(track.id) ? "star.slash" : "star"
            )
        }

        Button {
            persistence.upsertTrack(track, addToLibrary: true)
        } label: {
            Label("Add to Library", systemImage: "plus")
        }

        Button {
            showPlaylistPicker = true
        } label: {
            Label("Add to a Playlist…", systemImage: "text.badge.plus")
        }

        Button {
            downloadManager.enqueueDownload(for: track)
        } label: {
            Label(
                downloadManager.isDownloaded(track.id) ? "Downloaded Offline ✓" : "Download Offline",
                systemImage: downloadManager.isDownloaded(track.id) ? "checkmark.circle.fill" : "arrow.down.circle"
            )
        }

        if let deepLink = track.externalDeepLink {
            Button {
                UIApplication.shared.open(deepLink)
            } label: {
                Label("Open in \(track.provider.displayName)", systemImage: "arrow.up.forward.app")
            }
        }

        Button {
            showShareSheet = true
        } label: {
            Label("Share Song…", systemImage: "square.and.arrow.up")
        }
    }
}

public struct AddToPlaylistPickerSheet: View {
    public let track: UniversalTrack
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var persistence: PersistenceController = .shared

    public var body: some View {
        NavigationStack {
            List {
                ForEach(persistence.playlists.filter { !$0.isSmartPlaylist }, id: \.playlistID) { playlist in
                    Button {
                        PlaylistManager.shared.addTrack(track, to: playlist)
                        dismiss()
                    } label: {
                        HStack {
                            Text(playlist.name)
                                .font(.headline)
                            Spacer()
                            Text("\(playlist.orderedTrackIDs.count) songs")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
