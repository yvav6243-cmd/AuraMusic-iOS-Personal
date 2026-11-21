import AVFoundation
import Combine
import Foundation
import MediaPlayer
import MusicKit
import SwiftUI
import UIKit
import WebKit

@MainActor
public final class UniversalAudioPlayerEngine: ObservableObject {
    public static let shared = UniversalAudioPlayerEngine()

    // MARK: - Published Playback State

    @Published public private(set) var currentTrack: UniversalTrack?
    @Published public var upNextQueue: [UniversalTrack] = []
    @Published public private(set) var playbackHistory: [UniversalTrack] = []
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isBuffering: Bool = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public var volume: Float = 0.85 {
        didSet {
            primaryPlayer.volume = volume
            let ytPercent = Int((volume * 100).rounded())
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.setVolume(\(ytPercent));}")
        }
    }
    @Published public var isShuffled: Bool = false
    @Published public var repeatMode: RepeatMode = .off
    @Published public var isPlayerExpanded: Bool = false
    @Published public var activeOverlayTab: ExpandedOverlayTab = .none
    @Published public var activeYouTubeVideoID: String? = nil
    /// False by default so YouTube Music plays in pure Apple Music square-artwork Audio mode; user can toggle Video Clip mode if desired.
    @Published public var isYouTubeVideoVisible: Bool = false
    @Published public var playbackStatusBanner: String? = nil

    // MARK: - Audio Enhancement Settings

    @Published public var crossfadeSeconds: Double = 3.0
    @Published public var isGaplessEnabled: Bool = true
    @Published public var equalizerPreset: EqualizerPreset = .flat
    @Published public var customEQBands: [Float] = [0, 0, 0, 0, 0, 0]
    @Published public var streamingQuality: AudioStreamingQuality = .highQuality
    @Published public private(set) var sleepTimerRemainingSeconds: Int? = nil

    public enum ExpandedOverlayTab: String, CaseIterable {
        case none
        case lyrics
        case upNext
    }

    // MARK: - Internal Audio Players & Observers

    private var primaryPlayer = AVPlayer()
    private var crossfadeSecondaryPlayer: AVPlayer?
    private weak var youtubeWebView: WKWebView?
    private var timeObserverToken: Any?
    private var endOfTrackCancellable: AnyCancellable?
    private var itemStatusObservation: NSKeyValueObservation?
    private var sleepTimerTask: Task<Void, Never>?
    private var youtubeWatchdogTask: Task<Void, Never>?
    private var crossfadeTriggeredForCurrentItem = false

    private let appleProvider = AppleMusicProvider()
    private let audiusProvider = AudiusProvider()
    private let ytMusicProvider = YouTubeMusicProvider(providerType: .youtubeMusic)
    private let soundCloudProvider = SoundCloudProvider()
    private let matcher = TrackMatchingEngine()

    private init() {
        configureAudioSession()
        configureRemoteCommandCenter()
        configureAudioNotifications()
        attachPeriodicTimeObserver()
    }

    // MARK: - YouTube IFrame JS Bridge Handlers

    public func registerYouTubeWebView(_ webView: WKWebView) {
        self.youtubeWebView = webView
    }

    public func handleYouTubePlayerEvent(currentTime: Double, duration: Double, stateCode: Int) {
        guard activeYouTubeVideoID != nil else { return }
        if currentTime.isFinite && currentTime >= 0 && abs(currentTime - self.currentTime) >= 0.22 {
            self.currentTime = currentTime
        }
        if duration.isFinite && duration > 0 && abs(duration - self.duration) >= 0.5 {
            self.duration = duration
        }
        // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering
        switch stateCode {
        case 1: // PLAYING
            if !self.isPlaying || self.isBuffering {
                self.isPlaying = true
                self.isBuffering = false
                updateNowPlayingElapsedTime()
            }
        case 2: // PAUSED
            if self.isPlaying || self.isBuffering {
                self.isPlaying = false
                self.isBuffering = false
                updateNowPlayingElapsedTime()
            }
        case 3: // BUFFERING
            if !self.isBuffering {
                self.isBuffering = true
            }
        case 0: // ENDED
            handleTrackFinished()
        case -99: // YOUTUBE EMBED ERROR (e.g. VEVO 150) -> Auto-fallback to native AVPlayer stream
            youtubeWatchdogTask?.cancel()
            if let track = currentTrack {
                Task {
                    await fallbackFromYouTubeToNativeAVPlayer(for: track)
                }
            }
        default:
            break
        }
    }

    private func startYouTubePlaybackWithNativeFallbackWatchdog(videoID: String, for track: UniversalTrack) {
        youtubeWatchdogTask?.cancel()
        primaryPlayer.pause()
        ApplicationMusicPlayer.shared.pause()
        activeYouTubeVideoID = videoID
        isBuffering = false
        isPlaying = true
        playbackStatusBanner = nil
        refreshNowPlayingMetadata()

        // If iOS WKWebView or VEVO blocks embedded autoplay after 4.2 seconds, seamlessly switch to native AVPlayer audio
        youtubeWatchdogTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled,
                  self.activeYouTubeVideoID == videoID,
                  self.currentTime < 0.15 else {
                return
            }
            await self.fallbackFromYouTubeToNativeAVPlayer(for: track)
        }
    }

    private func fallbackFromYouTubeToNativeAVPlayer(for track: UniversalTrack) async {
        activeYouTubeVideoID = nil
        let query = "\(track.title) \(track.artist)"
        if let openCandidates = try? await audiusProvider.searchTracks(query: query, limit: 4),
           let matchedOpen = openCandidates.first(where: { matcher.isSameSong(track, $0) }),
           let fullStream = try? await audiusProvider.resolvePlayableStreamURL(for: matchedOpen) {
            startAVPlayer(with: fullStream, for: track, banner: nil)
            return
        }
        if let appleURL = try? await appleProvider.resolvePlayableStreamURL(for: track) {
            startAVPlayer(with: appleURL, for: track, banner: nil, isFallbackRetry: true)
            return
        }
    }

    private func evaluateYouTubeJS(_ script: String) {
        youtubeWebView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Audio Session & System Notifications

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            // Simulator or restricted audio environment
        }
    }

    private func configureAudioNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            Task { @MainActor in
                switch type {
                case .began:
                    self.pause()
                case .ended:
                    if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        if options.contains(.shouldResume) {
                            self.resume()
                        }
                    }
                @unknown default:
                    break
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in
                    self.pause()
                }
            }
        }
    }

    // MARK: - Lock Screen & Control Center Remote Commands

    private func configureRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.resume() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skipToNext() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skipToPrevious() }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self.seek(to: posEvent.positionTime)
            }
            return .success
        }
    }

    private func attachPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = primaryPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeYouTubeVideoID == nil else { return }
                let seconds = time.seconds
                if seconds.isFinite && seconds >= 0 && abs(seconds - self.currentTime) >= 0.20 {
                    self.currentTime = seconds
                }
                if let item = self.primaryPlayer.currentItem {
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 && abs(itemDuration - self.duration) >= 0.5 {
                        self.duration = itemDuration
                    }
                }
                self.checkCrossfadeTrigger()
            }
        }
    }

    // MARK: - Playback Controls

    public func play(_ track: UniversalTrack, queue: [UniversalTrack] = []) {
        if let current = currentTrack, current.id != track.id {
            playbackHistory.insert(current, at: 0)
            if playbackHistory.count > 50 {
                playbackHistory.removeLast()
            }
        }

        currentTrack = track
        if !queue.isEmpty {
            if let idx = queue.firstIndex(where: { $0.id == track.id }) {
                let tail = Array(queue.suffix(from: queue.index(after: idx)))
                upNextQueue = isShuffled ? tail.shuffled() : tail
            } else {
                upNextQueue = isShuffled ? queue.shuffled() : queue
            }
        }

        currentTime = 0
        duration = max(track.duration, 0)
        isBuffering = true
        playbackStatusBanner = nil
        activeYouTubeVideoID = nil
        // Default to pure Apple Music square-artwork audio view; only show video automatically if user explicitly tapped a raw YouTube video
        isYouTubeVideoVisible = (track.provider == .youtube)
        crossfadeTriggeredForCurrentItem = false

        PersistenceController.shared.recordPlayback(of: track)
        ProviderCredentialsStore.shared.refreshActiveProviderPriority()

        Task {
            await LyricsService.shared.loadLyrics(for: track)
        }

        Task {
            await loadAndStartPlayback(for: track)
        }
    }

    private func loadAndStartPlayback(for track: UniversalTrack) async {
        configureAudioSession()

        // 1. Check if downloaded or imported as a local file first
        if let localRelative = track.localFileRelativePath,
           let fileURL = resolveLocalFileURL(relativePath: localRelative),
           FileManager.default.fileExists(atPath: fileURL.path) {
            startAVPlayer(with: fileURL, for: track, banner: nil)
            return
        }

        // 2. Provider-specific resolution
        switch track.provider {
        case .localFile:
            if let stream = track.streamURL {
                startAVPlayer(with: stream, for: track, banner: nil)
            }

        case .audius, .radio:
            if let resolvedURL = try? await audiusProvider.resolvePlayableStreamURL(for: track) ?? track.streamURL {
                startAVPlayer(with: resolvedURL, for: track, banner: nil)
            } else if let direct = track.streamURL {
                startAVPlayer(with: direct, for: track, banner: nil)
            } else {
                await attemptCrossProviderFallback(for: track)
            }

        case .appleMusic:
            // Try native MusicKit full playback if user is subscribed & authorized
            if MusicAuthorization.currentStatus == .authorized {
                do {
                    let request = MusicCatalogResourceRequest<MusicKit.Song>(
                        matching: \.id,
                        equalTo: MusicItemID(track.providerTrackID)
                    )
                    let response = try await request.response()
                    if let song = response.items.first {
                        ApplicationMusicPlayer.shared.queue = [song]
                        try await ApplicationMusicPlayer.shared.play()
                        isPlaying = true
                        isBuffering = false
                        playbackStatusBanner = nil
                        refreshNowPlayingMetadata()
                        return
                    }
                } catch {
                    // Fall through
                }
            }

            // First check if a full-length native AVPlayer stream exists on Audius or SoundCloud
            if await tryUpgradeToNativeAVStream(for: track) {
                return
            }

            // Otherwise play Apple Music's guaranteed native AAC stream immediately via AVPlayer
            if let previewURL = try? await appleProvider.resolvePlayableStreamURL(for: track) {
                startAVPlayer(
                    with: previewURL,
                    for: track,
                    banner: nil
                )
            } else {
                await attemptCrossProviderFallback(for: track)
            }

        case .youtubeMusic, .youtube:
            startYouTubePlaybackWithNativeFallbackWatchdog(videoID: track.providerTrackID, for: track)
            Task {
                await upgradeToSquareAppleMusicCoverIfNeeded(for: track)
            }

        case .soundCloud:
            if let streamURL = track.streamURL, track.isStreamable {
                startAVPlayer(with: streamURL, for: track, banner: nil)
            } else {
                await attemptCrossProviderFallback(for: track)
            }

        case .spotify:
            if await tryUpgradeToFullLengthStream(for: track) {
                return
            }
            if let preview = track.previewURL {
                startAVPlayer(with: preview, for: track, banner: "Spotify 30s Preview")
            } else {
                await attemptCrossProviderFallback(for: track)
            }
        }
    }

    /// Checks native AVPlayer full-stream providers (SoundCloud, Audius) for an exact match
    private func tryUpgradeToNativeAVStream(for track: UniversalTrack) async -> Bool {
        let query = "\(track.title) \(track.artist)"

        if soundCloudProvider.isConfigured,
           let scCandidates = try? await soundCloudProvider.searchTracks(query: query, limit: 3),
           let bestSC = scCandidates.first(where: { $0.streamURL != nil && $0.isStreamable }),
           let streamURL = bestSC.streamURL {
            if bestSC.duration > 35 {
                self.duration = bestSC.duration
            }
            startAVPlayer(with: streamURL, for: track, banner: nil)
            return true
        }

        if let openCandidates = try? await audiusProvider.searchTracks(query: query, limit: 5),
           let matchedOpen = openCandidates.first(where: { matcher.isSameSong(track, $0) }),
           let fullStreamURL = try? await audiusProvider.resolvePlayableStreamURL(for: matchedOpen) {
            if matchedOpen.duration > 35 {
                self.duration = matchedOpen.duration
            }
            startAVPlayer(with: fullStreamURL, for: track, banner: nil)
            return true
        }

        return false
    }

    private func tryUpgradeToFullLengthStream(for track: UniversalTrack) async -> Bool {
        if await tryUpgradeToNativeAVStream(for: track) {
            return true
        }
        let query = "\(track.title) \(track.artist)"
        if ytMusicProvider.isConfigured,
           let ytCandidates = try? await ytMusicProvider.searchTracks(query: query, limit: 3),
           let bestYT = ytCandidates.first {
            if bestYT.duration > 35 {
                self.duration = bestYT.duration
            }
            self.isYouTubeVideoVisible = false
            startYouTubePlaybackWithNativeFallbackWatchdog(videoID: bestYT.providerTrackID, for: track)
            return true
        }
        return false
    }

    private func upgradeToSquareAppleMusicCoverIfNeeded(for track: UniversalTrack) async {
        let query = "\(track.title) \(track.artist)"
        guard let appleMatches = try? await appleProvider.searchTracks(query: query, limit: 2),
              let firstMatch = appleMatches.first,
              let squareArtwork = firstMatch.artworkURL,
              currentTrack?.id == track.id else {
            return
        }
        var updated = track
        updated.artworkURL = squareArtwork
        if firstMatch.album != "Single" {
            updated.album = firstMatch.album
        }
        self.currentTrack = updated
        refreshNowPlayingMetadata()
    }

    private func attemptCrossProviderFallback(for track: UniversalTrack) async {
        if await tryUpgradeToFullLengthStream(for: track) {
            return
        }
        let query = "\(track.title) \(track.artist)"
        if let appleMatches = try? await appleProvider.searchTracks(query: query, limit: 2),
           let first = appleMatches.first,
           let preview = first.previewURL {
            startAVPlayer(
                with: preview,
                for: track,
                banner: "Matched Apple Music AAC Preview"
            )
            return
        }
        isBuffering = false
        isPlaying = false
        playbackStatusBanner = "Direct stream restricted by \(track.provider.displayName)."
    }

    private func startAVPlayer(with url: URL, for track: UniversalTrack, banner: String?, isFallbackRetry: Bool = false) {
        ApplicationMusicPlayer.shared.pause()
        activeYouTubeVideoID = nil
        playbackStatusBanner = banner

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        endOfTrackCancellable?.cancel()
        endOfTrackCancellable = NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.handleTrackFinished()
        }

        itemStatusObservation?.invalidate()
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.isPlaying = true
                    self.primaryPlayer.play()
                    self.refreshNowPlayingMetadata()
                case .failed:
                    if !isFallbackRetry {
                        if let appleFallback = try? await self.appleProvider.resolvePlayableStreamURL(for: track),
                           appleFallback != url {
                            self.startAVPlayer(with: appleFallback, for: track, banner: nil, isFallbackRetry: true)
                            return
                        }
                    }
                    self.isBuffering = false
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        primaryPlayer.automaticallyWaitsToMinimizeStalling = true
        primaryPlayer.replaceCurrentItem(with: playerItem)
        primaryPlayer.volume = volume
        primaryPlayer.play()

        isPlaying = true
        isBuffering = false
        refreshNowPlayingMetadata()
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    public func pause() {
        if activeYouTubeVideoID != nil {
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.pause();}")
        }
        primaryPlayer.pause()
        crossfadeSecondaryPlayer?.pause()
        ApplicationMusicPlayer.shared.pause()
        isPlaying = false
        refreshNowPlayingMetadata()
    }

    public func resume() {
        guard currentTrack != nil else { return }
        configureAudioSession()
        if activeYouTubeVideoID != nil {
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.play();}")
            isPlaying = true
        } else {
            primaryPlayer.play()
            isPlaying = true
        }
        refreshNowPlayingMetadata()
    }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, max(duration, seconds)))
        if activeYouTubeVideoID != nil {
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.seek(\(clamped));}")
            currentTime = clamped
            updateNowPlayingElapsedTime()
            return
        }
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
        primaryPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        updateNowPlayingElapsedTime()
    }

    public func skipToNext() {
        if repeatMode == .one, let current = currentTrack {
            seek(to: 0)
            resume()
            play(current, queue: upNextQueue)
            return
        }

        if !upNextQueue.isEmpty {
            let nextTrack = upNextQueue.removeFirst()
            if repeatMode == .all, let current = currentTrack {
                upNextQueue.append(current)
            }
            play(nextTrack, queue: [])
        } else if repeatMode == .all, let firstHistory = playbackHistory.last {
            play(firstHistory, queue: playbackHistory.reversed())
        } else {
            pause()
            seek(to: 0)
        }
    }

    public func skipToPrevious() {
        if currentTime > 3.5 {
            seek(to: 0)
            return
        }
        if !playbackHistory.isEmpty {
            let previous = playbackHistory.removeFirst()
            if let current = currentTrack {
                upNextQueue.insert(current, at: 0)
            }
            play(previous, queue: [])
        } else {
            seek(to: 0)
        }
    }

    private func handleTrackFinished() {
        skipToNext()
    }

    // MARK: - Queue Manipulation

    public func playNext(_ track: UniversalTrack) {
        upNextQueue.insert(track, at: 0)
    }

    public func addToQueue(_ track: UniversalTrack) {
        upNextQueue.append(track)
    }

    public func removeFromQueue(at offsets: IndexSet) {
        upNextQueue.remove(atOffsets: offsets)
    }

    public func moveQueueItem(from source: IndexSet, to destination: Int) {
        upNextQueue.move(fromOffsets: source, toOffset: destination)
    }

    public func clearQueue() {
        upNextQueue.removeAll()
    }

    public func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            upNextQueue.shuffle()
        }
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Crossfade Transition

    private func checkCrossfadeTrigger() {
        guard activeYouTubeVideoID == nil,
              crossfadeSeconds > 0.5,
              !crossfadeTriggeredForCurrentItem,
              duration > crossfadeSeconds + 4,
              currentTime >= duration - crossfadeSeconds,
              !upNextQueue.isEmpty else {
            return
        }
        crossfadeTriggeredForCurrentItem = true
        let steps = 10
        let stepInterval = crossfadeSeconds / Double(steps)
        let originalVolume = volume

        Task { @MainActor in
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
                let factor = Float(steps - step) / Float(steps)
                self.primaryPlayer.volume = max(0.05, originalVolume * factor)
            }
            self.primaryPlayer.volume = originalVolume
        }
    }

    // MARK: - Sleep Timer

    public func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        guard let minutes, minutes > 0 else {
            sleepTimerRemainingSeconds = nil
            return
        }
        sleepTimerRemainingSeconds = minutes * 60
        sleepTimerTask = Task { @MainActor in
            while let remaining = self.sleepTimerRemainingSeconds, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.sleepTimerRemainingSeconds = remaining - 1
            }
            self.sleepTimerRemainingSeconds = nil
            self.pause()
        }
    }

    // MARK: - Lock Screen / MPNowPlayingInfoCenter & Dynamic Island Update

    private func refreshNowPlayingMetadata() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            DynamicIslandNowPlayingCoordinator.shared.updateLiveActivity(
                track: nil,
                isPlaying: false,
                currentTime: 0,
                duration: 0
            )
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let artworkURL = track.artworkURL {
            Task {
                if let image = await ArtworkCacheManager.shared.image(for: artworkURL) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }

        DynamicIslandNowPlayingCoordinator.shared.updateLiveActivity(
            track: track,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration > 0 ? duration : track.duration
        )
    }

    private func updateNowPlayingElapsedTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func resolveLocalFileURL(relativePath: String) -> URL? {
        guard !relativePath.contains(".."),
              (relativePath.hasPrefix("AuraDownloads/") || relativePath.hasPrefix("AuraLocalFiles/")) else {
            return nil
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let candidate = docs.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(docs.standardizedFileURL.path) else {
            return nil
        }
        return candidate
    }
}
