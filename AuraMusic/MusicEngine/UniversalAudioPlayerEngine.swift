import AVFoundation
import Combine
import Foundation
import MediaPlayer
import MusicKit
import SwiftUI
import UIKit
import WebKit

/// Enforces at most one Play/Pause toggle per cooldown window (default: 1.0s) so accidental rapid double-taps
/// or duplicate Lock Screen + MediaSession events can never double-toggle playback.
public struct PlayPauseCooldownGate: Sendable {
    public let cooldownInterval: TimeInterval
    public private(set) var lastAcceptedTimestamp: TimeInterval?

    public init(cooldownInterval: TimeInterval = 1.0) {
        self.cooldownInterval = cooldownInterval
    }

    public mutating func tryConsume(at now: TimeInterval) -> Bool {
        if let last = lastAcceptedTimestamp, (now - last) < cooldownInterval {
            return false
        }
        lastAcceptedTimestamp = now
        return true
    }

    public mutating func recordAction(at now: TimeInterval) {
        lastAcceptedTimestamp = now
    }

    public mutating func reset() {
        lastAcceptedTimestamp = nil
    }
}

/// High-frequency playback clock isolated from `UniversalAudioPlayerEngine` so 4–5Hz timer ticks
/// ONLY update the tiny scrubber & lyrics driver instead of re-rendering the entire SwiftUI app tree!
/// Between ticks, the scrubber interpolates linearly in O(1) with zero objectWillChange overhead.
@MainActor
public final class PlaybackClock: ObservableObject {
    public static let shared = PlaybackClock()
    @Published public var currentTime: TimeInterval = 0 {
        didSet {
            lastSyncWallTime = CACurrentMediaTime()
        }
    }
    @Published public var duration: TimeInterval = 0
    public private(set) var lastSyncWallTime: TimeInterval = CACurrentMediaTime()
    private init() {}

    /// Resets the interpolation wall-clock anchor (e.g., right on resume) so the bar glides forward from 0ms without jumping.
    public func refreshSyncAnchor(at wallTime: TimeInterval = CACurrentMediaTime()) {
        lastSyncWallTime = wallTime
    }

    /// Pure O(1) interpolated playback time between engine ticks — zero timers, zero allocations, zero SwiftUI invalidations.
    public func interpolatedTime(
        at nowWallTime: TimeInterval = CACurrentMediaTime(),
        isPlaying: Bool,
        isBuffering: Bool,
        fallbackDuration: TimeInterval = 0
    ) -> TimeInterval {
        let total = max(duration, fallbackDuration, 0)
        return Self.computeInterpolatedTime(
            anchorTime: currentTime,
            anchorWallTime: lastSyncWallTime,
            nowWallTime: nowWallTime,
            duration: total,
            isPlaying: isPlaying,
            isBuffering: isBuffering
        )
    }

    public nonisolated static func computeInterpolatedTime(
        anchorTime: TimeInterval,
        anchorWallTime: TimeInterval,
        nowWallTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        isBuffering: Bool
    ) -> TimeInterval {
        let clampedBase = max(0, duration > 0 ? min(anchorTime, duration) : anchorTime)
        guard isPlaying, !isBuffering else {
            return clampedBase
        }
        // Cap extrapolation at 0.65s so if audio briefly stalls on slow network, the scrubber never runs away past real audio
        let elapsed = max(0, min(nowWallTime - anchorWallTime, 0.65))
        let predicted = clampedBase + elapsed
        return duration > 0 ? min(predicted, duration) : predicted
    }
}

@MainActor
public final class UniversalAudioPlayerEngine: ObservableObject {
    public static let shared = UniversalAudioPlayerEngine()
    public let clock: PlaybackClock = .shared

    // MARK: - Published Playback State (Low-Frequency Only -> 120 FPS UI!)

    @Published public private(set) var currentTrack: UniversalTrack?
    @Published public var upNextQueue: [UniversalTrack] = []
    @Published public private(set) var playbackHistory: [UniversalTrack] = []
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isBuffering: Bool = false

    /// Proxied to `PlaybackClock.shared` so changing `currentTime` or `duration` NEVER invalidates views observing `UniversalAudioPlayerEngine`!
    public var currentTime: TimeInterval {
        get { clock.currentTime }
        set {
            if abs(clock.currentTime - newValue) > 0.0001 {
                clock.currentTime = newValue
            }
        }
    }

    public var duration: TimeInterval {
        get { clock.duration }
        set {
            if abs(clock.duration - newValue) > 0.0001 {
                clock.duration = newValue
            }
        }
    }
    @Published public var volume: Float = 1.0 {
        didSet {
            #if targetEnvironment(simulator)
            primaryPlayer.volume = volume
            #else
            // On real iOS hardware, master volume is controlled natively by iOS hardware volume (MPVolumeView + side buttons)
            // so AVPlayer stays at full 1.0 headroom matching WKWebView with zero double-attenuation!
            primaryPlayer.volume = 1.0
            #endif
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
    @Published public private(set) var isPlayingOfflineFile: Bool = false
    @Published public private(set) var activeTrackTrimRange: TrackTrimRange? = nil
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
    private var outputVolumeObservation: NSKeyValueObservation?
    private var sleepTimerTask: Task<Void, Never>?
    private var youtubeWatchdogTask: Task<Void, Never>?
    private var youtubeClockInterpolatorTask: Task<Void, Never>?
    private var backgroundProtectTask: Task<Void, Never>?
    private var delayedKeepAliveStopTask: Task<Void, Never>?
    private var nativeHandoffTask: Task<Void, Never>?
    private var nativeHandoffObservation: NSKeyValueObservation?
    private var attemptedNativeHandoffVideoIDs: Set<String> = []
    private var isUserPaused: Bool = false
    private var secondaryAudioWasAlreadySilencedOnBackground: Bool = false
    private var lastUserPauseWallTime: TimeInterval = 0
    private var lastUserResumeWallTime: TimeInterval = 0
    private var lastTrackStartWallTime: TimeInterval = 0
    private var playbackGeneration: Int = 0
    private var appliedStartTrimForGeneration: Int = -1
    private var triggeredEndTrimForGeneration: Int = -1
    private var playPauseCooldownGate = PlayPauseCooldownGate(cooldownInterval: 1.0)
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
        let hwVol = AVAudioSession.sharedInstance().outputVolume
        if hwVol.isFinite && hwVol > 0 {
            self.volume = hwVol
        }
        observeSystemHardwareVolume()
        YouTubeAdBlockerRuleManager.shared.preloadRules()
        prepareSilentBackgroundKeepAlivePlayer()
        configureRemoteCommandCenter()
        configureAudioNotifications()
        attachPeriodicTimeObserver()
    }

    public func syncObservedHardwareVolume(_ hardwareVolume: Float) {
        let clamped = max(0.0, min(1.0, hardwareVolume))
        if abs(self.volume - clamped) > 0.005 {
            self.volume = clamped
        }
    }

    private func observeSystemHardwareVolume() {
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let latest = session.outputVolume
            Task { @MainActor [weak self] in
                self?.syncObservedHardwareVolume(latest)
            }
        }
    }

    private static let safariMobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    public func recordCapturedYouTubeAudioStreamURL(_ url: URL, forVideoID videoID: String) {
        let lower = url.absoluteString.lowercased()
        let isNativeFriendly = lower.contains("mime=audio/mp4")
            || lower.contains("mime%3daudio%2fmp4")
            || lower.contains(".m3u8")
            || lower.contains("manifest.googlevideo.com")

        // Prefer keeping an AVPlayer-compatible MP4/HLS stream over WebM
        if let existing = capturedYouTubeAudioStreamURLs[videoID]?.absoluteString.lowercased() {
            let existingFriendly = existing.contains("mime=audio/mp4")
                || existing.contains("mime%3daudio%2fmp4")
                || existing.contains(".m3u8")
                || existing.contains("manifest.googlevideo.com")
            if existingFriendly && !isNativeFriendly {
                return
            }
        }
        capturedYouTubeAudioStreamURLs[videoID] = url

        // Attempt silent, zero-risk upgrade from WKWebView to 100% native AVPlayer for native iOS Lock Screen & background controls!
        if isNativeFriendly,
           !lower.contains("ump=1"),
           activeYouTubeVideoID == videoID,
           isPlaying,
           !isUserPaused,
           let track = currentTrack,
           !attemptedNativeHandoffVideoIDs.contains(videoID) {
            attemptedNativeHandoffVideoIDs.insert(videoID)
            let gen = playbackGeneration
            attemptSeamlessNativeAVPlayerHandoff(streamURL: url, videoID: videoID, track: track, generation: gen)
        }
    }

    /// Probes a WebKit-captured PO-token-signed audio/mp4 or HLS stream with AVURLAsset; ONLY hands off to native AVPlayer
    /// if Apple's AVFoundation confirms `.isPlayable == true` and `.readyToPlay`, so playback never glitches on failure.
    private func attemptSeamlessNativeAVPlayerHandoff(
        streamURL: URL,
        videoID: String,
        track: UniversalTrack,
        generation: Int
    ) {
        nativeHandoffTask?.cancel()
        nativeHandoffObservation?.invalidate()
        nativeHandoffObservation = nil

        nativeHandoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let headers: [String: String] = [
                "User-Agent": Self.safariMobileUserAgent,
                "Referer": "https://m.youtube.com/",
                "Origin": "https://m.youtube.com"
            ]
            let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            do {
                let (isPlayable, loadedDuration) = try await asset.load(.isPlayable, .duration)
                guard !Task.isCancelled,
                      isPlayable,
                      loadedDuration.seconds.isFinite,
                      loadedDuration.seconds > 20,
                      self.playbackGeneration == generation,
                      self.activeYouTubeVideoID == videoID,
                      self.isPlaying,
                      !self.isUserPaused else {
                    return
                }

                let probeItem = AVPlayerItem(asset: asset)
                self.primaryPlayer.pause()
                self.primaryPlayer.isMuted = true
                self.primaryPlayer.replaceCurrentItem(with: probeItem)

                let ready = await self.waitForPlayerItemReady(probeItem, timeoutSeconds: 4.0)
                guard ready,
                      !Task.isCancelled,
                      self.playbackGeneration == generation,
                      self.activeYouTubeVideoID == videoID,
                      self.isPlaying,
                      !self.isUserPaused else {
                    if self.primaryPlayer.currentItem === probeItem {
                        self.primaryPlayer.replaceCurrentItem(with: nil)
                        self.primaryPlayer.isMuted = false
                    }
                    return
                }

                let resumePosition = max(0, self.currentTime)
                if resumePosition > 0.3 {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        self.primaryPlayer.seek(
                            to: CMTime(seconds: resumePosition, preferredTimescale: 600),
                            toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
                        ) { _ in
                            cont.resume()
                        }
                    }
                }

                guard !Task.isCancelled,
                      self.playbackGeneration == generation,
                      self.activeYouTubeVideoID == videoID,
                      self.isPlaying,
                      !self.isUserPaused,
                      self.primaryPlayer.currentItem === probeItem else {
                    if self.primaryPlayer.currentItem === probeItem {
                        self.primaryPlayer.replaceCurrentItem(with: nil)
                        self.primaryPlayer.isMuted = false
                    }
                    return
                }

                // Seamless handoff: silence & tear down WKWebView, promote native AVPlayer to active audio owner!
                self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.pause();}")
                self.youtubeClockInterpolatorTask?.cancel()
                self.backgroundProtectTask?.cancel()
                self.delayedKeepAliveStopTask?.cancel()
                self.activeYouTubeVideoID = nil
                self.setBackgroundKeepAliveActive(false)
                self.configureAudioSession(mixWithWebKit: false)

                self.endOfTrackCancellable?.cancel()
                self.endOfTrackCancellable = NotificationCenter.default.publisher(
                    for: .AVPlayerItemDidPlayToEndTime,
                    object: probeItem
                )
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.handleTrackFinished()
                }

                self.itemStatusObservation?.invalidate()
                self.itemStatusObservation = nil
                self.primaryPlayer.automaticallyWaitsToMinimizeStalling = true
                self.primaryPlayer.isMuted = false
                self.primaryPlayer.volume = 1.0
                self.primaryPlayer.play()

                if loadedDuration.seconds > self.duration {
                    self.duration = loadedDuration.seconds
                }
                self.isPlaying = true
                self.isBuffering = false
                self.refreshNowPlayingMetadata()
            } catch {
                // Stream requires WebKit cookies/UMP -> cleanly remain on WKWebView with zero interruption
            }
        }
    }

    private func waitForPlayerItemReady(_ item: AVPlayerItem, timeoutSeconds: TimeInterval) async -> Bool {
        if item.status == .readyToPlay { return true }
        if item.status == .failed { return false }

        return await withCheckedContinuation { continuation in
            var resumed = false
            var timeoutTask: Task<Void, Never>?

            let finish: @MainActor (Bool) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                timeoutTask?.cancel()
                timeoutTask = nil
                self?.nativeHandoffObservation?.invalidate()
                self?.nativeHandoffObservation = nil
                continuation.resume(returning: result)
            }

            self.nativeHandoffObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
                Task { @MainActor in
                    switch observedItem.status {
                    case .readyToPlay:
                        finish(true)
                    case .failed:
                        finish(false)
                    default:
                        break
                    }
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                finish(false)
            }
        }
    }

    /// Synthesizes a 2-second 44.1kHz 16-bit mono WAV with ultra-quiet (-90 dBFS, ±1 LSB) sub-audible dither.
    /// Non-zero energy prevents iOS 17/18 mediaserverd from detecting pure digital silence and dropping our background audio assertion!
    internal static func buildSubAudibleKeepAliveWAVData() -> Data {
        let sampleRate: UInt32 = 44100
        let numSamples: UInt32 = 44100 * 2
        let dataSize: UInt32 = numSamples * 2
        let fileSize: UInt32 = 36 + dataSize
        var wavData = Data(capacity: Int(44 + dataSize))
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

        var pcm = Data(count: Int(dataSize))
        pcm.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                // ±1 LSB at ~18 Hz (-90 dBFS): 100% inaudible to humans, keeps iOS hardware audio graph alive indefinitely
                samples[i] = ((i / 1225) & 1 == 0) ? Int16(1).littleEndian : Int16(-1).littleEndian
            }
        }
        wavData.append(pcm)
        return wavData
    }

    private func prepareSilentBackgroundKeepAlivePlayer() {
        let wavData = Self.buildSubAudibleKeepAliveWAVData()
        if let silentPlayer = try? AVAudioPlayer(data: wavData) {
            silentPlayer.numberOfLoops = -1
            silentPlayer.volume = 0.01
            silentPlayer.prepareToPlay()
            self.backgroundKeepAliveAudioPlayer = silentPlayer
        }
    }

    private func setBackgroundKeepAliveActive(_ active: Bool, mixWithWebKit: Bool = true) {
        if active {
            configureAudioSession(mixWithWebKit: mixWithWebKit)
            if !(backgroundKeepAliveAudioPlayer?.isPlaying ?? false) {
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
        guard var current = currentTrack,
              current.id == trackID || (!current.providerTrackID.isEmpty && current.providerTrackID == trackID) else {
            return
        }
        if let oldURL = current.artworkURL, oldURL != newURL {
            ArtworkCacheManager.shared.invalidate(url: oldURL)
        }
        current.artworkURL = newURL
        self.currentTrack = current
        refreshNowPlayingMetadata()
        reassertNowPlayingOwnershipAfterDelay()
    }

    // MARK: - YouTube IFrame JS Bridge Handlers

    public func registerYouTubeWebView(_ webView: WKWebView) {
        self.youtubeWebView = webView
    }

    /// Completely stops, silences, and unmounts the YouTube WebKit engine so downloaded offline tracks & native streams
    /// NEVER run YouTube JS or load YouTube ads in the background!
    public func teardownYouTubeWebViewCompletely() {
        youtubeWatchdogTask?.cancel()
        youtubeClockInterpolatorTask?.cancel()
        backgroundProtectTask?.cancel()
        delayedKeepAliveStopTask?.cancel()
        if let webView = youtubeWebView {
            webView.evaluateJavaScript("if(window.auraControl && window.auraControl.pauseForExternalApp){window.auraControl.pauseForExternalApp();}", completionHandler: nil)
            webView.pauseAllMediaPlayback(completionHandler: nil)
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        youtubeWebView = nil
        activeYouTubeVideoID = nil
    }

    /// Returns the display start offset and visible duration of the currently playing song.
    /// When the user trims a song (e.g. `0:30 → 2:15`), AuraMusic presents it cleanly as a `0:00 → 1:45` original song!
    public func displayPlaybackBounds(for rawDuration: TimeInterval) -> (start: TimeInterval, duration: TimeInterval) {
        let safeRaw = max(rawDuration, 0)
        guard let trim = activeTrackTrimRange,
              safeRaw > 5,
              trim.isEffectivelyTrimmed(for: safeRaw) else {
            return (0, safeRaw)
        }
        let norm = trim.normalized(for: safeRaw)
        let effDur = norm.effectiveDuration(for: safeRaw)
        return (norm.startSeconds, effDur)
    }

    /// Converts a raw audio timestamp into the trim-relative display clock (`0:00 → newLength`).
    public func displayPlaybackTime(rawTime: TimeInterval, rawDuration: TimeInterval) -> TimeInterval {
        let bounds = displayPlaybackBounds(for: rawDuration)
        return max(0, min(max(bounds.duration, 0), rawTime - bounds.start))
    }

    /// Updates live playback trim immediately after the user edits song start/end bounds in Clip Settings.
    public func applyUpdatedTrimRange(_ range: TrackTrimRange?, for track: UniversalTrack) {
        guard let current = currentTrack,
              current.id == track.id || (!current.providerTrackID.isEmpty && current.providerTrackID == track.providerTrackID) else {
            return
        }
        let totalDur = max(duration, current.duration)
        if let range, totalDur > 5, range.isEffectivelyTrimmed(for: totalDur) {
            let normalized = range.normalized(for: totalDur)
            activeTrackTrimRange = normalized
            triggeredEndTrimForGeneration = -1
            if currentTime < normalized.startSeconds {
                seek(to: normalized.startSeconds)
            } else if let endSec = normalized.endSeconds, currentTime >= endSec {
                seek(to: normalized.startSeconds)
            }
        } else {
            activeTrackTrimRange = nil
            triggeredEndTrimForGeneration = -1
        }
        refreshNowPlayingMetadata()
    }

    /// Enforces custom song end trim (`endSeconds`), finishing the track cleanly right at the user's chosen cut point.
    internal func evaluateTrimBoundsIfNeeded(at seconds: TimeInterval) {
        guard isPlaying,
              triggeredEndTrimForGeneration != playbackGeneration,
              let trim = activeTrackTrimRange else {
            return
        }
        let totalDur = max(duration, currentTrack?.duration ?? 0)
        guard let endSec = trim.normalized(for: totalDur).endSeconds, endSec > 0 else {
            return
        }
        if seconds >= endSec - 0.15 {
            triggeredEndTrimForGeneration = playbackGeneration
            handleTrackFinished()
        }
    }

    public func handleYouTubePlayerEvent(
        currentTime: Double,
        duration: Double,
        stateCode: Int,
        userPaused: Bool = false,
        userResumed: Bool = false
    ) {
        guard activeYouTubeVideoID != nil else { return }
        if currentTime.isFinite && currentTime > 0.05 {
            hasReceivedFirstYouTubeProgressTick = true
            lastYouTubeJSTickWallTime = CACurrentMediaTime()
            if abs(currentTime - self.currentTime) >= 0.12 {
                self.currentTime = currentTime
            }
        }
        if duration.isFinite && duration > 0 && abs(duration - self.duration) >= 0.5 {
            self.duration = duration
        }
        // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering
        switch stateCode {
        case 1: // PLAYING
            let elapsedSinceUserPause = CACurrentMediaTime() - lastUserPauseWallTime
            if self.isUserPaused && !userResumed && elapsedSinceUserPause < 0.55 {
                // Ignore stale in-flight play ticks that were queued right before pause()
                return
            }
            if self.isUserPaused {
                // Genuine resume from Lock Screen, Control Center, Dynamic Island, or AirPods
                self.isUserPaused = false
                self.delayedKeepAliveStopTask?.cancel()
                self.setBackgroundKeepAliveActive(true)
            }
            if !self.isPlaying || self.isBuffering {
                self.isPlaying = true
                self.isBuffering = false
                refreshNowPlayingMetadata()
            }
            if appliedStartTrimForGeneration != playbackGeneration,
               let startSec = activeTrackTrimRange?.startSeconds,
               startSec >= 0.5 {
                appliedStartTrimForGeneration = playbackGeneration
                if currentTime < startSec - 0.5 {
                    seek(to: startSec)
                }
            }
            evaluateTrimBoundsIfNeeded(at: currentTime)
        case 2: // PAUSED
            // Protect against stale in-flight paused ticks queued in WebKit IPC right before the user tapped Play/Resume!
            // Since Play/Pause has a 1.0s cooldown, any state=2 tick within 0.8s of resume() is guaranteed stale.
            if (CACurrentMediaTime() - lastUserResumeWallTime) < 0.8 {
                return
            }
            if userPaused {
                // Already user-paused: ignore repeated heartbeat ticks completely (NEVER reset cooldown or spam audio session!)
                if self.isUserPaused && !self.isPlaying {
                    return
                }
                self.backgroundProtectTask?.cancel()
                self.isUserPaused = true
                self.lastUserPauseWallTime = CACurrentMediaTime()
                self.isPlaying = false
                self.isBuffering = false
                if UIApplication.shared.applicationState != .active {
                    self.setBackgroundKeepAliveActive(true, mixWithWebKit: false)
                }
                self.refreshNowPlayingMetadata()
                self.scheduleIdleKeepAliveTimeout()
                return
            }
            // Ignore transient initial paused ticks before playback settles (or during the first 3.0s of startup)
            // so YouTube ABR/init glitches can NEVER flip a brand-new song to paused!
            let elapsedSinceStart = CACurrentMediaTime() - lastTrackStartWallTime
            guard (hasReceivedFirstYouTubeProgressTick || currentTime > 0.05) && elapsedSinceStart >= 3.0 else {
                if !self.isUserPaused && !self.isBuffering {
                    self.isBuffering = true
                }
                return
            }
            if self.isPlaying || self.isBuffering {
                self.isPlaying = false
                self.isBuffering = false
                updateNowPlayingElapsedTime()
            }
        case 3: // BUFFERING
            if !self.isUserPaused && !self.isBuffering {
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

    /// Keeps the zero-amplitude silent keep-alive warm for 15 minutes while paused in background so iOS doesn't freeze WKWebView
    /// and Lock Screen / Control Center / AirPods Play resumes the track instantaneously.
    private func scheduleIdleKeepAliveTimeout() {
        delayedKeepAliveStopTask?.cancel()
        delayedKeepAliveStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000_000) // 15 minutes idle timeout
            guard !Task.isCancelled, !self.isPlaying else { return }
            self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.enterForeground();}")
            self.youtubeWebView?.pauseAllMediaPlayback(completionHandler: nil)
            self.setBackgroundKeepAliveActive(false)
        }
    }

    private func activateBackgroundTransitionProtection() {
        secondaryAudioWasAlreadySilencedOnBackground = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        if activeYouTubeVideoID != nil {
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.enterBackground(8000);}")
        }
        guard self.isPlaying && !self.isUserPaused else { return }
        backgroundProtectTask?.cancel()
        delayedKeepAliveStopTask?.cancel()
        if activeYouTubeVideoID != nil {
            setBackgroundKeepAliveActive(true, mixWithWebKit: true)
        } else {
            configureAudioSession(mixWithWebKit: false)
        }

        // Continuous background watchdog: immediately recovers if iOS WebKit suspends <video> on transition or mid-song
        // while immediately yielding to TikTok / YouTube / Instagram / Calls whenever external audio begins!
        backgroundProtectTask = Task { @MainActor in
            let initialDelaysNs: [UInt64] = [200_000_000, 500_000_000, 1_100_000_000]
            for delay in initialDelaysNs {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, self.isPlaying, !self.isUserPaused else { return }
                self.enforceBackgroundPlaybackAlive()
            }
            while !Task.isCancelled && self.isPlaying && !self.isUserPaused {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, self.isPlaying, !self.isUserPaused else { return }
                self.enforceBackgroundPlaybackAlive()
            }
        }
    }

    private func enforceBackgroundPlaybackAlive() {
        guard isPlaying, !isUserPaused else { return }
        // If another app (TikTok, YouTube, Instagram, Telegram, Phone) started primary audio, pause immediately instead of fighting it!
        if !secondaryAudioWasAlreadySilencedOnBackground && AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint {
            pauseForExternalAppAudio()
            return
        }
        if activeYouTubeVideoID != nil {
            if !(backgroundKeepAliveAudioPlayer?.isPlaying ?? false) {
                setBackgroundKeepAliveActive(true, mixWithWebKit: true)
            }
            evaluateYouTubeJS("if(window.auraControl && !window._auraUserPaused && !window._auraSoftPaused && !window._auraExternalInterrupted){window.auraControl.keepAliveInBackground();}")
        } else if primaryPlayer.currentItem != nil && primaryPlayer.timeControlStatus == .paused {
            configureAudioSession(mixWithWebKit: false)
            primaryPlayer.play()
        }
    }

    private func startFullLengthYouTubeMusicPlayback(videoID: String, for track: UniversalTrack) {
        youtubeWatchdogTask?.cancel()
        youtubeClockInterpolatorTask?.cancel()
        backgroundProtectTask?.cancel()
        delayedKeepAliveStopTask?.cancel()
        primaryPlayer.pause()
        ApplicationMusicPlayer.shared.pause()
        fallbackYouTubeVideoIDs = []
        hasReceivedFirstYouTubeProgressTick = false
        isUserPaused = false
        lastTrackStartWallTime = CACurrentMediaTime()
        playPauseCooldownGate.reset()
        lastYouTubeJSTickWallTime = CACurrentMediaTime()
        activeYouTubeVideoID = videoID
        isBuffering = false
        isPlaying = true
        playbackStatusBanner = nil
        setBackgroundKeepAliveActive(true, mixWithWebKit: true)
        refreshNowPlayingMetadata()

        // Native Swift 200ms smooth clock interpolator so lyrics highlight & scroll continuously even if WebKit throttles JS timers
        youtubeClockInterpolatorTask = Task { @MainActor in
            while !Task.isCancelled && self.activeYouTubeVideoID != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled,
                      self.activeYouTubeVideoID != nil,
                      self.isPlaying,
                      !self.isBuffering,
                      self.hasReceivedFirstYouTubeProgressTick else {
                    continue
                }
                let elapsedSinceJSTick = CACurrentMediaTime() - self.lastYouTubeJSTickWallTime
                let isInBackground = UIApplication.shared.applicationState != .active
                if elapsedSinceJSTick >= 0.22 && (isInBackground || elapsedSinceJSTick <= 0.80) {
                    let maxDur = self.duration > 0 ? self.duration : 240
                    if self.currentTime + 0.20 < maxDur {
                        self.currentTime += 0.20
                    }
                    self.evaluateTrimBoundsIfNeeded(at: self.currentTime)
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

    /// While actively playing YouTube in WKWebView, `.mixWithOthers` MUST be enabled so the WebContent process
    /// and AuraMusic's silent keep-alive NEVER interrupt each other (which otherwise causes every song to start paused!).
    public static let activePlaybackAudioSessionOptions: AVAudioSession.CategoryOptions = [
        .mixWithOthers,
        .allowAirPlay,
        .allowBluetoothA2DP
    ]

    /// When soft-paused in background (with WKWebView muted), non-mixing `.playback` hands 100% Lock Screen
    /// `MPRemoteCommandCenter` ownership to AuraMusic so the Lock Screen Play button stays enabled and clickable!
    public static let backgroundPausedLockScreenAudioSessionOptions: AVAudioSession.CategoryOptions = [
        .allowAirPlay,
        .allowBluetoothA2DP
    ]

    private func configureAudioSession(mixWithWebKit: Bool = true) {
        do {
            let session = AVAudioSession.sharedInstance()
            let options = mixWithWebKit
                ? Self.activePlaybackAudioSessionOptions
                : Self.backgroundPausedLockScreenAudioSessionOptions
            try session.setCategory(.playback, mode: .default, options: options)
            try session.setActive(true)
        } catch {
            // Simulator or restricted audio environment
        }
    }

    /// Guards against spurious self-interruptions during the first 2.5s of starting a new YouTube track
    internal func handleAudioSessionInterruptionBegan(at now: TimeInterval = CACurrentMediaTime()) {
        if activeYouTubeVideoID != nil && (now - lastTrackStartWallTime) < 2.5 {
            return
        }
        pauseForExternalAppAudio()
    }

    /// Handles iOS `silenceSecondaryAudioHintNotification` (fired whenever TikTok, YouTube, Instagram, Telegram, or
    /// any other non-mixing audio app starts playing while AuraMusic has `.mixWithOthers` active for WebKit playback).
    internal func handleSilenceSecondaryAudioHint(
        type: AVAudioSession.SilenceSecondaryAudioHintType,
        at now: TimeInterval = CACurrentMediaTime(),
        isAppActive: Bool = UIApplication.shared.applicationState == .active
    ) {
        guard type == .begin else { return }
        // Protect only against our own foreground WKWebView activating right as a track launches
        if activeYouTubeVideoID != nil && isAppActive && (now - lastTrackStartWallTime) < 2.5 {
            return
        }
        if isPlaying || isBuffering {
            pauseForExternalAppAudio()
        }
    }

    private func configureAudioNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Arm background protection IMMEDIATELY on willResignActive (BEFORE didEnterBackground)
                // so iOS WebKit cannot pause <video> during the transition gap!
                self.activateBackgroundTransitionProtection()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.activateBackgroundTransitionProtection()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.backgroundProtectTask?.cancel()
                if self.activeYouTubeVideoID != nil {
                    self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.enterForeground();}")
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.backgroundProtectTask?.cancel()
                if self.activeYouTubeVideoID != nil {
                    self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.enterForeground();}")
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.prepareSilentBackgroundKeepAlivePlayer()
                if self.isPlaying && !self.isUserPaused {
                    if self.activeYouTubeVideoID != nil {
                        self.setBackgroundKeepAliveActive(true, mixWithWebKit: true)
                        self.evaluateYouTubeJS("if(window.auraControl){window.auraControl.keepAliveInBackground();}")
                    } else {
                        self.configureAudioSession(mixWithWebKit: false)
                        self.primaryPlayer.play()
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
                    self.handleAudioSessionInterruptionBegan()
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
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
                  let hintType = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else {
                return
            }
            Task { @MainActor in
                self.handleSilenceSecondaryAudioHint(type: hintType)
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
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if !self.isPlaying {
                    self.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying {
                    self.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }

        // Explicitly disable skip ±5s/±15s and seek-step commands so Lock Screen ALWAYS displays
        // Previous Track (⏮) and Next Track (⏭) instead of 5-second skip buttons!
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false

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
                let rawTotal = max(self.duration, self.currentTrack?.duration ?? 0)
                let bounds = self.displayPlaybackBounds(for: rawTotal)
                let clampedDisplay = max(0, min(bounds.duration > 0 ? bounds.duration : posEvent.positionTime, posEvent.positionTime))
                self.seek(to: bounds.start + clampedDisplay)
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
                self.evaluateTrimBoundsIfNeeded(at: seconds)
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

        duration = max(track.duration, 0)
        if let savedTrim = PersistenceController.shared.trimRange(for: trackWithCustomArt) {
            activeTrackTrimRange = (duration > 5) ? savedTrim.normalized(for: duration) : savedTrim
        } else {
            activeTrackTrimRange = nil
        }
        appliedStartTrimForGeneration = -1
        triggeredEndTrimForGeneration = -1
        currentTime = activeTrackTrimRange?.startSeconds ?? 0
        clock.refreshSyncAnchor()
        isUserPaused = false
        isPlaying = true
        isBuffering = true
        playbackGeneration += 1
        let activeGeneration = playbackGeneration
        nativeHandoffTask?.cancel()
        nativeHandoffObservation?.invalidate()
        nativeHandoffObservation = nil
        primaryPlayer.isMuted = false
        attemptedNativeHandoffVideoIDs.removeAll()
        lastTrackStartWallTime = CACurrentMediaTime()
        lastUserResumeWallTime = 0
        playPauseCooldownGate.reset()
        playbackStatusBanner = nil
        isPlayingOfflineFile = false
        // ALWAYS prefer local offline downloaded audio FIRST — even when internet is available (instant start + 0 ads + native AVPlayer)!
        let offlineRelativePath = OfflineDownloadManager.shared.completedLocalRelativePath(for: track)
        let offlineFileURL = offlineRelativePath.flatMap { resolveLocalFileURL(relativePath: $0) }
        let hasOfflineFile = offlineFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        if hasOfflineFile {
            // Strictly tear down & unmount YouTube WebView engine so downloaded tracks NEVER run YouTube or ads!
            teardownYouTubeWebViewCompletely()
        } else if track.provider != .youtubeMusic && track.provider != .youtube {
            // Preserve existing WKWebView when switching between online YouTube tracks so background Next/Prev
            // reuses the live WebContent process (destroying WKWebView in background kills background playback on iOS!).
            activeYouTubeVideoID = nil
        }

        // Default to pure Apple Music square-artwork audio view; only show video automatically if user explicitly tapped a raw YouTube video
        isYouTubeVideoVisible = (!hasOfflineFile && track.provider == .youtube)
        crossfadeTriggeredForCurrentItem = false

        Task { @MainActor in
            PersistenceController.shared.recordPlayback(of: trackWithCustomArt)
            ProviderCredentialsStore.shared.refreshActiveProviderPriority()
        }

        Task {
            await LyricsService.shared.loadLyrics(for: trackWithCustomArt)
        }

        // If full-length offline audio is already downloaded, start native AVPlayer IMMEDIATELY on frame 0!
        if let localURL = offlineFileURL, hasOfflineFile {
            isPlayingOfflineFile = true
            startAVPlayer(with: localURL, for: trackWithCustomArt, banner: nil)
            return
        }

        refreshNowPlayingMetadata()

        Task {
            await loadAndStartPlayback(for: trackWithCustomArt, generation: activeGeneration)
        }
    }

    private func loadAndStartPlayback(for track: UniversalTrack, generation: Int) async {
        guard generation == playbackGeneration, !isUserPaused else { return }
        if !(backgroundKeepAliveAudioPlayer?.isPlaying ?? false) {
            configureAudioSession(mixWithWebKit: true)
        }

        // 1. Check if downloaded offline or imported as a local file first (works 100% offline in Airplane Mode & skips online buffering/ads!)
        let offlinePath = OfflineDownloadManager.shared.completedLocalRelativePath(for: track)
        if let localRelative = offlinePath,
           let fileURL = resolveLocalFileURL(relativePath: localRelative),
           FileManager.default.fileExists(atPath: fileURL.path) {
            isPlayingOfflineFile = true
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
                guard generation == playbackGeneration, !isUserPaused else { return }
                startAVPlayer(with: resolvedURL, for: track, banner: nil)
            } else if let direct = track.streamURL {
                guard generation == playbackGeneration, !isUserPaused else { return }
                startAVPlayer(with: direct, for: track, banner: nil)
            } else {
                await attemptCrossProviderFallback(for: track, generation: generation)
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
                    guard generation == playbackGeneration, !isUserPaused else { return }
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
            if await tryUpgradeToFullLengthStream(for: track, generation: generation) {
                return
            }
            guard generation == playbackGeneration, !isUserPaused else { return }

            if let previewURL = try? await appleProvider.resolvePlayableStreamURL(for: track) {
                guard generation == playbackGeneration, !isUserPaused else { return }
                startAVPlayer(
                    with: previewURL,
                    for: track,
                    banner: nil
                )
            } else {
                await attemptCrossProviderFallback(for: track, generation: generation)
            }

        case .youtubeMusic, .youtube:
            // Try 100% AD-FREE direct native AVPlayer playback via ANDROID Innertube itag=18 FIRST (0 ads, 0 WebKit!)
            if await tryStartDirectAdFreeYouTubeAVStream(videoID: track.providerTrackID, for: track, generation: generation) {
                Task {
                    await upgradeToSquareAppleMusicCoverIfNeeded(for: track)
                }
                return
            }
            guard generation == playbackGeneration, !isUserPaused else { return }
            startFullLengthYouTubeMusicPlayback(videoID: track.providerTrackID, for: track)
            Task {
                await upgradeToSquareAppleMusicCoverIfNeeded(for: track)
            }

        case .soundCloud:
            if let streamURL = track.streamURL, track.isStreamable {
                startAVPlayer(with: streamURL, for: track, banner: nil)
            } else {
                await attemptCrossProviderFallback(for: track, generation: generation)
            }

        case .spotify:
            if await tryUpgradeToFullLengthStream(for: track, generation: generation) {
                return
            }
            guard generation == playbackGeneration, !isUserPaused else { return }
            if let preview = track.previewURL {
                startAVPlayer(with: preview, for: track, banner: nil)
            } else {
                await attemptCrossProviderFallback(for: track, generation: generation)
            }
        }
    }

    /// Checks native AVPlayer full-stream providers (SoundCloud, Audius) for an exact match
    private func tryUpgradeToNativeAVStream(for track: UniversalTrack, generation: Int) async -> Bool {
        let query = "\(track.title) \(track.artist)"

        if soundCloudProvider.isConfigured,
           let scCandidates = try? await soundCloudProvider.searchTracks(query: query, limit: 3),
           let bestSC = scCandidates.first(where: { $0.streamURL != nil && $0.isStreamable }),
           let streamURL = bestSC.streamURL {
            guard generation == playbackGeneration, !isUserPaused else { return true }
            if bestSC.duration > 35 {
                self.duration = bestSC.duration
            }
            startAVPlayer(with: streamURL, for: track, banner: nil)
            return true
        }

        if let openCandidates = try? await audiusProvider.searchTracks(query: query, limit: 5),
           let matchedOpen = openCandidates.first(where: { matcher.isSameSong(track, $0) }),
           let fullStreamURL = try? await audiusProvider.resolvePlayableStreamURL(for: matchedOpen) {
            guard generation == playbackGeneration, !isUserPaused else { return true }
            if matchedOpen.duration > 35 {
                self.duration = matchedOpen.duration
            }
            startAVPlayer(with: fullStreamURL, for: track, banner: nil)
            return true
        }

        return false
    }

    /// Resolves a direct HTTP-200 progressive stream via YouTube ANDROID Innertube API and plays it on native `AVPlayer`:
    /// 0.00% ads (ad servers are never contacted!), native background audio, native Lock Screen & native trim bounds!
    private func tryStartDirectAdFreeYouTubeAVStream(
        videoID: String,
        for track: UniversalTrack,
        generation: Int
    ) async -> Bool {
        guard !videoID.isEmpty else { return false }
        let candidates = await YouTubeInnertubeAudioResolver.resolvePlayableStreams(videoID: videoID, timeoutSeconds: 5.5)
        guard generation == playbackGeneration, !isUserPaused else { return true }

        for stream in candidates where stream.isProgressiveMP4 {
            let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
            if let (isPlayable, loadedDuration) = try? await asset.load(.isPlayable, .duration),
               generation == playbackGeneration,
               !isUserPaused,
               isPlayable,
               OfflineDownloadManager.isFullLengthDurationValid(
                   actualDuration: loadedDuration.seconds,
                   expectedTrackDuration: track.duration
               ) {
                if loadedDuration.seconds > self.duration {
                    self.duration = loadedDuration.seconds
                }
                startAVPlayer(
                    with: stream.url,
                    for: track,
                    banner: nil,
                    customUserAgent: stream.headers["User-Agent"] ?? YouTubeInnertubeAudioResolver.androidUserAgent,
                    youtubeFallbackVideoID: videoID
                )
                return true
            }
        }
        return false
    }

    private func tryUpgradeToFullLengthStream(for track: UniversalTrack, generation: Int) async -> Bool {
        let query = "\(track.title) \(track.artist)"

        // 1. If YouTube Music API is configured, resolve full studio track (preferring ad-free native AVPlayer first!)
        if ProviderCredentialsStore.shared.hasConfiguredAPI(for: .youtubeMusic),
           let ytCandidates = try? await ytMusicProvider.searchTracks(query: query, limit: 3),
           let bestYT = ytCandidates.first {
            guard generation == playbackGeneration, !isUserPaused else { return true }
            if bestYT.duration > 35 {
                self.duration = bestYT.duration
            }
            self.isYouTubeVideoVisible = false
            if await tryStartDirectAdFreeYouTubeAVStream(videoID: bestYT.providerTrackID, for: track, generation: generation) {
                return true
            }
            guard generation == playbackGeneration, !isUserPaused else { return true }
            startFullLengthYouTubeMusicPlayback(videoID: bestYT.providerTrackID, for: track)
            return true
        }

        // 2. Otherwise check other configured native AVPlayer full-stream providers
        if await tryUpgradeToNativeAVStream(for: track, generation: generation) {
            return true
        }
        return false
    }

    private func upgradeToSquareAppleMusicCoverIfNeeded(for track: UniversalTrack) async {
        // Never overwrite a custom cover photo chosen by the user
        if PersistenceController.shared.hasCustomArtwork(for: track) {
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

    private func attemptCrossProviderFallback(for track: UniversalTrack, generation: Int) async {
        if await tryUpgradeToFullLengthStream(for: track, generation: generation) {
            return
        }
        guard generation == playbackGeneration, !isUserPaused else { return }
        let query = "\(track.title) \(track.artist)"
        if let appleMatches = try? await appleProvider.searchTracks(query: query, limit: 2),
           let first = appleMatches.first,
           let preview = first.previewURL {
            guard generation == playbackGeneration, !isUserPaused else { return }
            startAVPlayer(
                with: preview,
                for: track,
                banner: nil
            )
            return
        }
        guard generation == playbackGeneration, !isUserPaused else { return }
        isBuffering = false
        isPlaying = false
        playbackStatusBanner = "Direct stream restricted by \(track.provider.displayName)."
    }

    private func startAVPlayer(
        with url: URL,
        for track: UniversalTrack,
        banner: String?,
        isFallbackRetry: Bool = false,
        customUserAgent: String? = nil,
        youtubeFallbackVideoID: String? = nil
    ) {
        teardownYouTubeWebViewCompletely()
        nativeHandoffTask?.cancel()
        nativeHandoffObservation?.invalidate()
        nativeHandoffObservation = nil
        setBackgroundKeepAliveActive(false)
        configureAudioSession(mixWithWebKit: false)
        ApplicationMusicPlayer.shared.pause()
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

        let targetGen = playbackGeneration
        itemStatusObservation?.invalidate()
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.playbackGeneration == targetGen else { return }
                switch item.status {
                case .readyToPlay:
                    let itemDur = item.duration.seconds
                    if itemDur.isFinite && itemDur > 0 {
                        self.duration = itemDur
                        if let trim = self.activeTrackTrimRange {
                            self.activeTrackTrimRange = trim.normalized(for: itemDur)
                        }
                    }
                    if self.appliedStartTrimForGeneration != targetGen,
                       let startSec = self.activeTrackTrimRange?.startSeconds,
                       startSec >= 0.5 {
                        self.appliedStartTrimForGeneration = targetGen
                        let target = CMTime(seconds: startSec, preferredTimescale: 600)
                        _ = await self.primaryPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        guard self.playbackGeneration == targetGen else { return }
                        self.currentTime = startSec
                    }
                    self.isBuffering = false
                    if !self.isUserPaused {
                        self.isPlaying = true
                        self.primaryPlayer.play()
                    }
                    self.refreshNowPlayingMetadata()
                case .failed:
                    if let ytVid = youtubeFallbackVideoID, !ytVid.isEmpty, !self.isUserPaused {
                        // Seamlessly fall back to WebKit if direct Innertube stream expired/failed
                        self.startFullLengthYouTubeMusicPlayback(videoID: ytVid, for: track)
                        return
                    }
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
        primaryPlayer.isMuted = false
        primaryPlayer.replaceCurrentItem(with: playerItem)
        #if targetEnvironment(simulator)
        primaryPlayer.volume = volume
        #else
        primaryPlayer.volume = 1.0
        #endif
        primaryPlayer.play()

        isPlaying = true
        isBuffering = false
        refreshNowPlayingMetadata()
    }

    /// User-triggered Play/Pause toggle protected by a 1.0-second cooldown so pause/play fires at most once per second.
    @discardableResult
    public func togglePlayPause(at now: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard playPauseCooldownGate.tryConsume(at: now) else {
            return false
        }
        if isPlaying {
            pause(recordCooldownAt: nil)
        } else {
            resume(recordCooldownAt: nil)
        }
        return true
    }

    public func resetPlayPauseCooldownForTesting() {
        playPauseCooldownGate.reset()
    }

    public func pause() {
        pause(recordCooldownAt: CACurrentMediaTime())
    }

    internal func pause(recordCooldownAt timestamp: TimeInterval?) {
        let wasPlaying = isPlaying
        if let timestamp, wasPlaying {
            playPauseCooldownGate.recordAction(at: timestamp)
        }
        backgroundProtectTask?.cancel()
        delayedKeepAliveStopTask?.cancel()
        isUserPaused = true
        lastUserPauseWallTime = CACurrentMediaTime()
        isPlaying = false
        isBuffering = false

        primaryPlayer.pause()
        crossfadeSecondaryPlayer?.pause()
        ApplicationMusicPlayer.shared.pause()

        if activeYouTubeVideoID != nil {
            let isInBackground = UIApplication.shared.applicationState != .active
            if isInBackground {
                // Phase 2: Soft-pause & mute <video> FIRST, then switch AVAudioSession to non-mixing `.playback`
                // so AuraMusic owns Lock Screen MPRemoteCommandCenter with Play ▶ 100% enabled & clickable!
                evaluateYouTubeJS("if(window.auraControl){window.auraControl.pauseInBackground();}")
                setBackgroundKeepAliveActive(true, mixWithWebKit: false)
                scheduleIdleKeepAliveTimeout()
            } else {
                evaluateYouTubeJS("if(window.auraControl){window.auraControl.pause();}")
                setBackgroundKeepAliveActive(false)
            }
        } else {
            setBackgroundKeepAliveActive(false)
        }
        refreshNowPlayingMetadata()
        reassertNowPlayingOwnershipAfterDelay()
    }

    /// Cleanly pauses AuraMusic when an external app (TikTok, YouTube, Instagram, Telegram, Phone Call) begins audio playback.
    /// Unlike user-initiated background pause, this stops our background keep-alive completely and NEVER switches AVAudioSession
    /// to non-mixing `.playback` so TikTok/YouTube plays smoothly without ever being interrupted back!
    public func pauseForExternalAppAudio() {
        backgroundProtectTask?.cancel()
        delayedKeepAliveStopTask?.cancel()
        isUserPaused = true
        lastUserPauseWallTime = CACurrentMediaTime()
        isPlaying = false
        isBuffering = false

        primaryPlayer.pause()
        crossfadeSecondaryPlayer?.pause()
        ApplicationMusicPlayer.shared.pause()

        if activeYouTubeVideoID != nil {
            evaluateYouTubeJS("if(window.auraControl && window.auraControl.pauseForExternalApp){window.auraControl.pauseForExternalApp();}else if(window.auraControl){window.auraControl.pause();}")
            youtubeWebView?.pauseAllMediaPlayback(completionHandler: nil)
        }
        setBackgroundKeepAliveActive(false)
        updateNowPlayingElapsedTime()
    }

    public func resume() {
        resume(recordCooldownAt: CACurrentMediaTime())
    }

    internal func resume(recordCooldownAt timestamp: TimeInterval?) {
        guard currentTrack != nil || activeYouTubeVideoID != nil else { return }
        let wasPaused = !isPlaying
        if let timestamp, wasPaused {
            playPauseCooldownGate.recordAction(at: timestamp)
        }
        delayedKeepAliveStopTask?.cancel()
        isUserPaused = false
        let now = CACurrentMediaTime()
        clock.refreshSyncAnchor(at: now)
        lastUserResumeWallTime = now
        lastTrackStartWallTime = now
        if activeYouTubeVideoID != nil {
            // Phase 3: Switch back to `.mixWithOthers` BEFORE unmuting <video> so WebKit & keep-alive never interrupt each other!
            setBackgroundKeepAliveActive(true, mixWithWebKit: true)
            evaluateYouTubeJS("if(window.auraControl){window.auraControl.resume();}")
            isPlaying = true
        } else if primaryPlayer.currentItem != nil {
            configureAudioSession(mixWithWebKit: false)
            primaryPlayer.play()
            isPlaying = true
        } else if let track = currentTrack {
            // Track was paused before its initial async stream loaded — restart playback cleanly
            play(track, queue: [])
            return
        }
        refreshNowPlayingMetadata()
        reassertNowPlayingOwnershipAfterDelay()
    }

    private func reassertNowPlayingOwnershipAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            self.refreshNowPlayingMetadata()
        }
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
            let restartPos = activeTrackTrimRange?.startSeconds ?? 0
            triggeredEndTrimForGeneration = -1
            seek(to: restartPos)
            resume()
            if activeYouTubeVideoID == nil && primaryPlayer.currentItem == nil {
                play(current, queue: upNextQueue)
            }
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
            seek(to: activeTrackTrimRange?.startSeconds ?? 0)
        }
    }

    public func skipToPrevious() {
        let trimStart = activeTrackTrimRange?.startSeconds ?? 0
        if currentTime > trimStart + 3.5 {
            seek(to: trimStart)
            return
        }
        if !playbackHistory.isEmpty {
            let previous = playbackHistory.removeFirst()
            if let current = currentTrack {
                upNextQueue.insert(current, at: 0)
            }
            play(previous, queue: [])
        } else {
            seek(to: trimStart)
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
        let originalVolume = max(primaryPlayer.volume, 0.05)

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
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            DynamicIslandNowPlayingCoordinator.shared.updateLiveActivity(
                track: nil,
                isPlaying: false,
                currentTime: 0,
                duration: 0
            )
            return
        }

        let rawDuration = duration > 0 ? duration : track.duration
        let bounds = displayPlaybackBounds(for: rawDuration)
        let displayDuration = bounds.duration
        let displayElapsed = displayPlaybackTime(rawTime: currentTime, rawDuration: rawDuration)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: displayDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: displayElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        // Synchronously attach custom local `file://` photo (or memory-cached cover) immediately on frame 0 so Lock Screen ALWAYS shows it!
        let effectiveArtURL = PersistenceController.shared.effectiveArtworkURL(for: track) ?? track.artworkURL
        var attachedImmediateArtwork = false
        if let artworkURL = effectiveArtURL {
            if let immediateImage = ArtworkCacheManager.shared.cachedMemoryImage(for: artworkURL)
                ?? (artworkURL.isFileURL ? UIImage(contentsOfFile: artworkURL.path) : nil) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: immediateImage.size) { _ in immediateImage }
                attachedImmediateArtwork = true
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused

        // Sync title, artist, album, and cover into WebKit navigator.mediaSession too so Lock Screen shows AuraMusic's custom photo + ⏮/⏭!
        // NOTE: WebKit blocks raw `file://` URLs inside `https://m.youtube.com`, so custom photos are sent as a 512x512 JPEG `data:` URI!
        if activeYouTubeVideoID != nil {
            let targetTrackID = track.id
            if let artworkURL = effectiveArtURL, artworkURL.isFileURL {
                pushWebKitMediaSessionMetadata(title: track.title, artist: track.artist, album: track.album, artworkString: "")
                Task { @MainActor in
                    if let dataURI = await ArtworkCacheManager.shared.base64JPEGDataURI(for: artworkURL),
                       self.currentTrack?.id == targetTrackID,
                       self.activeYouTubeVideoID != nil {
                        self.pushWebKitMediaSessionMetadata(
                            title: track.title,
                            artist: track.artist,
                            album: track.album,
                            artworkString: dataURI
                        )
                    }
                }
            } else {
                pushWebKitMediaSessionMetadata(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    artworkString: effectiveArtURL?.absoluteString ?? ""
                )
            }
        }

        if let artworkURL = effectiveArtURL, !attachedImmediateArtwork {
            let targetTrackID = track.id
            Task { @MainActor in
                if let image = await ArtworkCacheManager.shared.image(for: artworkURL),
                   self.currentTrack?.id == targetTrackID {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    let latestRaw = self.duration > 0 ? self.duration : track.duration
                    var latest = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                    latest[MPMediaItemPropertyArtwork] = artwork
                    latest[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0
                    latest[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.displayPlaybackTime(rawTime: self.currentTime, rawDuration: latestRaw)
                    latest[MPMediaItemPropertyPlaybackDuration] = self.displayPlaybackBounds(for: latestRaw).duration
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = latest
                    MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused
                }
            }
        }

        DynamicIslandNowPlayingCoordinator.shared.updateLiveActivity(
            track: track,
            isPlaying: isPlaying,
            currentTime: displayElapsed,
            duration: displayDuration
        )
    }

    private func pushWebKitMediaSessionMetadata(title: String, artist: String, album: String, artworkString: String) {
        let metaPayload: [String: String] = [
            "title": title,
            "artist": artist,
            "album": album,
            "artwork": artworkString
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: metaPayload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            evaluateYouTubeJS("if(window.auraControl && window.auraControl.setMetadata){window.auraControl.setMetadata(\(jsonString));}")
        }
    }

    private func updateNowPlayingElapsedTime() {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        let rawDur = duration > 0 ? duration : (currentTrack?.duration ?? 0)
        let bounds = displayPlaybackBounds(for: rawDur)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = displayPlaybackTime(rawTime: currentTime, rawDuration: rawDur)
        info[MPMediaItemPropertyPlaybackDuration] = bounds.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
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
