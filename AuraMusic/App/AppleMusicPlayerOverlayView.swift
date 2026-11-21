import Foundation
import PhotosUI
import SwiftUI

// MARK: - Persistent Mini-Player & Expanded Full-Screen Player Container

public struct AppleMusicPlayerOverlayView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var downloadManager: OfflineDownloadManager = .shared

    @Namespace private var playerAnimationNamespace
    @State private var dragOffset: CGFloat = 0
    @State private var showAddToPlaylistSheet: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var showCustomCoverPicker: Bool = false
    @State private var selectedCoverPhotoItem: PhotosPickerItem?

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Single persistent YouTube Music engine instance — kept inside screen bounds so iOS WebKit never throttles timers, 100% invisible
            if let videoID = player.activeYouTubeVideoID {
                AuthorizedYouTubeIFramePlayerView(videoID: videoID)
                    .frame(width: 8, height: 8)
                    .opacity(0.005)
                    .allowsHitTesting(false)
                    .zIndex(-10)
            }

            if let track = player.currentTrack {
                if player.isPlayerExpanded {
                    expandedFullScreenPlayer(track: track)
                        .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .bottom)))
                        .zIndex(20)
                } else {
                    floatingMiniPlayerBar(track: track)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 54)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
        }
        .animation(AuraTheme.springInteractive, value: player.isPlayerExpanded)
    }

    // MARK: - 1. Floating Apple Music Mini-Player Bar

    private func floatingMiniPlayerBar(track: UniversalTrack) -> some View {
        HStack(spacing: 12) {
            AuraArtworkView(url: track.artworkURL, size: 42, cornerRadius: 8)
                .matchedGeometryEffect(id: "playerArtwork", in: playerAnimationNamespace)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("• \(track.provider.shortBadgeName)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(track.provider.badgeColor)
                }
            }

            Spacer()

            HStack(spacing: 18) {
                Button {
                    player.togglePlayPause()
                } label: {
                    if player.isBuffering {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    player.skipToNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 6)
        }
        .padding(.horizontal, 10)
        .frame(height: AuraTheme.miniPlayerHeight)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(AuraTheme.springInteractive) {
                player.isPlayerExpanded = true
            }
        }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -25 {
                        withAnimation(AuraTheme.springInteractive) {
                            player.isPlayerExpanded = true
                        }
                    }
                }
        )
    }

    // MARK: - 2. Full-Screen Expanded Apple Music Player

    private func expandedFullScreenPlayer(track: UniversalTrack) -> some View {
        ZStack {
            DynamicArtworkMeshBackground(artworkURL: track.artworkURL, isAnimating: player.isPlaying)
                .equatable()

            VStack(spacing: 0) {
                // Grabber Pill
                Capsule()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 38, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .onTapGesture {
                        withAnimation(AuraTheme.springInteractive) {
                            player.isPlayerExpanded = false
                        }
                    }

                // Compact Header when Lyrics or Up Next is active
                if player.activeOverlayTab != .none {
                    compactNowPlayingHeader(track: track)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                // Main Content Area: Standard Artwork View OR Synchronized Lyrics OR Up Next Queue
                switch player.activeOverlayTab {
                case .none:
                    standardArtworkCenterSection(track: track)
                case .lyrics:
                    SynchronizedLyricsView(player: player)
                case .upNext:
                    upNextQueueOverlaySection(track: track)
                }

                Spacer(minLength: 10)

                // Track Info, Scrubber, Transport Controls & Bottom Mode Bar
                VStack(spacing: 18) {
                    if player.activeOverlayTab == .none {
                        trackTitleAndActionsRow(track: track)
                    }

                    ExpandedPlaybackScrubberView(track: track, player: player)

                    primaryTransportControls

                    volumeAndOutputSlider

                    bottomModeToggleButtons
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 28)
            }
            .offset(y: max(0, dragOffset))
        }
        .environment(\.colorScheme, .dark)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 130 {
                        withAnimation(AuraTheme.springInteractive) {
                            dragOffset = 0
                            player.isPlayerExpanded = false
                        }
                    } else {
                        withAnimation(AuraTheme.springInteractive) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .sheet(isPresented: $showAddToPlaylistSheet) {
            AddToPlaylistPickerSheet(track: track)
        }
        .sheet(isPresented: $showShareSheet) {
            SystemShareSheet(activityItems: ["\(track.title) — \(track.artist) [\(track.provider.displayName)]"])
        }
        .photosPicker(isPresented: $showCustomCoverPicker, selection: $selectedCoverPhotoItem, matching: .images)
        .onChange(of: selectedCoverPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let newURL = persistence.setCustomTrackArtwork(
                        imageData: data,
                        for: track,
                        defaultArtworkURL: track.artworkURL
                    )
                    player.applyUpdatedArtworkURL(newURL, forTrackID: track.id)
                }
            }
        }
    }

    // MARK: - Center Artwork / Pure Apple Music Square Cover Section

    private func standardArtworkCenterSection(track: UniversalTrack) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 6)

            AuraArtworkView(
                url: track.artworkURL,
                size: 315,
                cornerRadius: AuraTheme.expandedArtworkCornerRadius,
                isPlayingElevated: player.isPlaying
            )
            .matchedGeometryEffect(id: "playerArtwork", in: playerAnimationNamespace)
            .scaleEffect(player.isPlaying ? 1.0 : 0.84)
            .animation(AuraTheme.springBouncy, value: player.isPlaying)

            if let banner = player.playbackStatusBanner {
                Text(banner)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            // Live Synchronized Lyric Line Preview Pill (isolated from main player redraws -> 120 FPS!)
            LiveLyricPreviewPillView {
                withAnimation(AuraTheme.springInteractive) {
                    player.activeOverlayTab = .lyrics
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 4)
        }
    }

    private func compactNowPlayingHeader(track: UniversalTrack) -> some View {
        HStack(spacing: 12) {
            AuraArtworkView(url: track.artworkURL, size: 48, cornerRadius: 8)
                .matchedGeometryEffect(id: "playerArtwork", in: playerAnimationNamespace)
                .onTapGesture {
                    withAnimation(AuraTheme.springInteractive) {
                        player.activeOverlayTab = .none
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                persistence.toggleFavorite(track)
            } label: {
                Image(systemName: persistence.isTrackFavorite(track.id) ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(persistence.isTrackFavorite(track.id) ? AuraTheme.accentPink : .white.opacity(0.8))
                    .padding(8)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
        }
    }

    private func trackTitleAndActionsRow(track: UniversalTrack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if track.explicit {
                        Text("E")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.22)))
                    }
                }

                HStack(spacing: 8) {
                    Text(track.artist)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)

                    Text(track.audioQualityBadge ?? track.provider.shortBadgeName)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.18)))
                }
            }

            Spacer()

            // Direct 1-Tap Offline Download Button on Expanded Player
            Button {
                downloadManager.enqueueDownload(for: track)
            } label: {
                let isDownloaded = downloadManager.isDownloaded(track.id)
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isDownloaded ? Color.green : .white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.16)))
            }

            Button {
                persistence.toggleFavorite(track)
            } label: {
                Image(systemName: persistence.isTrackFavorite(track.id) ? "star.fill" : "star")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(persistence.isTrackFavorite(track.id) ? AuraTheme.accentPink : .white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.16)))
            }

            Menu {
                Button {
                    showCustomCoverPicker = true
                } label: {
                    Label("Change Song Cover (Photos)…", systemImage: "photo.badge.plus")
                }

                if persistence.hasCustomArtwork(for: track.id) {
                    Button {
                        let restoredURL = persistence.setCustomTrackArtwork(imageData: nil, for: track)
                        player.applyUpdatedArtworkURL(restoredURL, forTrackID: track.id)
                    } label: {
                        Label("Reset to Default Album Cover", systemImage: "arrow.counterclockwise")
                    }
                }

                Divider()

                Button {
                    persistence.upsertTrack(track, addToLibrary: true)
                } label: {
                    Label("Add to Library", systemImage: "plus")
                }

                Button {
                    showAddToPlaylistSheet = true
                } label: {
                    Label("Add to a Playlist…", systemImage: "text.badge.plus")
                }

                if track.provider.supportsLegalOfflineDownload && track.isDownloadPermitted {
                    Button {
                        downloadManager.enqueueDownload(for: track)
                    } label: {
                        Label("Download Offline", systemImage: "arrow.down.circle")
                    }
                }

                if let deepLink = track.externalDeepLink {
                    Button {
                        UIApplication.shared.open(deepLink)
                    } label: {
                        Label("Open in \(track.provider.displayName)", systemImage: "arrow.up.forward.app")
                    }
                }

                Menu("Sleep Timer") {
                    Button("Off") { player.setSleepTimer(minutes: nil) }
                    Button("15 Minutes") { player.setSleepTimer(minutes: 15) }
                    Button("30 Minutes") { player.setSleepTimer(minutes: 30) }
                    Button("60 Minutes") { player.setSleepTimer(minutes: 60) }
                }

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share Song…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
        }
    }

    // MARK: - Transport Controls

    private var primaryTransportControls: some View {
        HStack(spacing: 52) {
            Button {
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                if player.isBuffering {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
            }
            .buttonStyle(.plain)

            Button {
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var volumeAndOutputSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))

            Slider(value: $player.volume, in: 0...1)
                .tint(.white)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var bottomModeToggleButtons: some View {
        HStack {
            // Synchronized Lyrics Toggle
            Button {
                withAnimation(AuraTheme.springInteractive) {
                    player.activeOverlayTab = (player.activeOverlayTab == .lyrics) ? .none : .lyrics
                }
            } label: {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(player.activeOverlayTab == .lyrics ? Color.black : Color.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(player.activeOverlayTab == .lyrics ? Color.white : Color.clear)
                    )
            }

            Spacer()

            // Native AirPlay / Bluetooth Audio Route Picker
            AirPlayRoutePickerButton(tintColor: .white)
                .frame(width: 40, height: 40)

            Spacer()

            // Up Next Queue Toggle
            Button {
                withAnimation(AuraTheme.springInteractive) {
                    player.activeOverlayTab = (player.activeOverlayTab == .upNext) ? .none : .upNext
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(player.activeOverlayTab == .upNext ? Color.black : Color.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(player.activeOverlayTab == .upNext ? Color.white : Color.clear)
                    )
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Up Next Queue Overlay (Shuffle, Repeat, Drag-and-Drop Queue)

    private func upNextQueueOverlaySection(track: UniversalTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playing Next")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // Shuffle Toggle
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(player.isShuffled ? Color.black : Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(player.isShuffled ? Color.white : Color.white.opacity(0.16))
                        )
                }

                // Repeat Cycle Toggle (Off / All / One)
                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: player.repeatMode.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(player.repeatMode != .off ? Color.black : Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(player.repeatMode != .off ? Color.white : Color.white.opacity(0.16))
                        )
                }
            }
            .padding(.horizontal, 24)

            if player.upNextQueue.isEmpty {
                Spacer()
                Text("No upcoming tracks in queue. Add songs with 'Play Next' or play a playlist/chart.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                List {
                    ForEach(player.upNextQueue) { queuedTrack in
                        HStack(spacing: 12) {
                            AuraArtworkView(url: queuedTrack.artworkURL, size: 44, cornerRadius: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(queuedTrack.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("\(queuedTrack.artist) • \(queuedTrack.provider.shortBadgeName)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(queuedTrack, queue: player.upNextQueue)
                        }
                    }
                    .onDelete { offsets in
                        player.removeFromQueue(at: offsets)
                    }
                    .onMove { source, destination in
                        player.moveQueueItem(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        guard value.isFinite && value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Isolated 120 FPS Leaf Subviews (Only these re-render on PlaybackClock ticks!)

private struct ExpandedPlaybackScrubberView: View {
    let track: UniversalTrack
    let player: UniversalAudioPlayerEngine
    @ObservedObject private var clock: PlaybackClock = .shared

    @State private var isScrubbing: Bool = false
    @State private var scrubTimeValue: Double = 0

    var body: some View {
        let total = max(clock.duration, track.duration, 1)
        let activeValue = isScrubbing ? scrubTimeValue : min(clock.currentTime, total)
        let remaining = max(0, total - activeValue)

        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { activeValue },
                    set: { newValue in
                        isScrubbing = true
                        scrubTimeValue = newValue
                    }
                ),
                in: 0...total,
                onEditingChanged: { editing in
                    if !editing {
                        player.seek(to: scrubTimeValue)
                        isScrubbing = false
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(Self.formatSeconds(activeValue))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))

                Spacer()

                Text(track.provider.shortBadgeName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))

                Spacer()

                Text("-\(Self.formatSeconds(remaining))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        guard value.isFinite && value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct LiveLyricPreviewPillView: View {
    let onTap: () -> Void
    @ObservedObject private var lyricsService: LyricsService = .shared
    @State private var displayedLine: String? = nil

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                if let activeLine = displayedLine {
                    Text(activeLine)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else if lyricsService.isLoading {
                    Text("Loading Synchronized Lyrics…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    Text("View Full-Screen Lyrics")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.16))
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
        }
        .onChange(of: lyricsService.currentDocument?.id) { _, _ in
            displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
        }
        .onReceive(PlaybackClock.shared.$currentTime) { newTime in
            let nextLine = lyricsService.activeLyricLineText(at: newTime)
            if nextLine != displayedLine {
                displayedLine = nextLine
            }
        }
    }
}
