import Foundation
import PhotosUI
import SwiftData
import SwiftUI

// MARK: - Playlist Manager Service

@MainActor
public final class PlaylistManager: ObservableObject {
    public static let shared = PlaylistManager()

    private let persistence = PersistenceController.shared
    private let appleImporter = AppleMusicPlaylistImporter()

    private init() {}

    @discardableResult
    public func createPlaylist(
        name: String,
        description: String = "",
        isSmart: Bool = false,
        rules: [SmartPlaylistRule] = [],
        initialTracks: [UniversalTrack] = [],
        coverArtworkURL: URL? = nil,
        sourceAppleMusicURL: String? = nil
    ) -> PersistedPlaylistEntity {
        var trackIDs: [String] = []
        for track in initialTracks {
            persistence.upsertTrack(track, addToLibrary: true)
            trackIDs.append(track.id)
        }

        let entity = PersistedPlaylistEntity(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Playlist" : name,
            playlistDescription: description,
            coverArtworkURLString: coverArtworkURL?.absoluteString ?? initialTracks.first?.artworkURL?.absoluteString,
            orderedTrackIDs: trackIDs,
            isFavorite: false,
            isSmartPlaylist: isSmart,
            sourceAppleMusicURL: sourceAppleMusicURL
        )
        entity.smartRules = rules
        persistence.context.insert(entity)
        try? persistence.context.save()
        persistence.reloadAll()
        return entity
    }

    public func deletePlaylist(_ playlist: PersistedPlaylistEntity) {
        persistence.context.delete(playlist)
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func duplicatePlaylist(_ playlist: PersistedPlaylistEntity) {
        let copy = PersistedPlaylistEntity(
            name: "\(playlist.name) Copy",
            playlistDescription: playlist.playlistDescription,
            coverArtworkURLString: playlist.coverArtworkURLString,
            customCoverImageData: playlist.customCoverImageData,
            orderedTrackIDs: playlist.orderedTrackIDs,
            isFavorite: playlist.isFavorite,
            isSmartPlaylist: playlist.isSmartPlaylist,
            smartRulesJSON: playlist.smartRulesJSON,
            sourceAppleMusicURL: playlist.sourceAppleMusicURL
        )
        persistence.context.insert(copy)
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func updateMetadata(
        for playlist: PersistedPlaylistEntity,
        name: String,
        description: String,
        customCoverData: Data?
    ) {
        playlist.name = name
        playlist.playlistDescription = description
        if let customCoverData {
            playlist.customCoverImageData = customCoverData
        }
        playlist.updatedAt = .now
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func toggleFavoritePlaylist(_ playlist: PersistedPlaylistEntity) {
        playlist.isFavorite.toggle()
        playlist.updatedAt = .now
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func addTrack(_ track: UniversalTrack, to playlist: PersistedPlaylistEntity) {
        persistence.upsertTrack(track, addToLibrary: true)
        if !playlist.orderedTrackIDs.contains(track.id) {
            playlist.orderedTrackIDs.append(track.id)
        }
        if playlist.coverArtworkURLString == nil {
            playlist.coverArtworkURLString = track.artworkURL?.absoluteString
        }
        playlist.updatedAt = .now
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func removeTracks(at offsets: IndexSet, from playlist: PersistedPlaylistEntity) {
        playlist.orderedTrackIDs.remove(atOffsets: offsets)
        playlist.updatedAt = .now
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func moveTracks(from source: IndexSet, to destination: Int, in playlist: PersistedPlaylistEntity) {
        playlist.orderedTrackIDs.move(fromOffsets: source, toOffset: destination)
        playlist.updatedAt = .now
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func sortPlaylistTracks(_ playlist: PersistedPlaylistEntity, by criterion: PlaylistSortCriterion) {
        let currentTracks = resolveTracks(for: playlist)
        let sorted: [UniversalTrack]
        switch criterion {
        case .customOrder:
            return
        case .title:
            sorted = currentTracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            sorted = currentTracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .duration:
            sorted = currentTracks.sorted { $0.duration < $1.duration }
        }
        playlist.orderedTrackIDs = sorted.map(\.id)
        playlist.updatedAt = .now
        try? persistence.context.save()
        persistence.reloadAll()
    }

    public func resolveTracks(for playlist: PersistedPlaylistEntity) -> [UniversalTrack] {
        let allEntities = persistence.libraryTracks
        if playlist.isSmartPlaylist {
            return evaluateSmartRules(playlist.smartRules, against: allEntities)
        }
        let map = Dictionary(uniqueKeysWithValues: allEntities.map { ($0.trackID, $0) })
        return playlist.orderedTrackIDs.compactMap { map[$0]?.toUniversalTrack() }
    }

    private func evaluateSmartRules(_ rules: [SmartPlaylistRule], against entities: [PersistedTrackEntity]) -> [UniversalTrack] {
        guard !rules.isEmpty else { return entities.map { $0.toUniversalTrack() } }
        return entities.filter { entity in
            for rule in rules {
                switch rule.field {
                case .artist:
                    if !entity.artist.localizedCaseInsensitiveContains(rule.stringValue) { return false }
                case .genre:
                    if !(entity.genre ?? "").localizedCaseInsensitiveContains(rule.stringValue) { return false }
                case .provider:
                    if !entity.providerRaw.localizedCaseInsensitiveContains(rule.stringValue) { return false }
                case .minimumPlays:
                    if entity.playCount < rule.intValue { return false }
                case .isFavorite:
                    if !entity.isFavorite { return false }
                case .isOffline:
                    if entity.localFileRelativePath == nil { return false }
                }
            }
            return true
        }.map { $0.toUniversalTrack() }
    }

    // MARK: - Apple Music Shared URL Import Execution

    public func importAppleMusicPlaylist(from urlString: String) async throws -> (playlist: PersistedPlaylistEntity, report: AppleMusicPlaylistImportReport) {
        let report = try await appleImporter.importSharedPlaylist(from: urlString)
        let created = createPlaylist(
            name: report.playlistTitle,
            description: report.playlistDescription,
            isSmart: false,
            initialTracks: report.orderedTracks,
            coverArtworkURL: report.coverArtworkURL,
            sourceAppleMusicURL: report.sourceURL.absoluteString
        )
        return (created, report)
    }

    public func exportPlaylistTextSummary(_ playlist: PersistedPlaylistEntity) -> String {
        let tracks = resolveTracks(for: playlist)
        var lines = [
            "Playlist: \(playlist.name)",
            "Description: \(playlist.playlistDescription)",
            "Tracks (\(tracks.count)):"
        ]
        for (i, t) in tracks.enumerated() {
            lines.append("\(i + 1). \(t.title) — \(t.artist) [\(t.provider.displayName)]")
        }
        return lines.joined(separator: "\n")
    }
}

public enum PlaylistSortCriterion: String, CaseIterable, Identifiable {
    case customOrder = "Custom Order"
    case title = "Title"
    case artist = "Artist"
    case duration = "Duration"

    public var id: String { rawValue }
}

// MARK: - Apple Music Shared Playlist URL Import Sheet

public struct AppleMusicPlaylistImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlInput: String = ""
    @State private var isImporting: Bool = false
    @State private var importReport: AppleMusicPlaylistImportReport?
    @State private var importedYouTubeTrack: UniversalTrack?
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                            Text("Import Song from YouTube URL or Apple Music Playlist")
                                .font(.headline)
                        }
                        Text("Paste any YouTube / YouTube Music link (e.g. https://youtu.be/... or https://www.youtube.com/watch?v=...) to get the full song with lyrics and album cover, OR paste an Apple Music playlist URL.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    TextField("https://youtu.be/... or https://music.apple.com/...", text: $urlInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("Paste from Clipboard") {
                            if let clip = UIPasteboard.general.string {
                                urlInput = clip
                            }
                        }
                        .font(.footnote.weight(.semibold))

                        Spacer()

                        Button("Sample YouTube Song") {
                            urlInput = "https://www.youtube.com/watch?v=plnfIj7dkJE"
                        }
                        .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task {
                            await performImport()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Loading Song, Cover & Lyrics…")
                                    .fontWeight(.semibold)
                            } else {
                                Text("Get Song / Import URL")
                                    .fontWeight(.bold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                    .foregroundStyle(AuraTheme.accentPink)
                }

                if let errorMessage {
                    Section("Import Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if let ytTrack = importedYouTubeTrack {
                    Section("YouTube Song Ready & Playing") {
                        HStack(spacing: 12) {
                            AuraArtworkView(url: ytTrack.artworkURL, size: 60, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ytTrack.title)
                                    .font(.headline)
                                Text(ytTrack.artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Saved to Favourite Songs & Library • Full Lyrics Loaded")
                                    .font(.caption2)
                                    .foregroundStyle(AuraTheme.accentPink)
                            }
                        }

                        Button("Done — Listen Now") {
                            dismiss()
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(AuraTheme.accentPink)
                    }
                }

                if let report = importReport {
                    Section("Import Summary") {
                        LabeledContent("Playlist", value: report.playlistTitle)
                        LabeledContent("Storefront", value: report.storefront.uppercased())
                        LabeledContent("Catalog ID", value: report.playlistCatalogID)
                        LabeledContent("Imported Tracks", value: "\(report.orderedTracks.count)")
                        LabeledContent("Full-Stream Cross-Matches", value: "\(report.crossMatchedTracksCount)")

                        if !report.unavailableTrackTitles.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Unavailable Tracks (\(report.unavailableTrackTitles.count)):")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.orange)
                                ForEach(report.unavailableTrackTitles, id: \.self) { item in
                                    Text("• \(item)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Button("Done — View in Playlists") {
                            dismiss()
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(AuraTheme.accentPink)
                    }
                }
            }
            .navigationTitle("Import Apple Music URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func performImport() async {
        isImporting = true
        errorMessage = nil
        importReport = nil
        importedYouTubeTrack = nil

        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if YouTubeMusicProvider.extractYouTubeVideoID(from: trimmed) != nil {
            if let ytTrack = await YouTubeMusicProvider(providerType: .youtubeMusic).resolveTrackFromYouTubeURL(trimmed) {
                PersistenceController.shared.upsertTrack(ytTrack, addToLibrary: true, markFavorite: true)
                UniversalAudioPlayerEngine.shared.play(ytTrack, queue: [ytTrack])
                importedYouTubeTrack = ytTrack
            } else {
                errorMessage = "Could not load the YouTube song from this link."
            }
            isImporting = false
            return
        }

        do {
            let result = try await PlaylistManager.shared.importAppleMusicPlaylist(from: trimmed)
            importReport = result.report
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }
}

// MARK: - Playlist Detail View (Apple Music Style)

public struct PlaylistDetailView: View {
    public let playlist: PersistedPlaylistEntity
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject var downloadManager: OfflineDownloadManager = .shared

    @State private var showEditSheet: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var editName: String = ""
    @State private var editDescription: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var customPhotoData: Data?

    public init(playlist: PersistedPlaylistEntity) {
        self.playlist = playlist
    }

    private var tracks: [UniversalTrack] {
        PlaylistManager.shared.resolveTracks(for: playlist)
    }

    public var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    if let customData = playlist.customCoverImageData,
                       let uiImage = UIImage(data: customData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 210, height: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    } else {
                        AuraArtworkView(
                            url: playlist.coverArtworkURLString.flatMap(URL.init(string:)) ?? tracks.first?.artworkURL,
                            size: 210,
                            cornerRadius: 14,
                            placeholderSymbol: playlist.isSmartPlaylist ? "gearshape.2.fill" : "music.note.list"
                        )
                    }

                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text(playlist.name)
                                .font(.system(size: 22, weight: .bold))
                                .multilineTextAlignment(.center)
                            if playlist.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(AuraTheme.accentPink)
                            }
                        }

                        if !playlist.playlistDescription.isEmpty {
                            Text(playlist.playlistDescription)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }

                        Text("\(tracks.count) Songs")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    // Play & Shuffle Action Buttons
                    HStack(spacing: 14) {
                        Button {
                            if let first = tracks.first {
                                player.isShuffled = false
                                player.play(first, queue: tracks)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.secondary.opacity(0.14))
                                )
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
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AuraTheme.accentPink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.secondary.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)

                    // Prominent One-Tap Download Entire Playlist Button (Full Audio + Synced Lyrics!)
                    if !tracks.isEmpty {
                        let summary = downloadManager.playlistDownloadSummary(for: tracks)
                        let allDone = summary.total > 0 && summary.completed == summary.total
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            downloadManager.enqueuePlaylistDownload(tracks: tracks)
                        } label: {
                            HStack(spacing: 8) {
                                if summary.active > 0 {
                                    ProgressView()
                                        .scaleEffect(0.85)
                                        .tint(AuraTheme.accentPink)
                                    Text("Скачивание плейлиста: \(summary.completed) / \(summary.total)")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(AuraTheme.accentPink)
                                } else if allDone {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.green)
                                    Text("Плейлист скачан офлайн (\(summary.completed)/\(summary.total))")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text(summary.completed > 0
                                         ? "Докачать плейлист (\(summary.total - summary.completed) осталось)"
                                         : "Скачать весь плейлист (\(summary.total))")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(allDone ? Color.green.opacity(0.16) : (summary.active > 0 ? AuraTheme.accentPink.opacity(0.14) : AuraTheme.accentPink))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                if tracks.isEmpty {
                    Text("No songs in this playlist yet. Add songs from Search, Browse, or import an Apple Music URL.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(tracks) { track in
                        HStack(spacing: 12) {
                            AuraArtworkView(url: persistence.effectiveArtworkURL(for: track), size: 46, cornerRadius: 7)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if player.currentTrack?.id == track.id {
                                        NowPlayingEqualizerBars(isPlaying: player.isPlaying)
                                    }
                                    Text(track.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(player.currentTrack?.id == track.id ? AuraTheme.accentPink : .primary)
                                        .lineLimit(1)
                                }
                                HStack(spacing: 6) {
                                    ProviderBadgePill(provider: track.provider)
                                    Text(track.artist)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            if downloadManager.isDownloaded(track) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.green)
                            } else if downloadManager.isDownloadingOrQueued(track) {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }

                            Text(track.formattedDuration)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(track, queue: tracks)
                        }
                    }
                    .onDelete { offsets in
                        guard !playlist.isSmartPlaylist else { return }
                        PlaylistManager.shared.removeTracks(at: offsets, from: playlist)
                    }
                    .onMove { source, destination in
                        guard !playlist.isSmartPlaylist else { return }
                        PlaylistManager.shared.moveTracks(from: source, to: destination, in: playlist)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !tracks.isEmpty {
                    let summary = downloadManager.playlistDownloadSummary(for: tracks)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        downloadManager.enqueuePlaylistDownload(tracks: tracks)
                    } label: {
                        Image(systemName: summary.completed == summary.total ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(summary.completed == summary.total ? Color.green : AuraTheme.accentPink)
                    }
                    .accessibilityLabel("Download Entire Playlist")
                }
                if !playlist.isSmartPlaylist {
                    EditButton()
                }
                Menu {
                    Button {
                        PlaylistManager.shared.toggleFavoritePlaylist(playlist)
                    } label: {
                        Label(
                            playlist.isFavorite ? "Remove from Favorites" : "Favorite Playlist",
                            systemImage: playlist.isFavorite ? "star.slash" : "star"
                        )
                    }

                    Button {
                        editName = playlist.name
                        editDescription = playlist.playlistDescription
                        showEditSheet = true
                    } label: {
                        Label("Edit Name, Description & Artwork", systemImage: "pencil")
                    }

                    Button {
                        downloadManager.enqueuePlaylistDownload(tracks: tracks)
                    } label: {
                        Label("Download Permitted Tracks Offline", systemImage: "arrow.down.circle")
                    }

                    Menu("Sort Songs") {
                        ForEach(PlaylistSortCriterion.allCases) { criterion in
                            Button(criterion.rawValue) {
                                PlaylistManager.shared.sortPlaylistTracks(playlist, by: criterion)
                            }
                        }
                    }

                    Button {
                        PlaylistManager.shared.duplicatePlaylist(playlist)
                    } label: {
                        Label("Duplicate Playlist", systemImage: "plus.square.on.square")
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share / Export Playlist Metadata", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AuraTheme.accentPink)
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            editPlaylistMetadataSheet
        }
        .sheet(isPresented: $showShareSheet) {
            SystemShareSheet(activityItems: [PlaylistManager.shared.exportPlaylistTextSummary(playlist)])
        }
    }

    private var editPlaylistMetadataSheet: some View {
        NavigationStack {
            Form {
                Section("Playlist Info") {
                    TextField("Playlist Title", text: $editName)
                    TextField("Description", text: $editDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Custom Cover Artwork") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Choose Artwork from Photos", systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                customPhotoData = data
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showEditSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PlaylistManager.shared.updateMetadata(
                            for: playlist,
                            name: editName,
                            description: editDescription,
                            customCoverData: customPhotoData
                        )
                        showEditSheet = false
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
