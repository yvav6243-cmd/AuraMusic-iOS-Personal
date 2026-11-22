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
    @State private var isPlayPauseCoolingDown: Bool = false
    @State private var playPauseCooldownResetTask: Task<Void, Never>?
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
        .onChange(of: player.currentTrack?.id) { _, _ in
            playPauseCooldownResetTask?.cancel()
            isPlayPauseCoolingDown = false
        }
    }

    private func triggerPlayPauseWithCooldownFeedback(hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard player.togglePlayPause() else { return }
        UIImpactFeedbackGenerator(style: hapticStyle).impactOccurred()
        isPlayPauseCoolingDown = true
        playPauseCooldownResetTask?.cancel()
        playPauseCooldownResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isPlayPauseCoolingDown = false
        }
    }

    // MARK: - 1. Floating Apple Music Mini-Player Bar

    private func floatingMiniPlayerBar(track: UniversalTrack) -> some View {
        HStack(spacing: 10) {
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

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(AuraTheme.springInteractive) {
                    player.isPlayerExpanded = true
                }
            }

            HStack(spacing: 6) {
                Button {
                    triggerPlayPauseWithCooldownFeedback(hapticStyle: .light)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 40, height: 40)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.primary)
                            .offset(x: player.isPlaying ? 0 : 1)
                            .contentTransition(.symbolEffect(.replace))
                        if player.isBuffering {
                            ProgressView()
                                .scaleEffect(0.6)
                                .offset(x: 14, y: -13)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
                    .opacity(isPlayPauseCoolingDown ? 0.72 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isPlayPauseCoolingDown)
                }
                .buttonStyle(AuraTactileTransportButtonStyle())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    player.skipToNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AuraTactileTransportButtonStyle())
            }
            .padding(.trailing, 2)
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height < -30 && abs(value.translation.height) > abs(value.translation.width) {
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 32)
                .onChanged { value in
                    if value.translation.height > 20 && abs(value.translation.height) > abs(value.translation.width) * 1.4 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 130 && abs(value.translation.height) > abs(value.translation.width) * 1.2 {
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
            Task { @MainActor in
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let newURL = persistence.setCustomTrackArtwork(
                        imageData: data,
                        for: track,
                        defaultArtworkURL: track.artworkURL
                    )
                    player.applyUpdatedArtworkURL(newURL, forTrackID: track.id)
                }
                selectedCoverPhotoItem = nil
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

            // Direct 1-Tap Offline Download Button on Expanded Player (Full Audio + Synced Lyrics!)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                downloadManager.enqueueDownload(for: track)
            } label: {
                let isDownloaded = downloadManager.isDownloaded(track)
                let isDownloading = downloadManager.isDownloadingOrQueued(track)
                ZStack {
                    if isDownloading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(isDownloaded ? Color.green : .white)
                    }
                }
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

                if persistence.hasCustomArtwork(for: track) {
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
        HStack(spacing: 38) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(AuraTactileTransportButtonStyle())

            Button {
                triggerPlayPauseWithCooldownFeedback(hapticStyle: .medium)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 76, height: 76)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))

                    if player.isBuffering {
                        ProgressView()
                            .tint(.white.opacity(0.85))
                            .scaleEffect(0.75)
                            .offset(y: 27)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: 78, height: 78)
                .contentShape(Circle())
                .opacity(isPlayPauseCoolingDown ? 0.72 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isPlayPauseCoolingDown)
            }
            .buttonStyle(AuraTactileTransportButtonStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(AuraTactileTransportButtonStyle())
        }
        .padding(.vertical, 2)
    }

    private var volumeAndOutputSlider: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                SystemVolumeController.shared.stepVolume(by: -0.10)
            } label: {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AuraTactileTransportButtonStyle())
            .accessibilityLabel("Decrease Volume")

            #if targetEnvironment(simulator)
            Slider(value: $player.volume, in: 0...1)
                .tint(.white)
            #else
            HardwareVolumeSliderBridge()
                .frame(height: 30)
            #endif

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                SystemVolumeController.shared.stepVolume(by: 0.10)
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AuraTactileTransportButtonStyle())
            .accessibilityLabel("Increase Volume")
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

private struct AuraTactileTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ExpandedPlaybackScrubberView: View {
    let track: UniversalTrack
    let player: UniversalAudioPlayerEngine
    @ObservedObject private var clock: PlaybackClock = .shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isScrubbing: Bool = false
    @State private var scrubTimeValue: Double = 0

    var body: some View {
        let total = max(clock.duration, track.duration, 1)
        let labelTime = isScrubbing ? scrubTimeValue : min(clock.currentTime, total)
        let remaining = max(0, total - labelTime)
        let shouldAnimateBar = player.isPlaying && !player.isBuffering && !isScrubbing && scenePhase == .active

        VStack(spacing: 8) {
            SmoothAppleMusicScrubberBar(
                totalDuration: total,
                clock: clock,
                isPlaying: player.isPlaying,
                isBuffering: player.isBuffering,
                shouldAnimateBar: shouldAnimateBar,
                isScrubbing: $isScrubbing,
                scrubTimeValue: $scrubTimeValue,
                onCommitSeek: { target in
                    player.seek(to: target)
                }
            )

            HStack {
                Text(Self.formatSeconds(labelTime))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isScrubbing ? 0.95 : 0.65))

                Spacer()

                Text(track.provider.shortBadgeName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))

                Spacer()

                Text("-\(Self.formatSeconds(remaining))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isScrubbing ? 0.95 : 0.65))
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

/// Ultra-lightweight Apple Music smooth progress bar:
/// - Glides smoothly at 30 FPS via O(1) wall-clock linear interpolation between 4–5Hz engine ticks (~0.1% CPU)
/// - Automatically pauses TimelineView (0% CPU) when paused, buffering, scrubbing, or backgrounded
/// - Never triggers PlaybackClock or UniversalAudioPlayerEngine invalidations
private struct SmoothAppleMusicScrubberBar: View {
    let totalDuration: TimeInterval
    let clock: PlaybackClock
    let isPlaying: Bool
    let isBuffering: Bool
    let shouldAnimateBar: Bool
    @Binding var isScrubbing: Bool
    @Binding var scrubTimeValue: Double
    let onCommitSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let barHeight: CGFloat = isScrubbing ? 10 : 6

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimateBar)) { _ in
                let displayTime: TimeInterval = isScrubbing
                    ? scrubTimeValue
                    : clock.interpolatedTime(
                        isPlaying: isPlaying,
                        isBuffering: isBuffering,
                        fallbackDuration: totalDuration
                    )
                let progress = max(0, min(1, totalDuration > 0 ? displayTime / totalDuration : 0))
                let fillWidth = max(barHeight, width * CGFloat(progress))

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.24))
                        .frame(height: barHeight)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isScrubbing ? 1.0 : 0.92))
                        .frame(width: progress <= 0.0005 ? 0 : fillWidth, height: barHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isScrubbing)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let ratio = max(0, min(1, value.location.x / width))
                        scrubTimeValue = Double(ratio) * totalDuration
                    }
                    .onEnded { value in
                        let ratio = max(0, min(1, value.location.x / width))
                        let target = Double(ratio) * totalDuration
                        scrubTimeValue = target
                        onCommitSeek(target)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 28)
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
