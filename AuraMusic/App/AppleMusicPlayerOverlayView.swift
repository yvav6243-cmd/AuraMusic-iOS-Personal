import Foundation
import PhotosUI
import SwiftUI

// MARK: - Isolated 120 FPS Sheet Drag Controller (Prevents Full Player Tree Re-Evaluation During Drag)

@MainActor
private final class PlayerSheetDragController: ObservableObject {
    @Published var dragOffset: CGFloat = 0

    func openExpandedPlayer() {
        dragOffset = 0
        withAnimation(AuraTheme.springPlayerSheet) {
            UniversalAudioPlayerEngine.shared.isPlayerExpanded = true
        }
    }

    func closeExpandedPlayer() {
        withAnimation(AuraTheme.springPlayerDismiss) {
            UniversalAudioPlayerEngine.shared.isPlayerExpanded = false
            dragOffset = 0
        }
    }

    func resetDragAnimated() {
        guard dragOffset != 0 else { return }
        withAnimation(AuraTheme.springPlayerSheet) {
            dragOffset = 0
        }
    }

    func handleDragChanged(translation: CGSize) {
        if translation.height > 8 && abs(translation.height) > abs(translation.width) * 1.2 {
            dragOffset = translation.height
        }
    }

    func handleDragEnded(translation: CGSize, predictedEndTranslation: CGSize) {
        if AppleMusicPlayerOverlayView.shouldDismissSheet(
            translationHeight: translation.height,
            predictedEndHeight: predictedEndTranslation.height,
            horizontalTranslation: translation.width
        ) {
            closeExpandedPlayer()
        } else {
            withAnimation(AuraTheme.springPlayerSheet) {
                dragOffset = 0
            }
        }
    }
}

/// Thin GPU-only compositor shell that observes `dragOffset` so dragging at 120Hz ONLY updates CoreAnimation
/// transform/opacity/corner-radius layers without EVER re-evaluating `MiniContent` or `SheetContent`!
private struct PlayerSheetAnimatedFrame<MiniContent: View, SheetContent: View>: View {
    let isExpanded: Bool
    let fullHeight: CGFloat
    @ObservedObject var dragController: PlayerSheetDragController
    let miniContent: MiniContent
    let sheetContent: SheetContent

    var body: some View {
        let activeDrag = max(0, dragController.dragOffset)
        let sheetOffsetY = AppleMusicPlayerOverlayView.sheetVerticalOffset(
            isExpanded: isExpanded,
            dragOffset: activeDrag,
            screenHeight: fullHeight
        )
        let dismissProgress = isExpanded ? min(1.0, activeDrag / max(fullHeight * 0.55, 1)) : 1.0
        let cardCornerRadius = AppleMusicPlayerOverlayView.sheetCornerRadius(
            isExpanded: isExpanded,
            dragOffset: activeDrag,
            screenHeight: fullHeight
        )

        ZStack(alignment: .bottom) {
            // Persistent Floating Mini-Player Bar: stays mounted cleanly in safe area so expanding/closing
            // smoothly fades & settles it without ever shooting the artwork icon off to the screen edge!
            miniContent
                .padding(.horizontal, 12)
                .padding(.bottom, 54)
                .opacity(isExpanded ? min(1.0, dismissProgress * 1.35) : 1.0)
                .scaleEffect(isExpanded ? (0.95 + 0.05 * dismissProgress) : 1.0, anchor: .bottom)
                .offset(y: isExpanded ? (12 * (1.0 - dismissProgress)) : 0)
                .allowsHitTesting(!isExpanded)
                .zIndex(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay {
            ZStack(alignment: .bottom) {
                // Soft dimming backdrop behind the sheet — lightens smoothly as user drags/closes
                Color.black
                    .opacity(isExpanded ? max(0, 0.48 * (1.0 - dismissProgress)) : 0)
                    .allowsHitTesting(isExpanded)
                    .zIndex(15)

                // Permanently-mounted Full-Screen Player Sheet driven by continuous GPU offset(y:):
                // guarantees 100% silky 120 FPS slide-up on open and slide-down on close — NEVER snaps or disappears abruptly!
                sheetContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(isExpanded && activeDrag > 2 ? 0.42 : 0.0), radius: 26, y: -4)
                    .offset(y: sheetOffsetY)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
                    .zIndex(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
        }
    }
}

// MARK: - Persistent Mini-Player & Expanded Full-Screen Player Container

public struct AppleMusicPlayerOverlayView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @StateObject private var dragController = PlayerSheetDragController()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    /// Computes an ideal responsive 1:1 album cover size so the expanded player never clips or crowds
    /// controls on iPhone SE / mini (small screens) while staying lush and full-sized on 6.1" and Pro Max models.
    public static func preferredExpandedArtworkSize(for containerSize: CGSize) -> CGFloat {
        let widthBound = max(180, containerSize.width - 56)
        let heightBound = max(190, containerSize.height * 0.36)
        return min(340, min(widthBound, heightBound))
    }

    /// Computes the continuous vertical sheet offset: `0` when resting expanded, `dragOffset` while pulling down,
    /// and `screenHeight + 32` (just below bottom edge) when collapsed — keeping the view mounted guarantees
    /// SwiftUI NEVER abruptly cuts off the dismiss animation!
    public static func sheetVerticalOffset(
        isExpanded: Bool,
        dragOffset: CGFloat,
        screenHeight: CGFloat
    ) -> CGFloat {
        isExpanded ? max(0, dragOffset) : (max(screenHeight, 568) + 32)
    }

    /// Computes progressive iOS sheet top corner radius as the user pulls or dismisses the expanded player downward.
    public static func sheetCornerRadius(
        isExpanded: Bool,
        dragOffset: CGFloat,
        screenHeight: CGFloat
    ) -> CGFloat {
        guard isExpanded else { return 38 }
        let clampedDrag = max(0, dragOffset)
        guard clampedDrag > 2 else { return 0 }
        let progress = min(1.0, clampedDrag / max(screenHeight * 0.45, 1))
        return min(44, 18 + progress * 26)
    }

    /// Determines whether a downward swipe (or fast downward flick) on the player handle should dismiss the player.
    public static func shouldDismissSheet(
        translationHeight: CGFloat,
        predictedEndHeight: CGFloat,
        horizontalTranslation: CGFloat
    ) -> Bool {
        let verticalDominant = abs(translationHeight) > abs(horizontalTranslation) * 1.1
        return verticalDominant && (translationHeight > 110 || predictedEndHeight > 260)
    }

    /// Full-screen vertical swipe-to-dismiss MUST only be enabled on the non-scrolling artwork view (`.none`).
    /// When `.lyrics` or `.upNext` is open, vertical drags in the content area belong 100% to the `ScrollView`
    /// so pulling lyrics up/down NEVER triggers player dismissal; users can still drag the top grabber/header to dismiss.
    public static func shouldAllowFullScreenSwipeDismiss(
        for activeOverlayTab: UniversalAudioPlayerEngine.ExpandedOverlayTab
    ) -> Bool {
        activeOverlayTab == .none
    }

    /// Keeps the iPhone display awake ONLY while the full-screen Lyrics mode is visibly open in the foreground,
    /// and immediately restores normal iOS Auto-Lock as soon as the user closes the player, switches tabs, or leaves the app.
    public static func shouldPreventScreenAutoLock(
        isPlayerExpanded: Bool,
        activeOverlayTab: UniversalAudioPlayerEngine.ExpandedOverlayTab,
        hasCurrentTrack: Bool,
        isAppActive: Bool
    ) -> Bool {
        isPlayerExpanded && activeOverlayTab == .lyrics && hasCurrentTrack && isAppActive
    }

    private var keepScreenAwakeForLyrics: Bool {
        Self.shouldPreventScreenAutoLock(
            isPlayerExpanded: player.isPlayerExpanded,
            activeOverlayTab: player.activeOverlayTab,
            hasCurrentTrack: player.currentTrack != nil,
            isAppActive: scenePhase == .active
        )
    }

    private func applyIdleTimerPolicy(_ preventAutoLock: Bool) {
        if UIApplication.shared.isIdleTimerDisabled != preventAutoLock {
            UIApplication.shared.isIdleTimerDisabled = preventAutoLock
        }
    }

    public var body: some View {
        GeometryReader { safeGeo in
            let safeTop = safeGeo.safeAreaInsets.top
            let safeBottom = safeGeo.safeAreaInsets.bottom
            let fullWidth = max(safeGeo.size.width + safeGeo.safeAreaInsets.leading + safeGeo.safeAreaInsets.trailing, 320)
            let fullHeight = max(safeGeo.size.height + safeTop + safeBottom, 568)
            let isExpanded = player.isPlayerExpanded

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
                    PlayerSheetAnimatedFrame(
                        isExpanded: isExpanded,
                        fullHeight: fullHeight,
                        dragController: dragController,
                        miniContent: FloatingMiniPlayerBarView(
                            track: track,
                            dragController: dragController
                        ),
                        sheetContent: ExpandedFullScreenPlayerSheetView(
                            track: track,
                            containerSize: CGSize(width: fullWidth, height: fullHeight),
                            safeTop: safeTop,
                            safeBottom: safeBottom,
                            isVisible: isExpanded,
                            dragController: dragController
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear {
            applyIdleTimerPolicy(keepScreenAwakeForLyrics)
        }
        .onChange(of: keepScreenAwakeForLyrics) { _, shouldPreventAutoLock in
            applyIdleTimerPolicy(shouldPreventAutoLock)
        }
        .onDisappear {
            applyIdleTimerPolicy(false)
        }
    }
}

// MARK: - 1. Isolated Floating Apple Music Mini-Player Bar

private struct FloatingMiniPlayerBarView: View {
    let track: UniversalTrack
    let dragController: PlayerSheetDragController

    @ObservedObject private var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject private var persistence: PersistenceController = .shared
    @State private var isPlayPauseCoolingDown: Bool = false
    @State private var playPauseCooldownResetTask: Task<Void, Never>?

    private func triggerPlayPause() {
        guard player.togglePlayPause() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isPlayPauseCoolingDown = true
        playPauseCooldownResetTask?.cancel()
        playPauseCooldownResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isPlayPauseCoolingDown = false
        }
    }

    var body: some View {
        let effectiveArt = persistence.effectiveArtworkURL(for: track) ?? track.artworkURL
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                AuraArtworkView(url: effectiveArt, size: 42, cornerRadius: 8)
                    .equatable()

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                dragController.openExpandedPlayer()
            }

            HStack(spacing: 6) {
                Button {
                    triggerPlayPause()
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
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -24 && abs(value.translation.height) > abs(value.translation.width) {
                        dragController.openExpandedPlayer()
                    }
                }
        )
        .onChange(of: track.id) { _, _ in
            playPauseCooldownResetTask?.cancel()
            isPlayPauseCoolingDown = false
        }
    }
}

// MARK: - 2. Isolated Full-Screen Expanded Apple Music Player Sheet

private struct ExpandedFullScreenPlayerSheetView: View {
    let track: UniversalTrack
    let containerSize: CGSize
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let isVisible: Bool
    let dragController: PlayerSheetDragController

    @ObservedObject private var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject private var persistence: PersistenceController = .shared
    @ObservedObject private var downloadManager: OfflineDownloadManager = .shared

    @State private var isPlayPauseCoolingDown: Bool = false
    @State private var playPauseCooldownResetTask: Task<Void, Never>?
    @State private var showAddToPlaylistSheet: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var showCustomCoverPicker: Bool = false
    @State private var showTrackTrimSheet: Bool = false
    @State private var selectedCoverPhotoItem: PhotosPickerItem?

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

    private var dismissHandleDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                dragController.handleDragChanged(translation: value.translation)
            }
            .onEnded { value in
                dragController.handleDragEnded(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
            }
    }

    var body: some View {
        let effectiveArt = persistence.effectiveArtworkURL(for: track) ?? track.artworkURL
        let artworkSize = AppleMusicPlayerOverlayView.preferredExpandedArtworkSize(for: containerSize)

        ZStack {
            DynamicArtworkMeshBackground(artworkURL: effectiveArt, isAnimating: isVisible && player.isPlaying)
                .equatable()

            VStack(spacing: 0) {
                // Top Dismiss Handle Zone (Grabber Pill + Compact Header) — always allows clean swipe-down to close
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.42))
                        .frame(width: 40, height: 5)
                        .padding(.top, max(safeTop, 14) + 6)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dragController.closeExpandedPlayer()
                        }

                    // Compact Header when Lyrics or Up Next is active
                    if player.activeOverlayTab != .none {
                        compactNowPlayingHeader(track: track, artworkURL: effectiveArt)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dismissHandleDragGesture)

                // Main Content Area: Standard Artwork View OR Synchronized Lyrics OR Up Next Queue
                Group {
                    switch player.activeOverlayTab {
                    case .none:
                        standardArtworkCenterSection(track: track, artworkURL: effectiveArt, artworkSize: artworkSize)
                            .contentShape(Rectangle())
                            .simultaneousGesture(dismissHandleDragGesture)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    case .lyrics:
                        SynchronizedLyricsView(player: player)
                            .transition(.opacity)
                    case .upNext:
                        upNextQueueOverlaySection(track: track)
                            .transition(.opacity)
                    }
                }
                .animation(AuraTheme.springInteractive, value: player.activeOverlayTab)

                Spacer(minLength: 8)

                // Track Info, Scrubber, Transport Controls & Bottom Mode Bar
                VStack(spacing: 16) {
                    if player.activeOverlayTab == .none {
                        trackTitleAndActionsRow(track: track)
                            .transition(.opacity)
                    }

                    ExpandedPlaybackScrubberView(track: track, player: player, isVisible: isVisible)

                    primaryTransportControls

                    volumeAndOutputSlider

                    bottomModeToggleButtons
                }
                .padding(.horizontal, 26)
                .padding(.bottom, max(safeBottom, 16) + 10)
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: track.id) { _, _ in
            playPauseCooldownResetTask?.cancel()
            isPlayPauseCoolingDown = false
        }
        .onChange(of: player.activeOverlayTab) { _, _ in
            dragController.resetDragAnimated()
        }
        .sheet(isPresented: $showAddToPlaylistSheet) {
            AddToPlaylistPickerSheet(track: track)
        }
        .sheet(isPresented: $showShareSheet) {
            SystemShareSheet(activityItems: ["\(track.title) — \(track.artist) [\(track.provider.displayName)]"])
        }
        .sheet(isPresented: $showTrackTrimSheet) {
            TrackTrimEditorSheet(track: track)
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

    private func standardArtworkCenterSection(track: UniversalTrack, artworkURL: URL?, artworkSize: CGFloat) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 4)

            AuraArtworkView(
                url: artworkURL,
                size: artworkSize,
                cornerRadius: AuraTheme.expandedArtworkCornerRadius,
                isPlayingElevated: player.isPlaying
            )
            .equatable()
            .scaleEffect(player.isPlaying ? 1.0 : 0.86)
            .animation(AuraTheme.springBouncy, value: player.isPlaying)

            // Live Synchronized Lyric Line Preview Pill (isolated from main player redraws -> 120 FPS!)
            LiveLyricPreviewPillView(isVisible: isVisible) {
                withAnimation(AuraTheme.springInteractive) {
                    player.activeOverlayTab = .lyrics
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 4)
        }
    }

    private func compactNowPlayingHeader(track: UniversalTrack, artworkURL: URL?) -> some View {
        let isFav = persistence.isTrackFavorite(track.id)
        return HStack(spacing: 12) {
            AuraArtworkView(url: artworkURL, size: 48, cornerRadius: 8)
                .equatable()
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
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                persistence.toggleFavorite(track)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isFav ? AuraTheme.accentPink : .white.opacity(0.8))
                    .symbolEffect(.bounce, value: isFav)
                    .padding(8)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(AuraTactileTransportButtonStyle())
        }
    }

    private func trackTitleAndActionsRow(track: UniversalTrack) -> some View {
        let isFav = persistence.isTrackFavorite(track.id)
        return HStack(alignment: .center, spacing: 12) {
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

                Text(track.artist)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(AuraTactileTransportButtonStyle())

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                persistence.toggleFavorite(track)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isFav ? AuraTheme.accentPink : .white)
                    .symbolEffect(.bounce, value: isFav)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(AuraTactileTransportButtonStyle())

            Menu {
                Button {
                    showTrackTrimSheet = true
                } label: {
                    let trimmed = persistence.hasCustomTrim(for: track)
                    Label(
                        trimmed ? "Изменить длину песни (обрезано)…" : "Изменить длину / Обрезать песню…",
                        systemImage: "scissors"
                    )
                }

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

                if downloadManager.isDownloaded(track) {
                    Button {
                        Task {
                            await downloadManager.syncOfflineLyricsForTrack(track)
                        }
                    } label: {
                        let needsUpdate = downloadManager.hasLyricsUpdateAvailable(for: track)
                        Label(
                            needsUpdate ? "Докачать обновлённую лирику" : "Обновить офлайн-лирику",
                            systemImage: needsUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath"
                        )
                    }
                } else if track.provider.supportsLegalOfflineDownload && track.isDownloadPermitted {
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
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(AuraTheme.springInteractive) {
                        player.toggleShuffle()
                    }
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
                .buttonStyle(AuraTactileTransportButtonStyle())

                // Repeat Cycle Toggle (Off / All / One)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(AuraTheme.springInteractive) {
                        player.cycleRepeatMode()
                    }
                } label: {
                    Image(systemName: player.repeatMode.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(player.repeatMode != .off ? Color.black : Color.white)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(player.repeatMode != .off ? Color.white : Color.white.opacity(0.16))
                        )
                }
                .buttonStyle(AuraTactileTransportButtonStyle())
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
                            AuraArtworkView(
                                url: persistence.effectiveArtworkURL(for: queuedTrack) ?? queuedTrack.artworkURL,
                                size: 44,
                                cornerRadius: 7
                            )
                            .equatable()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(queuedTrack.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(queuedTrack.artist)
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
            .scaleEffect(configuration.isPressed ? 0.89 : 1.0)
            .opacity(configuration.isPressed ? 0.80 : 1.0)
            .animation(AuraTheme.springSnappy, value: configuration.isPressed)
    }
}

private struct ExpandedPlaybackScrubberView: View {
    let track: UniversalTrack
    let player: UniversalAudioPlayerEngine
    let isVisible: Bool
    @ObservedObject private var clock: PlaybackClock = .shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isScrubbing: Bool = false
    @State private var scrubTimeValue: Double = 0

    var body: some View {
        let rawTotal = max(clock.duration, track.duration, 1)
        let bounds = player.displayPlaybackBounds(for: rawTotal)
        let displayTotal = max(bounds.duration, 1)
        let labelTime = isScrubbing
            ? scrubTimeValue
            : max(0, min(displayTotal, clock.currentTime - bounds.start))
        let remaining = max(0, displayTotal - labelTime)
        let shouldAnimateBar = isVisible && player.isPlaying && !player.isBuffering && !isScrubbing && scenePhase == .active

        VStack(spacing: 8) {
            SmoothAppleMusicScrubberBar(
                trimStart: bounds.start,
                totalDuration: displayTotal,
                rawTotalDuration: rawTotal,
                clock: clock,
                isPlaying: player.isPlaying,
                isBuffering: player.isBuffering,
                shouldAnimateBar: shouldAnimateBar,
                isScrubbing: $isScrubbing,
                scrubTimeValue: $scrubTimeValue,
                onCommitSeek: { displayTarget in
                    player.seek(to: bounds.start + displayTarget)
                }
            )

            HStack {
                Text(Self.formatSeconds(labelTime))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isScrubbing ? 0.95 : 0.65))

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
/// - Glides smoothly at 60 FPS via O(1) wall-clock linear interpolation between 4–5Hz engine ticks (~0.15% CPU)
/// - Displays trim-relative elapsed time (`0:00 → newLength`) seamlessly as if the trimmed track were the original
/// - Automatically pauses TimelineView (0% CPU) when collapsed, paused, buffering, scrubbing, or backgrounded
/// - Never triggers PlaybackClock or UniversalAudioPlayerEngine invalidations
private struct SmoothAppleMusicScrubberBar: View {
    let trimStart: TimeInterval
    let totalDuration: TimeInterval
    let rawTotalDuration: TimeInterval
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

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shouldAnimateBar)) { _ in
                let rawInterpolated = clock.interpolatedTime(
                    isPlaying: isPlaying,
                    isBuffering: isBuffering,
                    fallbackDuration: rawTotalDuration
                )
                let displayTime: TimeInterval = isScrubbing
                    ? scrubTimeValue
                    : max(0, min(totalDuration, rawInterpolated - trimStart))
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
                .animation(AuraTheme.springSnappy, value: isScrubbing)
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
    let isVisible: Bool
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
                        .contentTransition(.opacity)
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
            .animation(.easeInOut(duration: 0.22), value: displayedLine)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.16))
            )
        }
        .buttonStyle(AuraTactileTransportButtonStyle())
        .onAppear {
            guard isVisible else { return }
            displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
        }
        .onChange(of: isVisible) { _, nowVisible in
            if nowVisible {
                displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
            }
        }
        .onChange(of: lyricsService.currentDocument?.id) { _, _ in
            guard isVisible else { return }
            displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
        }
        .onChange(of: lyricsService.customDocument?.id) { _, _ in
            guard isVisible else { return }
            displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
        }
        .onChange(of: lyricsService.lyricsMode) { _, _ in
            guard isVisible else { return }
            displayedLine = lyricsService.activeLyricLineText(at: PlaybackClock.shared.currentTime)
        }
        .onReceive(PlaybackClock.shared.$currentTime) { newTime in
            // Skip lyric line lookups completely when the full-screen sheet is collapsed (0% background CPU!)
            guard isVisible else { return }
            let nextLine = lyricsService.activeLyricLineText(at: newTime)
            if nextLine != displayedLine {
                displayedLine = nextLine
            }
        }
    }
}

// MARK: - Persistent Song Length / Trim Editor Sheet (Start & End Cut Settings)

public struct TrackTrimEditorSheet: View {
    public let track: UniversalTrack

    @ObservedObject private var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject private var persistence: PersistenceController = .shared
    @Environment(\.dismiss) private var dismiss

    @State private var startSeconds: Double = 0
    @State private var endSeconds: Double = 180
    @State private var totalDuration: Double = 180

    public init(track: UniversalTrack) {
        self.track = track
    }

    private var trimmedLength: Double {
        max(TrackTrimRange.minimumSegmentLength, endSeconds - startSeconds)
    }

    private var isModified: Bool {
        startSeconds >= 0.5 || endSeconds < (totalDuration - 0.5)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AuraArtworkView(url: persistence.effectiveArtworkURL(for: track), size: 54, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("Оригинал: \(TrackTrimRange.formatClock(totalDuration)) → Новая длина: \(TrackTrimRange.formatClock(trimmedLength))")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(AuraTheme.accentPink)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)

                    // Visual Active Segment Range Bar
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let safeTotal = max(totalDuration, 1)
                        let startFrac = max(0, min(1, startSeconds / safeTotal))
                        let endFrac = max(startFrac, min(1, endSeconds / safeTotal))
                        let activeWidth = max(6, w * CGFloat(endFrac - startFrac))

                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.22))
                                .frame(height: 12)

                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [AuraTheme.accentPink, Color.purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: activeWidth, height: 12)
                                .offset(x: w * CGFloat(startFrac))
                        }
                    }
                    .frame(height: 18)
                } header: {
                    Text("Длина и обрезка трека")
                } footer: {
                    Text("Выбранные границы запоминаются для этой песни навсегда: трек начнётся с «Начала» и автоматически завершится на «Конце».")
                }

                Section("Начало трека: \(TrackTrimRange.formatClock(startSeconds))") {
                    Slider(
                        value: Binding(
                            get: { startSeconds },
                            set: { newVal in
                                let maxAllowed = max(0, endSeconds - TrackTrimRange.minimumSegmentLength)
                                startSeconds = max(0, min(newVal, maxAllowed))
                            }
                        ),
                        in: 0...max(TrackTrimRange.minimumSegmentLength, totalDuration)
                    )
                    .tint(AuraTheme.accentPink)

                    HStack(spacing: 10) {
                        Button("-1с") {
                            startSeconds = max(0, startSeconds - 1.0)
                        }
                        .buttonStyle(.bordered)

                        Button("+1с") {
                            let maxAllowed = max(0, endSeconds - TrackTrimRange.minimumSegmentLength)
                            startSeconds = min(maxAllowed, startSeconds + 1.0)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if player.currentTrack?.id == track.id {
                            Button("Взять текущее (\(TrackTrimRange.formatClock(PlaybackClock.shared.currentTime)))") {
                                let maxAllowed = max(0, endSeconds - TrackTrimRange.minimumSegmentLength)
                                startSeconds = max(0, min(PlaybackClock.shared.currentTime, maxAllowed))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AuraTheme.accentPink)
                        }
                    }
                }

                Section("Конец трека: \(TrackTrimRange.formatClock(endSeconds))") {
                    Slider(
                        value: Binding(
                            get: { endSeconds },
                            set: { newVal in
                                let minAllowed = min(totalDuration, startSeconds + TrackTrimRange.minimumSegmentLength)
                                endSeconds = max(minAllowed, min(newVal, totalDuration))
                            }
                        ),
                        in: 0...max(TrackTrimRange.minimumSegmentLength, totalDuration)
                    )
                    .tint(AuraTheme.accentPink)

                    HStack(spacing: 10) {
                        Button("-1с") {
                            let minAllowed = min(totalDuration, startSeconds + TrackTrimRange.minimumSegmentLength)
                            endSeconds = max(minAllowed, endSeconds - 1.0)
                        }
                        .buttonStyle(.bordered)

                        Button("+1с") {
                            endSeconds = min(totalDuration, endSeconds + 1.0)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if player.currentTrack?.id == track.id {
                            Button("Взять текущее (\(TrackTrimRange.formatClock(PlaybackClock.shared.currentTime)))") {
                                let minAllowed = min(totalDuration, startSeconds + TrackTrimRange.minimumSegmentLength)
                                endSeconds = max(minAllowed, min(PlaybackClock.shared.currentTime, totalDuration))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AuraTheme.accentPink)
                        }
                    }
                }

                Section("Предпрослушивание") {
                    Button {
                        if player.currentTrack?.id != track.id {
                            player.play(track)
                        }
                        player.seek(to: startSeconds)
                        if !player.isPlaying { player.resume() }
                    } label: {
                        Label("Слушать с нового начала (\(TrackTrimRange.formatClock(startSeconds)))", systemImage: "play.circle.fill")
                            .foregroundStyle(AuraTheme.accentPink)
                    }

                    Button {
                        if player.currentTrack?.id != track.id {
                            player.play(track)
                        }
                        let previewPos = max(startSeconds, endSeconds - 5.0)
                        player.seek(to: previewPos)
                        if !player.isPlaying { player.resume() }
                    } label: {
                        Label("Проверить концовку (за 5 сек до \(TrackTrimRange.formatClock(endSeconds)))", systemImage: "forward.end.circle.fill")
                            .foregroundStyle(AuraTheme.accentPink)
                    }
                }

                if isModified || persistence.hasCustomTrim(for: track) {
                    Section {
                        Button(role: .destructive) {
                            startSeconds = 0
                            endSeconds = totalDuration
                            persistence.setTrimRange(nil, for: track)
                            player.applyUpdatedTrimRange(nil, for: track)
                            dismiss()
                        } label: {
                            Label("Сбросить к полной длине песни", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .navigationTitle("Настройки длины песни")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let rawRange = TrackTrimRange(
                            startSeconds: startSeconds,
                            endSeconds: endSeconds < (totalDuration - 0.5) ? endSeconds : nil
                        )
                        let normalized = rawRange.normalized(for: totalDuration)
                        let toStore: TrackTrimRange? = normalized.isEffectivelyTrimmed(for: totalDuration) ? normalized : nil
                        persistence.setTrimRange(toStore, for: track)
                        player.applyUpdatedTrimRange(toStore, for: track)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AuraTheme.accentPink)
                }
            }
            .onAppear {
                let detectedTotal: Double
                if player.currentTrack?.id == track.id, PlaybackClock.shared.duration > 5 {
                    detectedTotal = PlaybackClock.shared.duration
                } else {
                    detectedTotal = max(track.duration, 30.0)
                }
                totalDuration = detectedTotal
                if let saved = persistence.trimRange(for: track) {
                    let norm = saved.normalized(for: detectedTotal)
                    startSeconds = norm.startSeconds
                    endSeconds = norm.endSeconds ?? detectedTotal
                } else {
                    startSeconds = 0
                    endSeconds = detectedTotal
                }
            }
        }
    }
}
