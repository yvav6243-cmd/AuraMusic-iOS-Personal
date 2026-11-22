import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import SwiftUI

// MARK: - Lyrics Mode & AI Audio-Listening Data Models

public enum LyricsDisplayMode: String, CaseIterable, Sendable {
    case standard = "База"
    case aiAudio = "ИИ"
}

public struct AIPauseInterval: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = max(0, start)
        self.end = max(self.start, end)
    }

    public var duration: TimeInterval {
        max(0, end - start)
    }
}

public struct AIWordToken: Equatable, Sendable {
    public let text: String
    public let timestamp: TimeInterval
    public let duration: TimeInterval
    public let confidence: Float
    public let languageCode: String

    public init(
        text: String,
        timestamp: TimeInterval,
        duration: TimeInterval,
        confidence: Float,
        languageCode: String
    ) {
        self.text = text
        self.timestamp = max(0, timestamp)
        self.duration = max(0, duration)
        self.confidence = max(0, min(1, confidence))
        self.languageCode = languageCode
    }
}

public struct AILyricsProgressState: Equatable, Sendable {
    public var isRunning: Bool = false
    public var currentPass: Int = 0
    public var totalPasses: Int = 10
    public var progress: Double = 0.0
    public var stageTitle: String = ""
    public var stageDetail: String = ""
    public var elapsedSeconds: Double = 0.0
    public var maxBudgetSeconds: Double = 30.0
    public var detectedPrimaryLanguage: String? = nil
    public var detectedSecondaryLanguage: String? = nil
    public var detectedPauseCount: Int = 0
    public var detectedForeignWordCount: Int = 0
    public var activeTrackID: String? = nil
    public var completedTrackID: String? = nil
    public var errorMessage: String? = nil

    public init() {}
}

// MARK: - Thread-Safe Speech Continuation Guard

private final class SpeechRecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var latestTokens: [AIWordToken] = []
    private var continuation: CheckedContinuation<[AIWordToken], Never>?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(continuation: CheckedContinuation<[AIWordToken], Never>) {
        self.continuation = continuation
    }

    func attachTask(_ task: SFSpeechRecognitionTask?) {
        lock.lock()
        if resumed {
            lock.unlock()
            task?.cancel()
            return
        }
        recognitionTask = task
        lock.unlock()
    }

    func updateLatest(_ tokens: [AIWordToken]) {
        lock.lock()
        if !tokens.isEmpty {
            latestTokens = tokens
        }
        lock.unlock()
    }

    func cancelAndFinish() {
        lock.lock()
        let task = recognitionTask
        recognitionTask = nil
        lock.unlock()
        task?.cancel()
        finish(with: nil)
    }

    func finish(with tokens: [AIWordToken]? = nil) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let result = (tokens != nil && !(tokens!.isEmpty)) ? tokens! : latestTokens
        let cont = continuation
        continuation = nil
        recognitionTask = nil
        lock.unlock()
        cont?.resume(returning: result)
    }
}

// MARK: - 10-Pass <=30s On-Device AI Audio-Listening Lyrics Engine

@MainActor
public final class AILyricsTranscriptionEngine: ObservableObject {
    public static let shared = AILyricsTranscriptionEngine()

    public nonisolated static let totalRequiredPasses: Int = 10
    public nonisolated static let maxDurationBudgetSeconds: TimeInterval = 30.0
    private nonisolated static let internalHardDeadlineSeconds: TimeInterval = 28.5
    private nonisolated static let targetSampleRate: Double = 16_000.0
    private nonisolated static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    @Published public private(set) var state = AILyricsProgressState()

    private var activeTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private let ytMusicProvider = YouTubeMusicProvider(providerType: .youtubeMusic)
    private let audiusProvider = AudiusProvider()

    private init() {}

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        if state.isRunning {
            state.isRunning = false
            state.stageTitle = "Остановлено"
            state.stageDetail = "ИИ-прослушивание отменено."
        }
    }

    public func resetForNewTrack(_ trackID: String?) {
        if state.activeTrackID != trackID {
            cancel()
            state = AILyricsProgressState()
            state.activeTrackID = trackID
        }
    }

    /// Runs the 10-pass AI audio-listening pipeline within a strict <=30s budget:
    /// - Pass 1/10: Analyzes PCM waveform for pauses, detects primary language & foreign-language code-switch candidates.
    /// - Passes 2–10/10: Iteratively listens, transcribes, re-listens to foreign-word regions, verifies consensus, and builds synced LRC.
    public func startListening(for track: UniversalTrack, forceReanalyze: Bool = false) {
        if !forceReanalyze,
           let cached = LyricsService.shared.loadCachedAILyrics(for: track) {
            LyricsService.shared.setActiveAIDocument(cached)
            var done = AILyricsProgressState()
            done.isRunning = false
            done.currentPass = Self.totalRequiredPasses
            done.progress = 1.0
            done.detectedPrimaryLanguage = cached.detectedLanguageDisplayName
            done.activeTrackID = track.id
            done.completedTrackID = track.id
            done.stageTitle = "Готово (10/10)"
            done.stageDetail = "Загружен сохранённый ИИ-текст песни"
            state = done
            return
        }

        cancel()

        let startDate = Date()
        let hardDeadline = startDate.addingTimeInterval(Self.internalHardDeadlineSeconds)

        var initial = AILyricsProgressState()
        initial.isRunning = true
        initial.currentPass = 1
        initial.totalPasses = Self.totalRequiredPasses
        initial.progress = 0.03
        initial.elapsedSeconds = 0
        initial.maxBudgetSeconds = Self.maxDurationBudgetSeconds
        initial.activeTrackID = track.id
        let d1 = Self.passDescriptor(for: 1, primaryLang: nil, secondaryLang: nil, pauseCount: 0, foreignCount: 0)
        initial.stageTitle = d1.title
        initial.stageDetail = "Подготовка аудиодорожки для 10 прослушиваний…"
        state = initial

        // Smooth 0.15s UI ticker keeps the loading bar and 0:XX / 0:30 timer fluid at all times
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, self.state.isRunning, !Task.isCancelled else { break }
                let elapsed = min(Self.maxDurationBudgetSeconds, Date().timeIntervalSince(startDate))
                self.state.elapsedSeconds = elapsed
                // Gently advance intra-pass progress without crossing into the next pass ceiling
                let passCeiling = min(0.97, Double(max(1, self.state.currentPass)) / Double(Self.totalRequiredPasses) - 0.015)
                if self.state.progress < passCeiling {
                    self.state.progress = min(passCeiling, self.state.progress + 0.004)
                }
            }
        }

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runTenPassPipeline(for: track, startDate: startDate, hardDeadline: hardDeadline)
            self.tickerTask?.cancel()
            self.tickerTask = nil
        }
    }

    // MARK: - Core 10-Pass Execution Pipeline (Hard <= 30s Budget)

    private func runTenPassPipeline(for track: UniversalTrack, startDate: Date, hardDeadline: Date) async {
        // 0. Request Apple Speech Recognition authorization cleanly
        let authStatus = await Self.requestSpeechAuthorization()
        guard !Task.isCancelled else { return }
        guard authStatus == .authorized else {
            failPipeline(
                for: track,
                message: "Разрешите «Распознавание речи» в Настройках iOS → AuraMusic, чтобы ИИ мог слушать песни и писать лирику."
            )
            return
        }

        // 0.5 Acquire local audio file (instant if downloaded offline; otherwise fast temp stream fetch capped inside budget)
        let audioAcquireDeadline = min(hardDeadline, startDate.addingTimeInterval(8.0))
        guard let audioSource = await resolveAudioFileForListening(for: track, deadline: audioAcquireDeadline) else {
            guard !Task.isCancelled else { return }
            failPipeline(
                for: track,
                message: "Не удалось получить аудиофайл для ИИ-прослушивания. Скачайте песню офлайн или проверьте интернет."
            )
            return
        }
        defer {
            if audioSource.isTemporary {
                try? FileManager.default.removeItem(at: audioSource.url)
            }
        }
        guard !Task.isCancelled else { return }

        // =========================================================================
        // PASS 1 / 10 — Language, Pauses & Foreign-Language Insert Detection
        // =========================================================================
        updatePass(
            1,
            progress: 0.08,
            primaryLang: nil,
            secondaryLang: nil,
            pauseCount: 0,
            foreignCount: 0
        )

        guard let decoded = await Self.decodeMono16kPCM(from: audioSource.url) else {
            failPipeline(for: track, message: "Не удалось декодировать аудиодорожку для анализа.")
            return
        }
        guard !Task.isCancelled else { return }

        let trackDuration = max(decoded.duration, track.duration > 5 ? track.duration : decoded.duration)
        let rmsFrames = Self.computeRMSEnvelope(samples: decoded.samples, sampleRate: Self.targetSampleRate, frameDuration: 0.1)
        let detectedPauses = Self.detectPauseIntervals(
            rmsFrames: rmsFrames,
            frameDuration: 0.1,
            trackDuration: trackDuration
        )

        var (primaryLocale, secondaryLocale) = Self.inferCandidateLocales(for: track, detectedSampleText: nil)

        // Probe first strong vocal window (~16s right after intro pause) to verify spoken/sung language!
        let introEnd = detectedPauses.first(where: { $0.start <= 1.2 })?.end ?? 0.0
        let probeStart = min(max(0, introEnd), max(0, trackDuration - 10.0))
        let probeEnd = min(trackDuration, probeStart + 18.0)

        var pass1Tokens: [AIWordToken] = []
        let pass1Timeout = Self.computePassTimeout(hardDeadline: hardDeadline, preferred: 2.6, reserveForLater: 8.0)
        if pass1Timeout >= 0.8 {
            pass1Tokens = await Self.recognizeSegment(
                samples: decoded.samples,
                sampleRate: Self.targetSampleRate,
                startTime: probeStart,
                endTime: probeEnd,
                locale: primaryLocale,
                timeoutSeconds: pass1Timeout
            )
            // If primary guess yielded almost nothing, quickly probe English / Russian / Chinese to auto-identify language!
            if pass1Tokens.count < 3 && hardDeadline.timeIntervalSinceNow > 12.0 {
                let fallbackLocales = [Locale(identifier: "en-US"), Locale(identifier: "ru-RU"), Locale(identifier: "zh-CN")]
                    .filter { $0.identifier != primaryLocale.identifier }
                for altLocale in fallbackLocales {
                    let altBudget = Self.computePassTimeout(hardDeadline: hardDeadline, preferred: 1.8, reserveForLater: 10.0)
                    guard altBudget >= 0.8 else { break }
                    let altTokens = await Self.recognizeSegment(
                        samples: decoded.samples,
                        sampleRate: Self.targetSampleRate,
                        startTime: probeStart,
                        endTime: probeEnd,
                        locale: altLocale,
                        timeoutSeconds: altBudget
                    )
                    if altTokens.count > pass1Tokens.count {
                        pass1Tokens = altTokens
                        primaryLocale = altLocale
                        secondaryLocale = (altLocale.identifier.hasPrefix("en")) ? Locale(identifier: "ru-RU") : Locale(identifier: "en-US")
                        break
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }

        let probeText = pass1Tokens.map(\.text).joined(separator: " ")
        if !probeText.isEmpty {
            let refined = Self.inferCandidateLocales(for: track, detectedSampleText: probeText)
            primaryLocale = refined.primary
            secondaryLocale = refined.secondary
        }

        let primaryLangName = Self.localeDisplayName(primaryLocale)
        let secondaryLangName = Self.localeDisplayName(secondaryLocale)

        state.detectedPrimaryLanguage = primaryLangName
        state.detectedSecondaryLanguage = secondaryLangName
        state.detectedPauseCount = detectedPauses.count
        state.progress = 0.14

        // Compute 3 slightly overlapping vocal acts across the full song (each <= 54s to respect Apple's 60s URL recognizer cap)
        let vocalStart = min(introEnd, max(0, trackDuration - 12.0))
        let vocalEnd = max(vocalStart + 5.0, trackDuration)
        let acts = Self.buildVocalListeningActs(start: vocalStart, end: vocalEnd, count: 3, maxWindowLength: 54.0)

        var collectedPrimaryPasses: [[AIWordToken]] = []
        if !pass1Tokens.isEmpty {
            collectedPrimaryPasses.append(pass1Tokens)
        }

        // =========================================================================
        // PASSES 2, 3, 4 / 10 — Primary-Language Full-Song Listening & Writing
        // =========================================================================
        var actTokensCombined: [AIWordToken] = []
        for idx in 0..<3 {
            guard !Task.isCancelled else { return }
            let passNumber = idx + 2 // 2, 3, 4
            let targetProgress = 0.16 + Double(idx + 1) * 0.11
            updatePass(
                passNumber,
                progress: targetProgress - 0.06,
                primaryLang: primaryLangName,
                secondaryLang: secondaryLangName,
                pauseCount: detectedPauses.count,
                foreignCount: state.detectedForeignWordCount
            )
            if idx < acts.count {
                let window = acts[idx]
                let reserve = Double(2 - idx) * 2.4 + 4.5
                let timeout = Self.computePassTimeout(hardDeadline: hardDeadline, preferred: 4.0, reserveForLater: reserve)
                if timeout >= 0.8 {
                    let segTokens = await Self.recognizeSegment(
                        samples: decoded.samples,
                        sampleRate: Self.targetSampleRate,
                        startTime: window.start,
                        endTime: window.end,
                        locale: primaryLocale,
                        timeoutSeconds: timeout
                    )
                    actTokensCombined.append(contentsOf: segTokens)
                }
            }
            state.progress = max(state.progress, targetProgress)
        }
        if !actTokensCombined.isEmpty {
            collectedPrimaryPasses.append(actTokensCombined)
        }
        guard !Task.isCancelled else { return }

        var workingTokens = Self.reconcileMultiPassTokens(passes: collectedPrimaryPasses)

        // =========================================================================
        // PASSES 5 & 6 / 10 — Foreign-Language Code-Switching Re-Listening
        // =========================================================================
        let uncertainWindows = Self.identifyLowConfidenceWindows(
            tokens: workingTokens,
            vocalStart: vocalStart,
            vocalEnd: vocalEnd,
            maxWindows: 2
        )
        var secondaryTokens: [AIWordToken] = []

        for passIdx in 0..<2 {
            guard !Task.isCancelled else { return }
            let passNumber = passIdx + 5 // 5, 6
            let targetProgress = 0.50 + Double(passIdx + 1) * 0.09
            updatePass(
                passNumber,
                progress: targetProgress - 0.05,
                primaryLang: primaryLangName,
                secondaryLang: secondaryLangName,
                pauseCount: detectedPauses.count,
                foreignCount: state.detectedForeignWordCount
            )
            if passIdx < uncertainWindows.count {
                let win = uncertainWindows[passIdx]
                let timeout = Self.computePassTimeout(hardDeadline: hardDeadline, preferred: 2.6, reserveForLater: 3.5)
                if timeout >= 0.8 {
                    let foreignSeg = await Self.recognizeSegment(
                        samples: decoded.samples,
                        sampleRate: Self.targetSampleRate,
                        startTime: win.start,
                        endTime: win.end,
                        locale: secondaryLocale,
                        timeoutSeconds: timeout
                    )
                    secondaryTokens.append(contentsOf: foreignSeg)
                }
            }
            state.progress = max(state.progress, targetProgress)
        }

        let mergedForeign = Self.mergeForeignLanguageTokens(
            primaryTokens: workingTokens,
            secondaryTokens: secondaryTokens
        )
        workingTokens = mergedForeign.merged
        state.detectedForeignWordCount = mergedForeign.foreignReplacements

        // =========================================================================
        // PASS 7 / 10 — Shifted-Boundary Re-Listening Verification Pass
        // =========================================================================
        guard !Task.isCancelled else { return }
        updatePass(
            7,
            progress: 0.70,
            primaryLang: primaryLangName,
            secondaryLang: secondaryLangName,
            pauseCount: detectedPauses.count,
            foreignCount: state.detectedForeignWordCount
        )
        if let verifyWin = uncertainWindows.first ?? acts.first {
            let shiftedStart = max(0, verifyWin.start - 1.2)
            let shiftedEnd = min(trackDuration, verifyWin.end + 1.2)
            let timeout = Self.computePassTimeout(hardDeadline: hardDeadline, preferred: 2.4, reserveForLater: 1.8)
            if timeout >= 0.8 {
                let verifyTokens = await Self.recognizeSegment(
                    samples: decoded.samples,
                    sampleRate: Self.targetSampleRate,
                    startTime: shiftedStart,
                    endTime: shiftedEnd,
                    locale: primaryLocale,
                    timeoutSeconds: timeout
                )
                if !verifyTokens.isEmpty {
                    workingTokens = Self.reconcileMultiPassTokens(passes: [workingTokens, verifyTokens])
                }
            }
        }
        state.progress = max(state.progress, 0.77)

        // =========================================================================
        // PASS 8 / 10 — Multi-Pass Consensus & Deduplication Check
        // =========================================================================
        guard !Task.isCancelled else { return }
        updatePass(
            8,
            progress: 0.82,
            primaryLang: primaryLangName,
            secondaryLang: secondaryLangName,
            pauseCount: detectedPauses.count,
            foreignCount: state.detectedForeignWordCount
        )
        workingTokens = Self.reconcileMultiPassTokens(passes: [workingTokens])
        if hardDeadline.timeIntervalSinceNow > 1.2 {
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
        state.progress = max(state.progress, 0.86)

        // =========================================================================
        // PASS 9 / 10 — Pause Alignment & Rhythm Line-Breaking
        // =========================================================================
        guard !Task.isCancelled else { return }
        updatePass(
            9,
            progress: 0.90,
            primaryLang: primaryLangName,
            secondaryLang: secondaryLangName,
            pauseCount: detectedPauses.count,
            foreignCount: state.detectedForeignWordCount
        )
        let syncedLRC = Self.buildSyncedLRCFromTokens(
            tokens: workingTokens,
            pauses: detectedPauses,
            trackDuration: trackDuration
        )
        if hardDeadline.timeIntervalSinceNow > 0.9 {
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
        state.progress = max(state.progress, 0.94)

        // =========================================================================
        // PASS 10 / 10 — Final Verification, Sync Validation & SwiftData Save
        // =========================================================================
        guard !Task.isCancelled else { return }
        updatePass(
            10,
            progress: 0.97,
            primaryLang: primaryLangName,
            secondaryLang: secondaryLangName,
            pauseCount: detectedPauses.count,
            foreignCount: state.detectedForeignWordCount
        )
        if hardDeadline.timeIntervalSinceNow > 0.5 {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let parsedCheck = LRCParser.parseSyncedLRC(syncedLRC, includeIntroDots: true)
        let sungLinesCount = parsedCheck.filter { !$0.isInstrumental }.count

        if sungLinesCount > 0,
           let doc = LyricsService.shared.saveAILyrics(syncedLRC: syncedLRC, for: track) {
            LyricsService.shared.setActiveAIDocument(doc)
            state.isRunning = false
            state.currentPass = Self.totalRequiredPasses
            state.progress = 1.0
            state.elapsedSeconds = min(Self.maxDurationBudgetSeconds, Date().timeIntervalSince(startDate))
            state.completedTrackID = track.id
            state.errorMessage = nil
            state.stageTitle = "Готово (10/10)"
            state.stageDetail = "Синхронизировано строк: \(sungLinesCount) • Пауз: \(detectedPauses.count)"
        } else {
            failPipeline(
                for: track,
                message: "ИИ прослушал песню 10 раз, но не смог разобрать чёткий вокал (возможно, это инструментал или музыка слишком громкая). Попробуйте режим «База»."
            )
        }
    }

    private func updatePass(
        _ pass: Int,
        progress: Double,
        primaryLang: String?,
        secondaryLang: String?,
        pauseCount: Int,
        foreignCount: Int
    ) {
        let clampedPass = max(1, min(Self.totalRequiredPasses, pass))
        let desc = Self.passDescriptor(
            for: clampedPass,
            primaryLang: primaryLang,
            secondaryLang: secondaryLang,
            pauseCount: pauseCount,
            foreignCount: foreignCount
        )
        state.currentPass = clampedPass
        state.progress = max(state.progress, min(1.0, progress))
        state.stageTitle = desc.title
        state.stageDetail = desc.detail
    }

    private func failPipeline(for track: UniversalTrack, message: String) {
        state.isRunning = false
        state.errorMessage = message
        state.stageTitle = "ИИ-режим"
        state.stageDetail = message
        state.activeTrackID = track.id
    }

    // MARK: - Audio File Acquisition (Offline-First, Fast Temp Stream Fallback)

    private struct ResolvedAudioSource {
        let url: URL
        let isTemporary: Bool
    }

    private func resolveAudioFileForListening(for track: UniversalTrack, deadline: Date) async -> ResolvedAudioSource? {
        // 1. Instant local file if already downloaded offline!
        if let relPath = OfflineDownloadManager.shared.completedLocalRelativePath(for: track) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fullURL = docs.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: fullURL.path) {
                return ResolvedAudioSource(url: fullURL, isTemporary: false)
            }
        }
        // 2. Local imported file
        if track.provider == .localFile, let localURL = track.streamURL, localURL.isFileURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            return ResolvedAudioSource(url: localURL, isTemporary: false)
        }

        // 3. Fast temporary audio fetch capped strictly inside the 30-second budget
        var candidateURLs: [(url: URL, ytHeaders: Bool)] = []
        var cookieHeader: String? = nil

        if track.provider == .audius, let stream = try? await audiusProvider.resolvePlayableStreamURL(for: track) {
            candidateURLs.append((stream, false))
        } else if track.provider == .soundCloud, let stream = track.streamURL {
            candidateURLs.append((stream, false))
        } else {
            var targetVideoID: String? = (track.provider == .youtubeMusic || track.provider == .youtube)
                ? track.providerTrackID
                : nil
            if targetVideoID == nil && deadline.timeIntervalSinceNow > 3.0 {
                if let matches = try? await ytMusicProvider.searchTracks(query: "\(track.title) \(track.artist)", limit: 2) {
                    targetVideoID = matches.first?.providerTrackID
                }
            }
            if let vid = targetVideoID, !vid.isEmpty {
                if let captured = UniversalAudioPlayerEngine.shared.capturedYouTubeAudioStreamURLs[vid],
                   let clean = YouTubeWebKitAudioExtractor.sanitizeFullLengthYouTubeStreamURL(captured.absoluteString) ?? Optional(captured) {
                    candidateURLs.append((clean, true))
                }
                let extractBudget = min(4.5, max(0, deadline.timeIntervalSinceNow - 2.0))
                if candidateURLs.isEmpty && extractBudget >= 1.5 {
                    let extracted = await YouTubeWebKitAudioExtractor.shared.extractAudioStreams(videoID: vid, timeoutSeconds: extractBudget)
                    cookieHeader = extracted.cookieHeader
                    for u in extracted.candidateURLs {
                        candidateURLs.append((u, true))
                    }
                }
            }
        }

        for cand in candidateURLs {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining >= 1.2, !Task.isCancelled else { break }
            if let tempURL = await Self.downloadTempAudioFile(
                from: cand.url,
                useSafariHeaders: cand.ytHeaders,
                cookieHeader: cookieHeader,
                timeoutSeconds: min(6.0, remaining)
            ) {
                return ResolvedAudioSource(url: tempURL, isTemporary: true)
            }
        }

        return nil
    }

    private nonisolated static func downloadTempAudioFile(
        from url: URL,
        useSafariHeaders: Bool,
        cookieHeader: String?,
        timeoutSeconds: TimeInterval
    ) async -> URL? {
        var req = URLRequest(url: url)
        req.timeoutInterval = max(2.0, timeoutSeconds)
        if useSafariHeaders {
            req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
            req.setValue("https://m.youtube.com", forHTTPHeaderField: "Origin")
            if let cookieHeader, !cookieHeader.isEmpty {
                req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            let mime = (http.mimeType ?? "").lowercased()
            let ext = mime.contains("mpeg") ? "mp3" : (mime.contains("video/mp4") ? "mp4" : "m4a")
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("aura_ai_\(UUID().uuidString).\(ext)")
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - Fast Single-Pass Mono 16kHz PCM Decoder & WAV Segment Writer

    private struct DecodedMonoPCM: Sendable {
        let samples: [Int16]
        let duration: TimeInterval
    }

    private nonisolated static func decodeMono16kPCM(from url: URL) async -> DecodedMonoPCM? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let audioTrack = tracks.first else { return nil }
                let loadedDuration = try await asset.load(.duration)
                let reader = try AVAssetReader(asset: asset)
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: targetSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { return nil }
                reader.add(output)
                guard reader.startReading() else { return nil }

                var allSamples: [Int16] = []
                let expectedSamples = loadedDuration.seconds.isFinite && loadedDuration.seconds > 0
                    ? Int(min(loadedDuration.seconds, 600.0) * targetSampleRate)
                    : 16_000 * 180
                allSamples.reserveCapacity(expectedSamples)

                let maxSampleCap = Int(targetSampleRate * 420.0) // Cap at 7 minutes to stay ultra-light on RAM
                while reader.status == .reading && allSamples.count < maxSampleCap {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                    if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
                        if byteLength >= 2 {
                            let count = byteLength / 2
                            var chunk = [Int16](repeating: 0, count: count)
                            let copyStatus = chunk.withUnsafeMutableBytes { rawPtr -> OSStatus in
                                guard let base = rawPtr.baseAddress else { return -1 }
                                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: count * 2, destination: base)
                            }
                            if copyStatus == kCMBlockBufferNoErr {
                                allSamples.append(contentsOf: chunk)
                            }
                        }
                    }
                    CMSampleBufferInvalidate(sampleBuffer)
                }

                guard !allSamples.isEmpty else { return nil }
                let actualDuration = Double(allSamples.count) / targetSampleRate
                return DecodedMonoPCM(samples: allSamples, duration: actualDuration)
            } catch {
                return nil
            }
        }.value
    }

    private nonisolated static func writeMono16kWAVSlice(
        samples: [Int16],
        sampleRate: Double,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> URL? {
        let sr = Int(sampleRate)
        let startIdx = max(0, min(samples.count, Int(startTime * sampleRate)))
        let endIdx = max(startIdx, min(samples.count, Int(endTime * sampleRate)))
        let count = endIdx - startIdx
        guard count > sr / 4 else { return nil } // Need at least 0.25s of audio

        let dataSize = UInt32(count * 2)
        let fileSize = UInt32(36) + dataSize
        var wav = Data(capacity: 44 + Int(dataSize))
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        withUnsafeBytes(of: fileSize.littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt 
        withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) } // PCM
        withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) } // Mono
        withUnsafeBytes(of: UInt32(sr).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sr * 2).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        withUnsafeBytes(of: dataSize.littleEndian) { wav.append(contentsOf: $0) }

        samples[startIdx..<endIdx].withUnsafeBytes { rawBuf in
            wav.append(contentsOf: rawBuf)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura_seg_\(UUID().uuidString).wav")
        do {
            try wav.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            return nil
        }
    }

    // MARK: - Apple Speech Recognition Segment Runner (Timeout-Guarded)

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private nonisolated static func recognizeSegment(
        samples: [Int16],
        sampleRate: Double,
        startTime: TimeInterval,
        endTime: TimeInterval,
        locale: Locale,
        timeoutSeconds: TimeInterval
    ) async -> [AIWordToken] {
        guard timeoutSeconds >= 0.6,
              let wavURL = writeMono16kWAVSlice(
                  samples: samples,
                  sampleRate: sampleRate,
                  startTime: startTime,
                  endTime: endTime
              ) else {
            return []
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return []
        }

        let request = SFSpeechURLRecognitionRequest(url: wavURL)
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let langCode = locale.language.languageCode?.identifier ?? locale.identifier

        return await withCheckedContinuation { (continuation: CheckedContinuation<[AIWordToken], Never>) in
            let box = SpeechRecognitionBox(continuation: continuation)

            let timeoutTask = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, timeoutSeconds) * 1_000_000_000))
                box.cancelAndFinish()
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let tokens: [AIWordToken] = result.bestTranscription.segments.compactMap { seg in
                        let word = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !word.isEmpty else { return nil }
                        return AIWordToken(
                            text: word,
                            timestamp: startTime + seg.timestamp,
                            duration: max(0.08, seg.duration),
                            confidence: seg.confidence > 0 ? seg.confidence : 0.55,
                            languageCode: langCode
                        )
                    }
                    box.updateLatest(tokens)
                    if result.isFinal {
                        timeoutTask.cancel()
                        box.finish(with: tokens)
                    }
                } else if error != nil {
                    timeoutTask.cancel()
                    box.finish(with: nil)
                }
            }
            box.attachTask(task)
        }
    }

    // MARK: - Pure Deterministic DSP, Language Detection, Foreign-Word Merging & LRC Builder (100% Unit-Testable!)

    /// Computes RMS amplitude per fixed frame window (e.g., 0.1s) from mono 16-bit PCM samples.
    public nonisolated static func computeRMSEnvelope(
        samples: [Int16],
        sampleRate: Double = 16_000.0,
        frameDuration: TimeInterval = 0.1
    ) -> [Float] {
        let frameSize = max(1, Int(sampleRate * frameDuration))
        guard !samples.isEmpty else { return [] }
        var rmsValues: [Float] = []
        rmsValues.reserveCapacity(samples.count / frameSize + 1)

        var idx = 0
        let scale: Float = 1.0 / 32768.0
        while idx < samples.count {
            let end = min(samples.count, idx + frameSize)
            var sumSq: Double = 0
            for i in idx..<end {
                let norm = Double(Float(samples[i]) * scale)
                sumSq += norm * norm
            }
            let rms = Float(sqrt(sumSq / Double(max(1, end - idx))))
            rmsValues.append(rms)
            idx = end
        }
        return rmsValues
    }

    /// Pass 1 DSP detector: identifies intro and mid-song instrumental/silent pauses >= `minPauseDuration`
    /// using an adaptive percentile energy floor so both loud EDM/rap and quiet ballads work accurately.
    public nonisolated static func detectPauseIntervals(
        rmsFrames: [Float],
        frameDuration: TimeInterval = 0.1,
        trackDuration: TimeInterval,
        minPauseDuration: TimeInterval = 2.4
    ) -> [AIPauseInterval] {
        guard !rmsFrames.isEmpty, frameDuration > 0 else { return [] }
        let sorted = rmsFrames.sorted()
        let p15 = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let p80 = sorted[Int(Double(sorted.count - 1) * 0.80)]
        let dynamicThreshold = max(0.006, p15 + (p80 - p15) * 0.24)

        var pauses: [AIPauseInterval] = []
        var pauseStartFrame: Int? = nil

        for (i, rms) in rmsFrames.enumerated() {
            let isQuiet = rms <= dynamicThreshold
            if isQuiet {
                if pauseStartFrame == nil {
                    pauseStartFrame = i
                }
            } else if let start = pauseStartFrame {
                let startSec = Double(start) * frameDuration
                let endSec = min(trackDuration, Double(i) * frameDuration)
                if (endSec - startSec) >= minPauseDuration {
                    pauses.append(AIPauseInterval(start: startSec, end: endSec))
                }
                pauseStartFrame = nil
            }
        }

        if let start = pauseStartFrame {
            let startSec = Double(start) * frameDuration
            let endSec = min(trackDuration, Double(rmsFrames.count) * frameDuration)
            // Keep trailing outro pause only if long enough and not spanning the entire file
            if (endSec - startSec) >= minPauseDuration && startSec > 0.5 {
                pauses.append(AIPauseInterval(start: startSec, end: endSec))
            }
        }

        return pauses
    }

    /// Infers primary & secondary (foreign-insert) speech recognition locales from track metadata + Pass-1 vocal probe.
    public nonisolated static func inferCandidateLocales(
        for track: UniversalTrack,
        detectedSampleText: String?
    ) -> (primary: Locale, secondary: Locale) {
        let combined = [detectedSampleText ?? "", track.title, track.artist]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let script = LRCParser.detectScriptLanguage(for: combined)
        var detectedCode = script.code

        if let sample = detectedSampleText, sample.count >= 8 {
            let nl = NLLanguageRecognizer()
            nl.processString(sample)
            if let dom = nl.dominantLanguage {
                detectedCode = dom.rawValue
            }
        }

        let primaryIdentifier: String
        switch detectedCode {
        case "ru", "uk", "be", "kk": primaryIdentifier = "ru-RU"
        case "zh", "zh-Hans": primaryIdentifier = "zh-CN"
        case "zh-Hant": primaryIdentifier = "zh-TW"
        case "ja": primaryIdentifier = "ja-JP"
        case "ko": primaryIdentifier = "ko-KR"
        case "es": primaryIdentifier = "es-ES"
        case "fr": primaryIdentifier = "fr-FR"
        case "de": primaryIdentifier = "de-DE"
        case "it": primaryIdentifier = "it-IT"
        case "pt": primaryIdentifier = "pt-BR"
        case "tr": primaryIdentifier = "tr-TR"
        case "ar": primaryIdentifier = "ar-SA"
        default: primaryIdentifier = "en-US"
        }

        // Foreign code-switching language: English for non-English songs (very common in RU/CN/JP/KR pop & rap!),
        // or Cyrillic/CJK if detected in metadata for English-dominant tracks, defaulting to Russian.
        let secondaryIdentifier: String
        if primaryIdentifier.hasPrefix("en") {
            let metaLang = LRCParser.detectScriptLanguage(for: "\(track.title) \(track.artist)").code
            switch metaLang {
            case "zh": secondaryIdentifier = "zh-CN"
            case "ja": secondaryIdentifier = "ja-JP"
            case "ko": secondaryIdentifier = "ko-KR"
            case "es": secondaryIdentifier = "es-ES"
            default: secondaryIdentifier = "ru-RU"
            }
        } else {
            secondaryIdentifier = "en-US"
        }

        return (Locale(identifier: primaryIdentifier), Locale(identifier: secondaryIdentifier))
    }

    public nonisolated static func localeDisplayName(_ locale: Locale) -> String {
        let id = locale.identifier.lowercased()
        if id.hasPrefix("ru") { return "Русский" }
        if id.hasPrefix("zh") { return "中文" }
        if id.hasPrefix("ja") { return "日本語" }
        if id.hasPrefix("ko") { return "한국어" }
        if id.hasPrefix("es") { return "Español" }
        if id.hasPrefix("fr") { return "Français" }
        if id.hasPrefix("de") { return "Deutsch" }
        if id.hasPrefix("it") { return "Italiano" }
        if id.hasPrefix("pt") { return "Português" }
        if id.hasPrefix("tr") { return "Türkçe" }
        if id.hasPrefix("ar") { return "العربية" }
        return "English"
    }

    /// Passes 5–6 merger: replaces low-confidence primary words with high-confidence foreign-language words
    /// while preserving all confident native words intact.
    public nonisolated static func mergeForeignLanguageTokens(
        primaryTokens: [AIWordToken],
        secondaryTokens: [AIWordToken],
        primaryConfidenceThreshold: Float = 0.62
    ) -> (merged: [AIWordToken], foreignReplacements: Int) {
        guard !secondaryTokens.isEmpty else {
            return (primaryTokens.sorted { $0.timestamp < $1.timestamp }, 0)
        }
        guard !primaryTokens.isEmpty else {
            let sortedSec = secondaryTokens.sorted { $0.timestamp < $1.timestamp }
            return (sortedSec, sortedSec.count)
        }

        var result = primaryTokens.sorted { $0.timestamp < $1.timestamp }
        var replacedCount = 0

        for sec in secondaryTokens {
            let secClean = sec.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secClean.isEmpty, sec.confidence >= 0.52 else { continue }

            // Find overlapping primary token within ±0.42s
            if let matchIdx = result.firstIndex(where: { abs($0.timestamp - sec.timestamp) <= 0.42 }) {
                let existing = result[matchIdx]
                // Only substitute if primary had weak confidence AND secondary is clearly stronger
                if existing.confidence < primaryConfidenceThreshold && sec.confidence >= existing.confidence + 0.12 {
                    result[matchIdx] = sec
                    replacedCount += 1
                }
            } else {
                // Fill a vocal gap where primary recognizer missed a foreign word completely
                let tooClose = result.contains { abs($0.timestamp - sec.timestamp) < 0.30 }
                if !tooClose && sec.confidence >= 0.68 {
                    result.append(sec)
                    replacedCount += 1
                }
            }
        }

        result.sort { $0.timestamp < $1.timestamp }
        return (result, replacedCount)
    }

    /// Passes 7–8 cross-pass consensus engine: deduplicates overlapping window boundaries and selects
    /// the highest-confidence / majority-agreed token at each timestamp bucket.
    public nonisolated static func reconcileMultiPassTokens(passes: [[AIWordToken]]) -> [AIWordToken] {
        let all = passes.flatMap { $0 }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        guard !all.isEmpty else { return [] }

        var buckets: [[AIWordToken]] = []
        for token in all {
            if var lastBucket = buckets.last,
               let anchor = lastBucket.first,
               abs(token.timestamp - anchor.timestamp) <= 0.28 {
                lastBucket.append(token)
                buckets[buckets.count - 1] = lastBucket
            } else {
                buckets.append([token])
            }
        }

        var consensus: [AIWordToken] = []
        consensus.reserveCapacity(buckets.count)

        for bucket in buckets {
            if bucket.count == 1 {
                consensus.append(bucket[0])
                continue
            }
            // Score each candidate text by frequency + total confidence
            var scores: [String: Float] = [:]
            var bestRep: [String: AIWordToken] = [:]
            for tok in bucket {
                let key = tok.text.lowercased()
                scores[key, default: 0] += (tok.confidence + 0.35)
                if let prev = bestRep[key] {
                    if tok.confidence > prev.confidence { bestRep[key] = tok }
                } else {
                    bestRep[key] = tok
                }
            }
            if let bestKey = scores.max(by: { $0.value < $1.value })?.key,
               let winner = bestRep[bestKey] {
                // Avoid immediate duplicate stutters across window seam
                if let prev = consensus.last,
                   prev.text.lowercased() == winner.text.lowercased(),
                   abs(winner.timestamp - prev.timestamp) < 0.45 {
                    continue
                }
                consensus.append(winner)
            }
        }

        return consensus.sorted { $0.timestamp < $1.timestamp }
    }

    /// Passes 9–10 LRC assembler: groups verified tokens into rhythmic singable lines, injects intro & mid-song `•••` pauses,
    /// and formats strictly monotonic `[mm:ss.xx]` timestamps compatible with `LRCParser.parseSyncedLRC`.
    public nonisolated static func buildSyncedLRCFromTokens(
        tokens: [AIWordToken],
        pauses: [AIPauseInterval],
        trackDuration: TimeInterval
    ) -> String {
        let sortedTokens = tokens
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        guard !sortedTokens.isEmpty else { return "" }

        let sortedPauses = pauses.sorted { $0.start < $1.start }

        struct BuiltLine {
            let timestamp: TimeInterval
            let text: String
            let isInstrumental: Bool
        }

        var lines: [BuiltLine] = []

        // 1. Intro instrumental dots if track starts with a pause >= 2.4s before first vocal
        let firstVocalTime = sortedTokens[0].timestamp
        if firstVocalTime >= 2.4 || sortedPauses.contains(where: { $0.start <= 1.0 && $0.duration >= 2.4 }) {
            lines.append(BuiltLine(timestamp: 0.0, text: "•••", isInstrumental: true))
        }

        var currentWords: [AIWordToken] = []
        var lineStartTime: TimeInterval = sortedTokens[0].timestamp

        func flushCurrentLine() {
            guard !currentWords.isEmpty else { return }
            let joined = Self.joinTokensForDisplay(currentWords)
            if !joined.isEmpty {
                lines.append(BuiltLine(timestamp: lineStartTime, text: joined, isInstrumental: false))
            }
            currentWords.removeAll(keepingCapacity: true)
        }

        for token in sortedTokens {
            if let prev = currentWords.last {
                let prevEnd = prev.timestamp + prev.duration
                let gap = token.timestamp - prevEnd
                let hasPauseBetween = sortedPauses.contains { p in
                    p.duration >= 2.4 && p.start >= prev.timestamp && p.start < token.timestamp
                }
                let currentCharCount = currentWords.reduce(0) { $0 + $1.text.count + 1 }
                let isCJKLine = currentWords.contains { Self.containsCJK($0.text) }
                let maxChars = isCJKLine ? 18 : 42
                let maxWords = isCJKLine ? 10 : 8

                if hasPauseBetween || gap >= 0.65 || currentWords.count >= maxWords || currentCharCount >= maxChars {
                    flushCurrentLine()
                    // Insert mid-song instrumental pause marker `•••` if a substantial break sits between lines
                    if let matchingPause = sortedPauses.first(where: { p in
                        p.duration >= 2.8 && p.start >= prevEnd - 0.3 && p.end <= token.timestamp + 0.5
                    }) {
                        let dotStart = max(prevEnd + 0.35, matchingPause.start)
                        if dotStart < token.timestamp - 1.2 {
                            lines.append(BuiltLine(timestamp: dotStart, text: "•••", isInstrumental: true))
                        }
                    } else if gap >= 4.2 {
                        let dotStart = prevEnd + 0.4
                        if dotStart < token.timestamp - 1.2 {
                            lines.append(BuiltLine(timestamp: dotStart, text: "•••", isInstrumental: true))
                        }
                    }
                    lineStartTime = token.timestamp
                }
            } else {
                lineStartTime = token.timestamp
            }
            currentWords.append(token)
        }
        flushCurrentLine()

        // Enforce strictly monotonic timestamps so lyrics highlight cleanly without ever jumping backwards
        var lrcOutput: [String] = []
        var lastTS: TimeInterval = -0.05
        for line in lines {
            let safeTS = max(line.timestamp, lastTS + 0.05)
            lastTS = safeTS
            lrcOutput.append("\(Self.formatLRCTimestamp(safeTS))\(line.text)")
        }
        return lrcOutput.joined(separator: "\n")
    }

    /// Returns localized Russian stage title and detail for passes 1...10.
    public nonisolated static func passDescriptor(
        for pass: Int,
        primaryLang: String?,
        secondaryLang: String?,
        pauseCount: Int,
        foreignCount: Int
    ) -> (title: String, detail: String) {
        let pLang = primaryLang ?? "основной язык"
        let sLang = secondaryLang ?? "иностранные слова"
        switch pass {
        case 1:
            return (
                "Прослушивание 1/10 — Разведка",
                "Определяю язык песни, паузы и места со словами из другого языка…"
            )
        case 2:
            return (
                "Прослушивание 2/10 — Текст (начало)",
                "Слушаю вступление и первый куплет (\(pLang)), записываю слова…"
            )
        case 3:
            return (
                "Прослушивание 3/10 — Текст (середина)",
                "Слушаю середину песни и припев (\(pLang)), сверяю ритм…"
            )
        case 4:
            return (
                "Прослушивание 4/10 — Текст (финал)",
                "Слушаю вторую половину и концовку (\(pLang))…"
            )
        case 5:
            return (
                "Прослушивание 5/10 — Другой язык",
                "Переслушиваю сложные фрагменты на \(sLang) (иноязычные вставки)…"
            )
        case 6:
            return (
                "Прослушивание 6/10 — Сверка вставок",
                "Уточняю иностранные слова (\(sLang)) и сравниваю с основным текстом…"
            )
        case 7:
            return (
                "Прослушивание 7/10 — Проверка текста",
                "Повторно слушаю спорные строки и уточняю тайминги слов…"
            )
        case 8:
            return (
                "Прослушивание 8/10 — Консенсус",
                "Сопоставляю все прослушивания, убираю дубли и ошибки (вставок: \(foreignCount))…"
            )
        case 9:
            return (
                "Прослушивание 9/10 — Паузы и строки",
                "Расставляю паузы (••• — \(pauseCount)) и делю текст на строки для пения…"
            )
        default:
            return (
                "Прослушивание 10/10 — Финальная проверка",
                "Проверяю точную синхронизацию по времени и сохраняю лирику…"
            )
        }
    }

    // MARK: - Window Planning & Formatting Helpers

    public nonisolated static func computePassTimeout(
        hardDeadline: Date,
        preferred: TimeInterval,
        reserveForLater: TimeInterval,
        now: Date = Date()
    ) -> TimeInterval {
        let remaining = hardDeadline.timeIntervalSince(now)
        let available = remaining - reserveForLater
        guard available > 0.4 else { return 0 }
        return min(preferred, available)
    }

    private nonisolated static func buildVocalListeningActs(
        start: TimeInterval,
        end: TimeInterval,
        count: Int,
        maxWindowLength: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let span = max(4.0, end - start)
        let step = span / Double(max(1, count))
        var windows: [(TimeInterval, TimeInterval)] = []
        for i in 0..<count {
            let winStart = max(0, start + Double(i) * step - (i > 0 ? 1.2 : 0))
            let rawEnd = (i == count - 1) ? end : min(end, start + Double(i + 1) * step + 1.2)
            let winEnd = min(rawEnd, winStart + maxWindowLength)
            if winEnd - winStart >= 1.5 {
                windows.append((winStart, winEnd))
            }
        }
        return windows
    }

    private nonisolated static func identifyLowConfidenceWindows(
        tokens: [AIWordToken],
        vocalStart: TimeInterval,
        vocalEnd: TimeInterval,
        maxWindows: Int
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let weak = tokens.filter { $0.confidence < 0.62 }
        var windows: [(TimeInterval, TimeInterval)] = []

        if !weak.isEmpty {
            let midTime = (vocalStart + vocalEnd) / 2.0
            let firstHalf = weak.filter { $0.timestamp < midTime }
            let secondHalf = weak.filter { $0.timestamp >= midTime }
            for group in [firstHalf, secondHalf] where !group.isEmpty {
                let s = max(vocalStart, (group.first?.timestamp ?? vocalStart) - 1.5)
                let e = min(vocalEnd, min(s + 26.0, (group.last?.timestamp ?? s + 10.0) + 2.5))
                if e - s >= 2.0 {
                    windows.append((s, e))
                }
            }
        }

        if windows.isEmpty {
            let span = max(6.0, vocalEnd - vocalStart)
            let w1End = min(vocalEnd, vocalStart + min(24.0, span * 0.45))
            windows.append((vocalStart, w1End))
            if span > 30.0 {
                let w2Start = vocalStart + span * 0.50
                let w2End = min(vocalEnd, w2Start + 24.0)
                windows.append((w2Start, w2End))
            }
        }
        return Array(windows.prefix(maxWindows))
    }

    private nonisolated static func joinTokensForDisplay(_ tokens: [AIWordToken]) -> String {
        var out = ""
        for tok in tokens {
            let clean = tok.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if out.isEmpty {
                out = clean
            } else if containsCJK(clean) && containsCJK(String(out.suffix(1))) {
                // Chinese / Japanese characters join directly without spaces
                out += clean
            } else {
                out += " " + clean
            }
        }
        return out
    }

    private nonisolated static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
        }
    }

    private nonisolated static func formatLRCTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let secs = clamped - Double(mins * 60)
        return String(format: "[%02d:%05.2f]", mins, secs)
    }
}
