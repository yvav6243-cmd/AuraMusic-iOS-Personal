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
    @Published public var isYouTubeVideoVisible: Bool = false
    @Published public var playbackStatusBanner: String? = nil
    public private(set) var capturedYouTubeAudioStreamURLs: [String: URL] = [:]

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
    private var backgroundKeepAliveAudioPlayer: AVAudioPlayer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private weak var youtubeWebView: WKWebView?
    private var timeObserverToken: Any?
    private var endOfTrackCancellable: AnyCancellable?
    private var itemStatusObservation: NSKeyValueObservation?
    private var sleepTimerTask: Task<Void, Never>?
    private var youtubeWatchdogTask: Task<Void, Never>?
    private var youtubeClockInterpolatorTask: Task<Void, Never>?
    private var lastYouTubeJSTickWallTime: TimeInterval = 0
    private var hasReceivedFirstYouTubeProgressTick: Bool = false
    private var fallbackYouTubeVideoIDs: [String] = []
    private var crossfadeTriggeredForCurrentItem = false

    private let appleProvider = AppleMusicProvider()
    private let audiusProvider = AudiusProvider()
    private let ytMusicProvider = YouTubeMusicProvider(providerType: .youtubeMusic)
    private let soundCloudProvider = SoundCloudProvider()
    private let matcher = TrackMatchingEngine()

    private init() {
        configureAudioSession()
        prepareSilentBackgroundKeepAlivePlayer()
        configureRemoteCommandCenter()
        configureAudioNotifications()
        attachPeriodicTimeObserver()
    }

    public func recordCapturedYouTubeAudioStreamURL(_ url: URL, forVideoID videoID: String) {
        capturedYouTubeAudioStreamURLs[videoID] = url
    }

    private func prepareSilentBackgroundKeepAlivePlayer() {
        // Synthesize a tiny valid 1-second 8kHz 16-bit mono silent WAV in memory so iOS keeps the app's audio process awake in background
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000
        let dataSize: UInt32 = numSamples * 2
        let fileSize: UInt32 = 36 + dataSize
        var wavData = Data()
        wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        withUnsafeBytes(of: fileSize.littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        withUnsafeBytes(of: UInt32(16).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { wavData.append(contentsOf: $0) }  // PCM
        withUnsafeBytes(of: UInt16(1).littleEndian) { wavData.append(contentsOf: $0) }  // 1 channel
        withUnsafeBytes(of: sampleRate.littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: (sampleRate * 2).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        withUnsafeBytes(of: dataSize.littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(Data(count: Int(dataSize)))

        if let silentPlayer = try? AVAudioPlayer(data: wavData) {
            silentPlayer.numberOfLoops = -1
            silentPlayer.volume = 0.005
            silentPlayer.prepareToPlay()
            self.backgroundKeepAliveAudioPlayer = silentPlayer
        }
    }

    private func setBackgroundKeepAliveActive(_ active: Bool) {
        if active {
            if !(backgroundKeepAliveAudioPlayer?.isPlaying ?? false) {
                configureAudioSession(mixWithWebKit: activeYouTubeVideoID != nil)
                backgroundKeepAliveAudioPlayer?.play()
            }
            if backgroundTaskID == .invalid {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AuraMusicBackgroundAudio") { [weak self] in
                    guard let self else { return }
                    if self.backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                        self.backgroundTaskID = .invalid
                    }
                }
            }
        } else {
            backgroundKeepAliveAudioPlayer?.pause()
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
    }

    public func applyUpdatedArtworkURL(_ newURL: URL?, forTrackID trackID: String) {
        guard var current = currentTrack, current.id == trackID else { return }
        current.artworkURL = newURL
        self.currentTrack = current
        refreshNowPlayingMetadata()
    }

    // MARK: - YouTube IFrame JS Bridge Handlers

    public func registerYouTubeWebView(_ webView: WKWebView) {
        self.youtubeWebView = webView
    }

    public func handleYouTubePlayerEvent(currentTime: Double, duration: Double, stateCode: Int) {
        guard activeYouTubeVideoID != nil else { return }
        if currentTime.isFinite && currentTime > 0.05 {
            hasReceivedFirstYouTubeProgressTick = true
            lastYouTubeJSTickWallTime = CACurrentMediaTime()
            if abs(currentTime - self.currentTime) >= 0.08 {
                self.currentTime = currentTime
            }
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
            // Ignore transient initial paused state before playback has started so UI doesn't flicker or abort autoplay
            guard hasReceivedFirstYouTubeProgressTick || currentTime > 0.05 else {
                if !self.isBuffering { self.isBuffering = true }
                return
            }
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
        case -99: // Video restricted/error -> switch to next available audio candidate for this song
            if !fallbackYouTubeVideoIDs.isEmpty {
                let nextID = fallbackYouTubeVideoIDs.removeFirst()
                activeYouTubeVideoID = nextID
            }
        default:
            break
        }
    }

    private func startFullLengthYouTubeMusicPlayback(videoID: String, for track: UniversalTrack) {
        youtubeWatchdogTask?.cancel()
        youtubeClockInterpolatorTask?.cancel()
        primaryPlayer.pause()
        ApplicationMusicPlayer.shared.pause()
        fallbackYouTubeVideoIDs = []
        hasReceivedFirstYouTubeProgressTick = false
        lastYouTubeJSTickWallTime = CACurrentMediaTime()
        activeYouTubeVideoID = videoID
        isBuffering = false
        isPlaying = true
        playbackStatusBanner = nil
        setBackgroundKeepAliveActive(true)
        refreshNowPlayingMetadata()

        // Native Swift 150ms smooth clock interpolator so lyrics highlight & scroll continuously even if WebKit throttles JS timers
        youtubeClockInterpolatorTask = Task { @MainActor in
            while !Task.isCancelled && self.activeYouTubeVideoID != nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled,
                      self.activeYouTubeVideoID != nil,
                      self.isPlaying,
                      !self.isBuffering,
                      self.hasReceivedFirstYouTubeProgressTick else {
                    continue
                }
                let elapsedSinceJSTick = CACurrentMediaTime() - self.lastYouTubeJSTickWallTime
                let isInBackground = UIApplication.shared.applicationState != .active
                if elapsedSinceJSTick >= 0.16 && (isInBackground || elapsedSinceJSTick <= 0.75) {
                    let maxDur = self.duration > 0 ? self.duration : 240
                    if self.currentTime + 0.15 < maxDur {
                        self.currentTime += 0.15
                    }
                }
            }
        }

        // Pre-fetch backup audio videoIDs so if a clip is age/region restricted, we seamlessly switch to an alternate audio upload
        Task {
            let query = "\(track.title) \(track.artist) audio"
            if let candidates = try? await ytMusicProvider.searchTracks(query: query, limit: 5) {
                let backups = candidates.map(\.providerTrackID).filter { $0 != videoID }
                await MainActor.run {
                    if self.currentTrack?.id == track.id {
                        self.fallbackYouTubeVideoIDs = backups
                    }
                }
            }
        }
    }

    private func evaluateYouTubeJS(_ script: String) {
        youtubeWebView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Audio Session & System Notifications

    private func configureAudioSession(mixWithWebKit: Bool = true) {
        do {
            let session = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = mixWithWebKit
                ? [.mixWithOthers, .allowAirPlay, .allowBluetoothA2DP]
                : [.allowAirPlay, .allowBluetoothA2DP]
            try session.setCategory(.playback, mode: .default, options: options)
            try session.setActive(true)
        } catch {
            // Simulator or restricted audio environment
        }
    }

    private func configureAudioNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isPlaying else { return }
                self.setBackgroundKeepAliveActive(true)
                if self.activeYouTubeVideoID != nil {
                    self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.resume();}")
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if self.isPlaying && self.activeYouTubeVideoID != nil {
                        self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.resume();}")
                    }
                }
            }
        }
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

        var trackWithCustomArt = track
        if let customURL = PersistenceController.shared.effectiveArtworkURL(for: track) {
            trackWithCustomArt.artworkURL = customURL
        }
        currentTrack = trackWithCustomArt
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
        if !(backgroundKeepAliveAudioPlayer?.isPlaying ?? false) {
            configureAudioSession()
        }

        // 1. Check if downloaded offline or imported as a local file first (works 100% offline in Airplane Mode)
        let offlinePath = track.localFileRelativePath
            ?? OfflineDownloadManager.shared.completedLocalRelativePath(for: track.id)
        if let localRelative = offlinePath,
           let fileURL = resolveLocalFileURL(relativePath: localRelative),
           FileManager.default.fileExists(atPath: fileURL.path) {
            startAVPlayer(with: fileURL, for: track, banner: "Offline Audio")
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
            // Only use native MusicKit if the user actually has Apple MusicKit authorized
            if ProviderCredentialsStore.shared.hasConfiguredAPI(for: .appleMusic),
               MusicAuthorization.currentStatus == .authorized {
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

            // Since Apple Music API is not configured, route through the user's active configured API (e.g. YouTube Music)
            if await tryUpgradeToFullLengthStream(for: track) {
                return
            }

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
            startFullLengthYouTubeMusicPlayback(videoID: track.providerTrackID, for: track)
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
        let query = "\(track.title) \(track.artist)"

        // 1. If YouTube Music API is configured, resolve full studio track
        if ProviderCredentialsStore.shared.hasConfiguredAPI(for: .youtubeMusic),
           let ytCandidates = try? await ytMusicProvider.searchTracks(query: query, limit: 3),
           let bestYT = ytCandidates.first {
            if bestYT.duration > 35 {
                self.duration = bestYT.duration
            }
            self.isYouTubeVideoVisible = false
            startFullLengthYouTubeMusicPlayback(videoID: bestYT.providerTrackID, for: track)
            return true
        }

        // 2. Otherwise check other configured native AVPlayer full-stream providers
        if await tryUpgradeToNativeAVStream(for: track) {
            return true
        }
        return false
    }

    private func upgradeToSquareAppleMusicCoverIfNeeded(for track: UniversalTrack) async {
        // Never overwrite a custom cover photo chosen by the user
        if PersistenceController.shared.hasCustomArtwork(for: track.id) {
            if let customURL = PersistenceController.shared.effectiveArtworkURL(for: track),
               currentTrack?.id == track.id {
                var updated = track
                updated.artworkURL = customURL
                self.currentTrack = updated
            }
            return
        }
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

    private func startAVPlayer(
        with url: URL,
        for track: UniversalTrack,
        banner: String?,
        isFallbackRetry: Bool = false,
        customUserAgent: String? = nil
    ) {
        youtubeWatchdogTask?.cancel()
        ApplicationMusicPlayer.shared.pause()
        activeYouTubeVideoID = nil
        playbackStatusBanner = banner

        var assetOptions: [String: Any] = [:]
        if let customUserAgent {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = ["User-Agent": customUserAgent]
        }
        let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)
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
        setBackgroundKeepAliveActive(false)
        isPlaying = false
        refreshNowPlayingMetadata()
    }

    public func resume() {
        guard currentTrack != nil else { return }
        configureAudioSession()
        if activeYouTubeVideoID != nil {
            setBackgroundKeepAliveActive(true)
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.resume();}")
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
