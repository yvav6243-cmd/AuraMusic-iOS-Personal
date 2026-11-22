import Foundation
import NaturalLanguage
import SwiftData
import SwiftUI

// MARK: - Lyric Line & Payload Models

public struct SyncedLyricLine: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let index: Int
    public let timestamp: TimeInterval
    public let text: String
    public let isInstrumental: Bool
    public var translatedText: String?

    public init(
        id: UUID = UUID(),
        index: Int,
        timestamp: TimeInterval,
        text: String,
        isInstrumental: Bool? = nil,
        translatedText: String? = nil
    ) {
        self.id = id
        self.index = index
        self.timestamp = timestamp
        self.text = text
        self.isInstrumental = isInstrumental ?? (text == "•••")
        self.translatedText = translatedText
    }
}

public struct TrackLyricsDocument: Sendable {
    public let id: UUID
    public let trackTitle: String
    public let artistName: String
    public let isSynchronized: Bool
    public let detectedLanguageCode: String
    public let detectedLanguageDisplayName: String
    public let syncedLines: [SyncedLyricLine]
    public let plainLines: [String]
    public let hasTranslationAvailable: Bool

    public init(
        id: UUID = UUID(),
        trackTitle: String,
        artistName: String,
        isSynchronized: Bool,
        detectedLanguageCode: String,
        detectedLanguageDisplayName: String,
        syncedLines: [SyncedLyricLine],
        plainLines: [String],
        hasTranslationAvailable: Bool
    ) {
        self.id = id
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.isSynchronized = isSynchronized
        self.detectedLanguageCode = detectedLanguageCode
        self.detectedLanguageDisplayName = detectedLanguageDisplayName
        self.syncedLines = syncedLines
        self.plainLines = plainLines
        self.hasTranslationAvailable = hasTranslationAvailable
    }
}

// MARK: - Millisecond-Accurate LRC Parser & Normalization Engine

public enum LRCParser {
    private static let minimumPauseDuration: TimeInterval = 2.2
    private static let minimumIntroDotsDuration: TimeInterval = 3.0
    private static let collisionWindowSeconds: TimeInterval = 0.50
    private static let simultaneousLyricWindowSeconds: TimeInterval = 0.05

    private static let instrumentalTokens: Set<String> = [
        "", "•••", "...", "…", "♪", "♫", "♬", "🎵", "🎶",
        "instrumental", "(instrumental)", "[instrumental]",
        "---", "—", "–", "-", "•", "·"
    ]

    public static func isInstrumentalMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let normalized = trimmed.lowercased()
        if instrumentalTokens.contains(normalized) { return true }
        // Lines consisting purely of dots, music notes, dashes, or spaces
        let allowedInstrumentScalars = CharacterSet(charactersIn: "•·.…♪♫♬🎵🎶—–- \t")
        return trimmed.unicodeScalars.allSatisfy { allowedInstrumentScalars.contains($0) }
    }

    /// Parses standard and extended LRC timestamps: `[mm:ss.xx]`, `[mm:ss.xxx]`, or `[mm:ss]`.
    /// Also handles `[offset:±ms]`, inline Enhanced LRC tags `<mm:ss.xx>`, duplicate/colliding timestamps,
    /// consecutive/micro pause markers, trailing empty lines, and optional clean intro dots at `t = 0.0`.
    public static func parseSyncedLRC(_ rawLRC: String, includeIntroDots: Bool = false) -> [SyncedLyricLine] {
        let lines = rawLRC.components(separatedBy: .newlines)
        let timestampPattern = "\\[(\\d{1,3}):(\\d{2})(?:[\\.:](\\d{1,3}))?\\]"
        let offsetPattern = "\\[offset:\\s*([+-]?\\d+)\\s*\\]"
        let inlineWordTagPattern = "<\\d{1,3}:\\d{2}(?:[\\.:]\\d{1,3})?>"

        guard let tsRegex = try? NSRegularExpression(pattern: timestampPattern, options: []) else {
            return []
        }
        let offsetRegex = try? NSRegularExpression(pattern: offsetPattern, options: [.caseInsensitive])
        let inlineTagRegex = try? NSRegularExpression(pattern: inlineWordTagPattern, options: [])

        // 1. Extract optional [offset:±ms] header (positive offset shifts timestamps earlier per LRC spec)
        var offsetSeconds: TimeInterval = 0
        if let offsetRegex {
            for rawLine in lines {
                let nsRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
                if let match = offsetRegex.firstMatch(in: rawLine, options: [], range: nsRange),
                   let valRange = Range(match.range(at: 1), in: rawLine),
                   let ms = Double(rawLine[valRange]) {
                    offsetSeconds = ms / 1000.0
                    break
                }
            }
        }

        // 2. Parse every timestamped entry safely using UTF-16 -> Swift Range conversion
        struct RawEntry {
            let timestamp: TimeInterval
            let text: String
            let translation: String?
            let isInstrumental: Bool
            let originalOrder: Int
        }

        var rawEntries: [RawEntry] = []
        var orderCounter = 0

        for rawLine in lines {
            let nsRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = tsRegex.matches(in: rawLine, options: [], range: nsRange)
            guard !matches.isEmpty,
                  let lastMatch = matches.last,
                  let lastSwiftRange = Range(lastMatch.range, in: rawLine) else {
                continue
            }

            var lyricContent = String(rawLine[lastSwiftRange.upperBound...])
            if let inlineTagRegex {
                let cRange = NSRange(lyricContent.startIndex..<lyricContent.endIndex, in: lyricContent)
                lyricContent = inlineTagRegex.stringByReplacingMatches(in: lyricContent, range: cRange, withTemplate: "")
            }
            lyricContent = lyricContent.trimmingCharacters(in: .whitespacesAndNewlines)

            let parts = lyricContent.components(separatedBy: " // ")
            let original = (parts.first ?? lyricContent).trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let instrumental = isInstrumentalMarker(original)

            for match in matches {
                guard let minRange = Range(match.range(at: 1), in: rawLine),
                      let secRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minRange]),
                      let seconds = Double(rawLine[secRange]) else {
                    continue
                }
                var fraction: Double = 0
                if match.numberOfRanges > 3,
                   let fracRange = Range(match.range(at: 3), in: rawLine) {
                    let fracStr = String(rawLine[fracRange])
                    if let rawVal = Double(fracStr) {
                        if fracStr.count == 1 {
                            fraction = rawVal / 10.0
                        } else if fracStr.count == 2 {
                            fraction = rawVal / 100.0
                        } else {
                            fraction = rawVal / 1000.0
                        }
                    }
                }
                let adjustedTime = max(0, (minutes * 60.0) + seconds + fraction - offsetSeconds)
                rawEntries.append(
                    RawEntry(
                        timestamp: adjustedTime,
                        text: instrumental ? "•••" : original,
                        translation: instrumental ? nil : translation,
                        isInstrumental: instrumental,
                        originalOrder: orderCounter
                    )
                )
                orderCounter += 1
            }
        }

        guard !rawEntries.isEmpty else { return [] }

        // 3. Stable sort by timestamp; on equal timestamps, place instrumental markers before real lyrics so real lyrics always win
        let sorted = rawEntries.sorted { lhs, rhs in
            if abs(lhs.timestamp - rhs.timestamp) > 0.0001 {
                return lhs.timestamp < rhs.timestamp
            }
            if lhs.isInstrumental != rhs.isInstrumental {
                return lhs.isInstrumental && !rhs.isInstrumental
            }
            return lhs.originalOrder < rhs.originalOrder
        }

        // 4. Separate & clean:
        //    - Merge simultaneous real lyric lines (within 0.05s) so neither line is skipped/unlit
        //    - Drop any instrumental marker colliding within 0.50s of a real lyric line
        //    - Collapse consecutive instrumental markers into one (keeping the earliest timestamp)
        var cleaned: [RawEntry] = []

        for entry in sorted {
            if entry.isInstrumental {
                // Skip if a real lyric already sits right at this timestamp
                if let prev = cleaned.last, !prev.isInstrumental, abs(entry.timestamp - prev.timestamp) < collisionWindowSeconds {
                    continue
                }
                // Collapse consecutive instrumental markers
                if let prev = cleaned.last, prev.isInstrumental {
                    continue
                }
                cleaned.append(entry)
            } else {
                // If previous entry was an instrumental marker colliding right on/before this real lyric, drop the marker!
                if let prev = cleaned.last, prev.isInstrumental, abs(entry.timestamp - prev.timestamp) < collisionWindowSeconds {
                    cleaned.removeLast()
                }
                // Merge simultaneous real lyrics (e.g. overlapping lead + backing vocal at exact same timestamp)
                if let prev = cleaned.last, !prev.isInstrumental, abs(entry.timestamp - prev.timestamp) <= simultaneousLyricWindowSeconds {
                    if prev.text.caseInsensitiveCompare(entry.text) != .orderedSame {
                        let mergedText = "\(prev.text)\n\(entry.text)"
                        let mergedTranslation: String?
                        if let t1 = prev.translation, let t2 = entry.translation {
                            mergedTranslation = "\(t1)\n\(t2)"
                        } else {
                            mergedTranslation = prev.translation ?? entry.translation
                        }
                        cleaned[cleaned.count - 1] = RawEntry(
                            timestamp: prev.timestamp,
                            text: mergedText,
                            translation: mergedTranslation,
                            isInstrumental: false,
                            originalOrder: prev.originalOrder
                        )
                    }
                    continue
                }
                cleaned.append(entry)
            }
        }

        // 5. Drop trailing instrumental markers after the final sung lyric (common end-of-song clear tags in LRCLIB)
        while let last = cleaned.last, last.isInstrumental, cleaned.contains(where: { !$0.isInstrumental }) {
            cleaned.removeLast()
        }

        // 6. Drop short micro-pause instrumental markers (< 2.2s before the next real lyric line)
        var withoutMicroPauses: [RawEntry] = []
        for idx in cleaned.indices {
            let entry = cleaned[idx]
            if entry.isInstrumental {
                if idx + 1 < cleaned.count {
                    let gap = cleaned[idx + 1].timestamp - entry.timestamp
                    if gap < minimumPauseDuration {
                        continue
                    }
                }
            }
            withoutMicroPauses.append(entry)
        }

        // 7. Handle leading intro dots cleanly so SynchronizedLyricsView never inserts/removes views mid-scroll
        if includeIntroDots, let firstRealIdx = withoutMicroPauses.firstIndex(where: { !$0.isInstrumental }) {
            let firstRealTimestamp = withoutMicroPauses[firstRealIdx].timestamp
            // Remove any raw leading instrumental entries before the first real lyric
            if firstRealIdx > 0 {
                withoutMicroPauses.removeFirst(firstRealIdx)
            }
            // If the song has a meaningful instrumental intro (>= 3.0s), insert one clean intro "•••" row at t = 0.0
            if firstRealTimestamp >= minimumIntroDotsDuration {
                withoutMicroPauses.insert(
                    RawEntry(
                        timestamp: 0.0,
                        text: "•••",
                        translation: nil,
                        isInstrumental: true,
                        originalOrder: -1
                    ),
                    at: 0
                )
            }
        }

        // 8. Finalize strictly indexed lines with guaranteed strictly increasing timestamps
        var result: [SyncedLyricLine] = []
        result.reserveCapacity(withoutMicroPauses.count)
        for (idx, item) in withoutMicroPauses.enumerated() {
            var safeTimestamp = item.timestamp
            if let prev = result.last, safeTimestamp <= prev.timestamp {
                safeTimestamp = prev.timestamp + 0.01
            }
            result.append(
                SyncedLyricLine(
                    index: idx,
                    timestamp: safeTimestamp,
                    text: item.text,
                    isInstrumental: item.isInstrumental,
                    translatedText: item.translation
                )
            )
        }
        return result
    }

    public static func detectScriptLanguage(for text: String) -> (code: String, displayName: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let lang = recognizer.dominantLanguage {
            let code = lang.rawValue
            let name = Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
            return (code, name)
        }
        return ("und", "Original Script")
    }
}

// MARK: - Deterministic Lyric Synchronization State Machine

public struct LyricRowVisualState: Equatable, Sendable {
    public let isCurrent: Bool
    public let isPast: Bool
    public let litDotsCount: Int

    public init(isCurrent: Bool, isPast: Bool, litDotsCount: Int) {
        self.isCurrent = isCurrent
        self.isPast = isPast
        self.litDotsCount = litDotsCount
    }
}

public enum LyricSynchronizationEngine {
    /// Small visual anticipation lead so lyrics illuminate right as the vocalist begins each line
    public static let leadTimeSeconds: TimeInterval = 0.25

    /// Deterministically resolves the active line index for any playback time using binary search.
    /// Guarantees seamless transitions out of intro dots and mid-song pause dots ("•••") onto the exact next sung line.
    public static func activeLineIndex(at currentTime: TimeInterval, in lines: [SyncedLyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let clampedTime = max(0, currentTime)
        let effectiveTime = clampedTime + leadTimeSeconds

        if effectiveTime < lines[0].timestamp {
            // If the first sung line starts almost immediately (<= 1.0s), pre-light it so the start never appears unlit
            if !lines[0].isInstrumental && lines[0].timestamp <= 1.0 {
                return 0
            }
            return nil
        }

        var low = 0
        var high = lines.count - 1
        var matched = 0

        while low <= high {
            let mid = low + (high - low) / 2
            if lines[mid].timestamp <= effectiveTime {
                matched = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return matched
    }

    /// Computes how many progress dots (0...3) should be lit for an instrumental pause line.
    /// Uses the EXACT same `effectiveTime` (`currentTime + leadTimeSeconds`) as `activeLineIndex`,
    /// so all 3 dots finish illuminating smoothly right before the next sung line lights up.
    public static func litDotsCount(
        at currentTime: TimeInterval,
        forLineAt index: Int,
        in lines: [SyncedLyricLine],
        trackDuration: TimeInterval
    ) -> Int {
        guard index >= 0, index < lines.count, lines[index].isInstrumental else {
            return 0
        }
        let start = lines[index].timestamp
        let end: TimeInterval = (index + 1 < lines.count)
            ? lines[index + 1].timestamp
            : max(trackDuration, start + 6.0)
        let effectiveTime = max(0, currentTime) + leadTimeSeconds
        return AppleMusicInstrumentalDotsView.calculateLitDots(
            currentTime: effectiveTime,
            startTime: start,
            endTime: end
        )
    }

    /// Computes complete deterministic visual state (`isCurrent`, `isPast`, `litDotsCount`) for any row.
    public static func rowVisualState(
        forLineAt lineIndex: Int,
        activeIndex: Int?,
        currentTime: TimeInterval,
        in lines: [SyncedLyricLine],
        trackDuration: TimeInterval
    ) -> LyricRowVisualState {
        let isCurrent = (activeIndex == lineIndex)
        let isPast: Bool
        if let activeIndex {
            isPast = lineIndex < activeIndex
        } else {
            isPast = false
        }
        let dots = isCurrent
            ? litDotsCount(at: currentTime, forLineAt: lineIndex, in: lines, trackDuration: trackDuration)
            : 0
        return LyricRowVisualState(isCurrent: isCurrent, isPast: isPast, litDotsCount: dots)
    }
}

// MARK: - Official LRCLIB Lyrics Client + Multi-Stage Smart Resolver + SwiftData Cache

@MainActor
public final class LyricsService: ObservableObject {
    public static let shared = LyricsService()

    @Published public private(set) var currentDocument: TrackLyricsDocument?
    @Published public private(set) var aiDocument: TrackLyricsDocument?
    @Published public var lyricsMode: LyricsDisplayMode = .standard
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    public var activeDocument: TrackLyricsDocument? {
        lyricsMode == .aiAudio ? aiDocument : currentDocument
    }

    private let session: URLSession
    private var loadedTrackID: String?
    private var activeRequestID = UUID()

    private init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns the currently active synchronized lyric line for live preview on the Apple Music player card
    public func activeLyricLineText(at currentTime: TimeInterval) -> String? {
        guard let doc = activeDocument else { return nil }
        if doc.isSynchronized {
            if let activeIdx = LyricSynchronizationEngine.activeLineIndex(at: currentTime, in: doc.syncedLines) {
                if !doc.syncedLines[activeIdx].isInstrumental {
                    return doc.syncedLines[activeIdx].text
                }
                // During a pause, preview the most recent sung line or upcoming first sung line
                for idx in stride(from: activeIdx - 1, through: 0, by: -1) {
                    if !doc.syncedLines[idx].isInstrumental {
                        return doc.syncedLines[idx].text
                    }
                }
            }
            return doc.syncedLines.first(where: { !$0.isInstrumental })?.text
        } else {
            return doc.plainLines.first(where: { !$0.isEmpty })
        }
    }

    nonisolated public static func lyricsCacheKey(for track: UniversalTrack) -> String {
        let (parsedTitle, parsedArtist) = extractCleanTitleAndArtist(rawTitle: track.title, rawArtist: track.artist)
        return "\(parsedArtist.lowercased())::\(parsedTitle.lowercased())"
    }

    nonisolated public static func aiLyricsCacheKey(for track: UniversalTrack) -> String {
        "ai::\(lyricsCacheKey(for: track))"
    }

    public func setActiveAIDocument(_ document: TrackLyricsDocument?) {
        self.aiDocument = document
    }

    public func loadCachedAILyrics(for track: UniversalTrack) -> TrackLyricsDocument? {
        let key = Self.aiLyricsCacheKey(for: track)
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        guard let cached = try? context.fetch(descriptor).first,
              !(cached.syncedLRC ?? "").isEmpty else {
            return nil
        }
        return buildDocument(
            title: track.title,
            artist: track.artist,
            syncedLRC: cached.syncedLRC,
            plainLyrics: cached.plainLyrics,
            trackDuration: track.duration
        )
    }

    @discardableResult
    public func saveAILyrics(syncedLRC: String, for track: UniversalTrack) -> TrackLyricsDocument? {
        let key = Self.aiLyricsCacheKey(for: track)
        let parsed = LRCParser.parseSyncedLRC(syncedLRC, includeIntroDots: true)
        let plain = parsed.filter { !$0.isInstrumental }.map(\.text).joined(separator: "\n")
        cacheLyrics(
            cacheKey: key,
            title: track.title,
            artist: track.artist,
            syncedLRC: syncedLRC,
            plainLyrics: plain.isEmpty ? nil : plain
        )
        return buildDocument(
            title: track.title,
            artist: track.artist,
            syncedLRC: syncedLRC,
            plainLyrics: plain.isEmpty ? nil : plain,
            trackDuration: track.duration
        )
    }

    /// Provides optional reference lyric lines & vocabulary hints (cached or fast <=3.5s lookup) so AI speech recognition
    /// can bias Apple Speech `contextualStrings` and verify heard words against real audio timestamps without ever stalling.
    public func fetchReferenceLyricsForAI(
        for track: UniversalTrack,
        timeoutSeconds: TimeInterval = 3.5
    ) async -> (plainLines: [String], syncedLines: [SyncedLyricLine])? {
        // 1. Instant hit if already loaded for this track
        if loadedTrackID == track.id, let doc = currentDocument {
            let cleanPlain = doc.plainLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LRCParser.isInstrumentalMarker($0) }
            if !cleanPlain.isEmpty {
                return (cleanPlain, doc.isSynchronized ? doc.syncedLines : [])
            }
        }
        // 2. Instant SwiftData offline cache hit
        let cacheKey = Self.lyricsCacheKey(for: track)
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let cached = try? context.fetch(descriptor).first,
           let doc = buildDocument(
               title: track.title,
               artist: track.artist,
               syncedLRC: cached.syncedLRC,
               plainLyrics: cached.plainLyrics,
               trackDuration: track.duration
           ) {
            let cleanPlain = doc.plainLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LRCParser.isInstrumentalMarker($0) }
            if !cleanPlain.isEmpty {
                return (cleanPlain, doc.isSynchronized ? doc.syncedLines : [])
            }
        }
        // 3. Fast time-capped remote lookup across our 6 databases
        let candidate: LRCLIBEntryDTO? = await withTaskGroup(of: LRCLIBEntryDTO?.self) { group in
            group.addTask { @MainActor in
                await self.fetchBestRemoteLyricsCandidate(for: track)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, timeoutSeconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let dto = candidate,
              let doc = buildDocument(
                  title: track.title,
                  artist: track.artist,
                  syncedLRC: dto.syncedLyrics,
                  plainLyrics: dto.plainLyrics,
                  trackDuration: track.duration
              ) else {
            return nil
        }
        let cleanPlain = doc.plainLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LRCParser.isInstrumentalMarker($0) }
        guard !cleanPlain.isEmpty else { return nil }
        return (cleanPlain, doc.isSynchronized ? doc.syncedLines : [])
    }

    public func hasCachedLyrics(for track: UniversalTrack) -> Bool {
        let key = Self.lyricsCacheKey(for: track)
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        guard let cached = try? context.fetch(descriptor).first else { return false }
        return !(cached.syncedLRC ?? "").isEmpty || !(cached.plainLyrics ?? "").isEmpty
    }

    /// Downloads & persists synchronized lyrics alongside offline audio tracks / playlists WITHOUT disturbing the currently playing lyrics view!
    @discardableResult
    public func prefetchAndCacheLyrics(for track: UniversalTrack) async -> Bool {
        let cacheKey = Self.lyricsCacheKey(for: track)
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let existing = try? context.fetch(descriptor).first,
           !(existing.syncedLRC ?? "").isEmpty {
            return true
        }

        if let bestDTO = await fetchBestRemoteLyricsCandidate(for: track) {
            cacheLyrics(
                cacheKey: cacheKey,
                title: track.title,
                artist: track.artist,
                syncedLRC: bestDTO.syncedLyrics,
                plainLyrics: bestDTO.plainLyrics
            )
            // If this track is currently active on screen and had no lyrics yet, display them immediately
            if loadedTrackID == track.id && currentDocument == nil {
                self.currentDocument = buildDocument(
                    title: track.title,
                    artist: track.artist,
                    syncedLRC: bestDTO.syncedLyrics,
                    plainLyrics: bestDTO.plainLyrics,
                    trackDuration: track.duration
                )
                self.errorMessage = nil
            }
            return true
        }
        return hasCachedLyrics(for: track)
    }

    public func loadLyrics(for track: UniversalTrack, forceReload: Bool = false) async {
        // Refresh cached AI document when switching tracks so AI mode stays scoped to the current song
        if loadedTrackID != track.id {
            AILyricsTranscriptionEngine.shared.resetForNewTrack(track.id)
            self.aiDocument = loadCachedAILyrics(for: track)
        }

        // Avoid wiping and reloading already-loaded lyrics when re-opening the Lyrics panel for the same track
        if !forceReload, loadedTrackID == track.id, currentDocument != nil {
            isLoading = false
            return
        }

        let requestID = UUID()
        activeRequestID = requestID

        let (parsedTitle, _) = Self.extractCleanTitleAndArtist(rawTitle: track.title, rawArtist: track.artist)
        let cacheKey = Self.lyricsCacheKey(for: track)

        isLoading = true
        errorMessage = nil

        // 1. Check SwiftData local offline lyrics cache first
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        let cachedEntity = try? context.fetch(descriptor).first
        if let cached = cachedEntity,
           !(cached.syncedLRC ?? "").isEmpty {
            guard activeRequestID == requestID else { return }
            self.currentDocument = buildDocument(
                title: track.title,
                artist: track.artist,
                syncedLRC: cached.syncedLRC,
                plainLyrics: cached.plainLyrics,
                trackDuration: track.duration
            )
            self.loadedTrackID = track.id
            self.isLoading = false
            return
        }

        // 2. Parallel 6-provider remote lookup
        if let bestDTO = await fetchBestRemoteLyricsCandidate(for: track) {
            guard activeRequestID == requestID else { return }
            cacheLyrics(
                cacheKey: cacheKey,
                title: track.title,
                artist: track.artist,
                syncedLRC: bestDTO.syncedLyrics,
                plainLyrics: bestDTO.plainLyrics
            )
            self.currentDocument = buildDocument(
                title: track.title,
                artist: track.artist,
                syncedLRC: bestDTO.syncedLyrics,
                plainLyrics: bestDTO.plainLyrics,
                trackDuration: track.duration
            )
            self.loadedTrackID = track.id
            self.isLoading = false
            return
        }

        // 3. Offline Airplane Mode fallback: if plain lyrics were cached locally with the downloaded song, display them cleanly!
        if let cached = cachedEntity, !(cached.plainLyrics ?? "").isEmpty {
            guard activeRequestID == requestID else { return }
            self.currentDocument = buildDocument(
                title: track.title,
                artist: track.artist,
                syncedLRC: nil,
                plainLyrics: cached.plainLyrics,
                trackDuration: track.duration
            )
            self.loadedTrackID = track.id
            self.isLoading = false
            return
        }

        guard activeRequestID == requestID else { return }
        self.currentDocument = nil
        self.loadedTrackID = track.id
        self.errorMessage = "No licensed lyrics found for \"\(parsedTitle)\". Tap the magnifying glass to search manually."
        self.isLoading = false
    }

    private func fetchBestRemoteLyricsCandidate(for track: UniversalTrack) async -> LRCLIBEntryDTO? {
        let (parsedTitle, parsedArtist) = Self.extractCleanTitleAndArtist(rawTitle: track.title, rawArtist: track.artist)
        let referenceScriptText = "\(track.title) \(track.artist) \(parsedTitle) \(parsedArtist)"
        let youtubeVideoID: String? = (track.provider == .youtubeMusic || track.provider == .youtube)
            ? track.providerTrackID
            : nil

        var allCandidates: [LRCLIBEntryDTO] = []

        // Wave 1: Fire YouTube Music (exact videoId), LRCLIB, QQ Music, and NetEase Cloud Music in parallel!
        let primaryQuery = "\(parsedTitle) \(parsedArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let wave1Results: [LRCLIBEntryDTO] = await withTaskGroup(of: [LRCLIBEntryDTO].self) { group in
            if let vid = youtubeVideoID, !vid.isEmpty {
                group.addTask {
                    if let ytDTO = await self.fetchYouTubeMusicOfficialLyrics(
                        videoID: vid,
                        fallbackTitle: parsedTitle,
                        fallbackArtist: parsedArtist,
                        duration: track.duration
                    ) {
                        return [ytDTO]
                    }
                    return []
                }
            }

            group.addTask {
                var list: [LRCLIBEntryDTO] = []
                if let exact = try? await self.fetchExactLRCLIB(title: parsedTitle, artist: parsedArtist, album: track.album, duration: track.duration) {
                    list.append(exact)
                }
                if let search1 = try? await self.searchLRCLIB(title: parsedTitle, artist: parsedArtist) {
                    list.append(contentsOf: search1)
                }
                if let search2 = try? await self.searchLRCLIB(title: parsedTitle, artist: "") {
                    list.append(contentsOf: search2)
                }
                return list
            }

            group.addTask {
                var qqList = await self.fetchQQMusicLyrics(query: primaryQuery, targetDuration: track.duration)
                if qqList.isEmpty && !parsedTitle.isEmpty && primaryQuery != parsedTitle {
                    qqList = await self.fetchQQMusicLyrics(query: parsedTitle, targetDuration: track.duration)
                }
                return qqList
            }

            group.addTask {
                var neList = await self.fetchNetEaseLyrics(query: primaryQuery, targetDuration: track.duration)
                if neList.isEmpty && !parsedTitle.isEmpty && primaryQuery != parsedTitle {
                    neList = await self.fetchNetEaseLyrics(query: parsedTitle, targetDuration: track.duration)
                }
                return neList
            }

            var merged: [LRCLIBEntryDTO] = []
            for await batch in group {
                merged.append(contentsOf: batch)
            }
            return merged
        }
        allCandidates.append(contentsOf: wave1Results)

        let hasGoodSyncedAlready = Self.selectBestOriginalLanguageCandidate(
            from: allCandidates,
            referenceText: referenceScriptText,
            targetTitle: parsedTitle,
            targetArtist: parsedArtist,
            targetDuration: track.duration
        ).map { !($0.syncedLyrics ?? "").isEmpty } ?? false

        // Wave 2: Smart fallbacks (Kugou Music + localized iTunes CN/RU/US canonical lookup + reversed "Song - Artist" + Lyrics.ovh)
        if !hasGoodSyncedAlready {
            let wave2Results: [LRCLIBEntryDTO] = await withTaskGroup(of: [LRCLIBEntryDTO].self) { group in
                group.addTask {
                    await self.fetchKugouLyrics(query: primaryQuery, targetDuration: track.duration)
                }

                if parsedTitle != parsedArtist, !parsedArtist.isEmpty {
                    group.addTask {
                        var rev: [LRCLIBEntryDTO] = []
                        if let reversedSearch = try? await self.searchLRCLIB(title: parsedArtist, artist: parsedTitle) {
                            rev.append(contentsOf: reversedSearch)
                        }
                        let reversedQuery = "\(parsedArtist) \(parsedTitle)"
                        rev.append(contentsOf: await self.fetchQQMusicLyrics(query: reversedQuery, targetDuration: track.duration))
                        return rev
                    }
                }

                group.addTask {
                    var canonicalHits: [LRCLIBEntryDTO] = []
                    let countryCode: String
                    if Self.containsScript(referenceScriptText, pattern: "\\p{Han}") && !Self.containsScript(referenceScriptText, pattern: "[\\p{Hiragana}\\p{Katakana}]") {
                        countryCode = "cn"
                    } else if Self.containsScript(referenceScriptText, pattern: "\\p{Cyrillic}") {
                        countryCode = "ru"
                    } else {
                        countryCode = "us"
                    }
                    if let canonical = await self.resolveCanonicalMetadataFromCatalog(query: primaryQuery, country: countryCode) {
                        let canonicalQuery = "\(canonical.title) \(canonical.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
                        if let s3 = try? await self.searchLRCLIB(title: canonical.title, artist: canonical.artist) {
                            canonicalHits.append(contentsOf: s3)
                        }
                        canonicalHits.append(contentsOf: await self.fetchQQMusicLyrics(query: canonicalQuery, targetDuration: track.duration))
                        canonicalHits.append(contentsOf: await self.fetchNetEaseLyrics(query: canonicalQuery, targetDuration: track.duration))
                    }
                    return canonicalHits
                }

                var merged: [LRCLIBEntryDTO] = []
                for await batch in group {
                    merged.append(contentsOf: batch)
                }
                return merged
            }
            allCandidates.append(contentsOf: wave2Results)
        }

        // Stage 3: Backup public Lyrics.ovh lookup if all 5 synced catalogs returned nothing
        if allCandidates.isEmpty {
            if let ovhPlain = await fetchBackupLyricsOvh(artist: parsedArtist, title: parsedTitle) {
                allCandidates.append(
                    LRCLIBEntryDTO(
                        id: 999999,
                        trackName: parsedTitle,
                        artistName: parsedArtist,
                        albumName: track.album,
                        duration: track.duration,
                        instrumental: false,
                        plainLyrics: ovhPlain,
                        syncedLyrics: nil
                    )
                )
            }
        }

        return Self.selectBestOriginalLanguageCandidate(
            from: allCandidates,
            referenceText: referenceScriptText,
            targetTitle: parsedTitle,
            targetArtist: parsedArtist,
            targetDuration: track.duration
        )
    }

    /// Splits composite titles like "Miyagi & Эндшпиль feat. Рем Дигга - I Got Love (Official Video)" into ("I Got Love", "Miyagi & Эндшпиль")
    nonisolated public static func extractCleanTitleAndArtist(rawTitle: String, rawArtist: String) -> (title: String, artist: String) {
        var workingTitle = rawTitle
        var workingArtist = rawArtist
            .replacingOccurrences(of: " - Topic", with: "")
            .replacingOccurrences(of: "VEVO", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Handle Chinese guillemets 《...》 and Japanese corner brackets 「...」 / 『...』
        //    e.g. 周杰伦《晴天》官方MV, 鄧紫棋《光年之外》【動態歌詞】, YOASOBI「アイドル」Official Music Video
        let quotePairs: [(Character, Character)] = [("《", "》"), ("「", "」"), ("『", "』")]
        for (openChar, closeChar) in quotePairs {
            if let openBracket = workingTitle.firstIndex(of: openChar),
               let closeBracket = workingTitle.firstIndex(of: closeChar),
               openBracket < closeBracket {
                let prefixArtist = String(workingTitle[..<openBracket])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:：")))
                let insideTitle = String(workingTitle[workingTitle.index(after: openBracket)..<closeBracket])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !insideTitle.isEmpty {
                    workingTitle = insideTitle
                    if !prefixArtist.isEmpty {
                        workingArtist = prefixArtist
                    }
                    break
                }
            }
        }

        // 2. Strip hashtags, pipes, and parenthetical/bracketed video/audio/remix/slowed noise in Chinese, Russian, and English FIRST
        let noiseWords = "official|audio|video|lyric|remaster|visualizer|live|hd|4k|mv|slowed|reverb|speed|sped|nightcore|remix|tiktok|bass|ost|prod|клип|видео|аудио|премьера|официальн|текст|музыка|сниппет|полная версия|лирик|минус|лайв|живой|官方|動態歌詞|动态歌词|完整版|高清|纯享|純享|现场|現場|翻唱|歌词|歌詞|高音質|高音质|无损|無損|伴奏|纯音乐|抖音|热歌|動態"
        let bracketPatterns = [
            "#\\S+",
            "\\|.*$",
            "\\([^)]*(?:\(noiseWords))[^)]*\\)",
            "\\[[^\\]]*(?:\(noiseWords))[^\\]]*\\]",
            "【[^】]*(?:\(noiseWords))[^】]*】",
            "（[^）]*(?:\(noiseWords))[^）]*）"
        ]
        for pattern in bracketPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(workingTitle.startIndex..<workingTitle.endIndex, in: workingTitle)
                workingTitle = regex.stringByReplacingMatches(in: workingTitle, range: range, withTemplate: "")
            }
        }

        // 3. Split "Artist - Song" BEFORE stripping feat./ft. so "Artist feat. Guest - Song" keeps "Song"!
        let separators = [" - ", " – ", " — ", " ~ "]
        for sep in separators {
            if workingTitle.contains(sep) {
                let parts = workingTitle.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    workingArtist = parts[0]
                    workingTitle = parts[1]
                    break
                }
            }
        }

        // 4. Now strip trailing feat./ft./prod./slowed/reverb from both title and artist
        let featPatterns = [
            "\\([^)]*(?:feat\\.?|ft\\.?|prod\\.?)[^)]*\\)",
            "\\[[^\\]]*(?:feat\\.?|ft\\.?|prod\\.?)[^\\]]*\\]",
            "(?i)\\b(?:feat\\.?|ft\\.?|prod\\.?)\\s+.+$",
            "(?i)\\b(?:official\\s+music\\s+video|official\\s+video|official\\s+audio|lyric\\s+video|slowed\\s*\\+?\\s*reverb|slowed|speed\\s+up|sped\\s+up|премьера\\s+клипа|официальный\\s+клип).*$"
        ]
        for pattern in featPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let titleRange = NSRange(workingTitle.startIndex..<workingTitle.endIndex, in: workingTitle)
                workingTitle = regex.stringByReplacingMatches(in: workingTitle, range: titleRange, withTemplate: "")
                let artistRange = NSRange(workingArtist.startIndex..<workingArtist.endIndex, in: workingArtist)
                workingArtist = regex.stringByReplacingMatches(in: workingArtist, range: artistRange, withTemplate: "")
            }
        }

        if let artistComma = workingArtist.components(separatedBy: ",").first {
            workingArtist = artistComma.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let artistAmp = workingArtist.components(separatedBy: "&").first {
            let trimmedAmp = artistAmp.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAmp.isEmpty {
                workingArtist = trimmedAmp
            }
        }

        let finalTitle = workingTitle
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalArtist = workingArtist
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (finalTitle.isEmpty ? rawTitle : finalTitle, finalArtist.isEmpty ? rawArtist : finalArtist)
    }

    /// Selects the best lyric entry while strictly preserving the song's original language (including Chinese, Russian, Japanese, Korean)
    /// and prioritizing synchronized LRC + exact title/artist/duration matches.
    nonisolated public static func selectBestOriginalLanguageCandidate(
        from candidates: [LRCLIBEntryDTO],
        referenceText: String,
        targetTitle: String = "",
        targetArtist: String = "",
        targetDuration: TimeInterval
    ) -> LRCLIBEntryDTO? {
        let valid = candidates.filter { item in
            let sample = (item.syncedLyrics ?? item.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty else { return false }
            // Filter out QQ/NetEase "pure instrumental, please enjoy" placeholders when real lyrics may exist
            if sample.count < 80 && (sample.contains("纯音乐，请欣赏") || sample.contains("此歌曲为没有填词的纯音乐")) {
                return false
            }
            return true
        }
        guard !valid.isEmpty else { return nil }

        let expectsCyrillic = containsScript(referenceText, pattern: "\\p{Cyrillic}")
        let expectsJapanese = containsScript(referenceText, pattern: "[\\p{Hiragana}\\p{Katakana}]")
        let expectsKorean = containsScript(referenceText, pattern: "\\p{Hangul}")
        let expectsChinese = !expectsJapanese && containsScript(referenceText, pattern: "\\p{Han}")

        let normTargetTitle = targetTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normTargetArtist = targetArtist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let scored = valid.map { item -> (dto: LRCLIBEntryDTO, score: Int) in
            let textSample = (item.syncedLyrics ?? item.plainLyrics ?? "")
            let metaSample = "\(item.trackName) \(item.albumName ?? "")"
            var score = 0

            // Strongly prefer time-synchronized LRC lyrics
            if !(item.syncedLyrics ?? "").isEmpty {
                score += 120
                // Exact YouTube Music videoId timed lyrics match bonus
                if item.albumName == "YouTube Music Synced" {
                    score += 55
                }
            }

            // Penalize any entry marked as a translation or romanization
            if metaSample.range(of: "translation|translated|romanized|romaji|pinyin|перевод|english ver", options: [.regularExpression, .caseInsensitive]) != nil {
                score -= 250
            }

            // Enforce original script preservation (Russian/Cyrillic, Chinese/Han, Japanese, Korean)
            let hasCyrillic = containsScript(textSample, pattern: "\\p{Cyrillic}")
            let hasJapanese = containsScript(textSample, pattern: "[\\p{Hiragana}\\p{Katakana}]")
            let hasKorean = containsScript(textSample, pattern: "\\p{Hangul}")
            let hasHan = containsScript(textSample, pattern: "\\p{Han}")

            if expectsCyrillic {
                score += hasCyrillic ? 160 : -130
            } else if expectsJapanese {
                score += hasJapanese ? 160 : -150
            } else if expectsKorean {
                score += hasKorean ? 160 : -150
            } else if expectsChinese {
                score += hasHan ? 160 : -140
            }

            // Title & artist relevance scoring so title-only fallbacks don't match wrong songs
            let itemTitle = item.trackName.lowercased()
            let itemArtist = item.artistName.lowercased()
            if !normTargetTitle.isEmpty {
                if itemTitle == normTargetTitle {
                    score += 45
                } else if itemTitle.contains(normTargetTitle) || normTargetTitle.contains(itemTitle) {
                    score += 25
                } else {
                    score -= 35
                }
            }
            if !normTargetArtist.isEmpty && !normTargetArtist.contains("youtube") && !normTargetArtist.contains("music") {
                if itemArtist == normTargetArtist || itemArtist.contains(normTargetArtist) || normTargetArtist.contains(itemArtist) {
                    score += 35
                }
            }

            // Duration proximity bonus
            if targetDuration > 20, let itemDur = item.duration, itemDur > 20 {
                let delta = abs(targetDuration - itemDur)
                if delta <= 3 {
                    score += 40
                } else if delta <= 10 {
                    score += 20
                } else if delta > 45 {
                    score -= 30
                }
            }

            return (item, score)
        }

        return scored.max(by: { $0.score < $1.score })?.dto
    }

    nonisolated private static func containsScript(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    nonisolated public static func decodeLyricsHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#58;", with: ":")
            .replacingOccurrences(of: "&#32;", with: " ")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "")
    }

    // MARK: - Provider 1: YouTube Music Official InnerTube Timed Lyrics (Exact videoId -> Russian, Chinese, Global!)

    nonisolated public static func parseYouTubeMusicTimedLyricsJSON(
        _ data: Data,
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> LRCLIBEntryDTO? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // 1. Search recursively for `timedLyricsData` array (ANDROID_MUSIC timed/plain lyrics)
        if let timedEntries = findNestedArray(named: "timedLyricsData", in: root), !timedEntries.isEmpty {
            var syncedLines: [String] = []
            var plainLines: [String] = []
            var hasTimestamps = false

            for item in timedEntries {
                guard let dict = item as? [String: Any],
                      let rawLine = dict["lyricLine"] as? String else { continue }
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    plainLines.append(line)
                }
                if let cue = dict["cueRange"] as? [String: Any],
                   let startStr = cue["startTimeMilliseconds"] as? String,
                   let startMs = Double(startStr) {
                    hasTimestamps = true
                    let totalSec = max(0, startMs / 1000.0)
                    let mins = Int(totalSec) / 60
                    let secs = totalSec - Double(mins * 60)
                    let ts = String(format: "[%02d:%06.3f]", mins, secs)
                    syncedLines.append("\(ts)\(line)")
                }
            }

            if hasTimestamps && syncedLines.count >= 3 {
                return LRCLIBEntryDTO(
                    id: abs("\(title)\(artist)yt".hashValue) % 800_000 + 200_000,
                    trackName: title,
                    artistName: artist,
                    albumName: "YouTube Music Synced",
                    duration: duration,
                    instrumental: false,
                    plainLyrics: plainLines.joined(separator: "\n"),
                    syncedLyrics: syncedLines.joined(separator: "\n")
                )
            } else if plainLines.count >= 3 {
                return LRCLIBEntryDTO(
                    id: abs("\(title)\(artist)ytp".hashValue) % 800_000 + 200_000,
                    trackName: title,
                    artistName: artist,
                    albumName: "YouTube Music",
                    duration: duration,
                    instrumental: false,
                    plainLyrics: plainLines.joined(separator: "\n"),
                    syncedLyrics: nil
                )
            }
        }

        // 2. Fallback: WEB_REMIX `musicDescriptionShelfRenderer.description.runs`
        if let shelf = findNestedDict(named: "musicDescriptionShelfRenderer", in: root),
           let desc = shelf["description"] as? [String: Any],
           let runs = desc["runs"] as? [[String: Any]] {
            let plain = runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.count >= 20 {
                return LRCLIBEntryDTO(
                    id: abs("\(title)\(artist)ytw".hashValue) % 800_000 + 200_000,
                    trackName: title,
                    artistName: artist,
                    albumName: "YouTube Music",
                    duration: duration,
                    instrumental: false,
                    plainLyrics: plain,
                    syncedLyrics: nil
                )
            }
        }
        return nil
    }

    nonisolated private static func findNestedArray(named key: String, in node: Any) -> [Any]? {
        if let dict = node as? [String: Any] {
            if let arr = dict[key] as? [Any] { return arr }
            for value in dict.values {
                if let found = findNestedArray(named: key, in: value) { return found }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let found = findNestedArray(named: key, in: item) { return found }
            }
        }
        return nil
    }

    nonisolated private static func findNestedDict(named key: String, in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let target = dict[key] as? [String: Any] { return target }
            for value in dict.values {
                if let found = findNestedDict(named: key, in: value) { return found }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let found = findNestedDict(named: key, in: item) { return found }
            }
        }
        return nil
    }

    private func fetchYouTubeMusicOfficialLyrics(
        videoID: String,
        fallbackTitle: String,
        fallbackArtist: String,
        duration: TimeInterval
    ) async -> LRCLIBEntryDTO? {
        guard let nextURL = URL(string: "https://music.youtube.com/youtubei/v1/next?prettyPrint=false"),
              let browseURL = URL(string: "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false") else {
            return nil
        }

        let contextObj: [String: Any] = [
            "client": [
                "clientName": "ANDROID_MUSIC",
                "clientVersion": "7.11.50",
                "androidSdkVersion": 34,
                "hl": "ru",
                "gl": "RU"
            ]
        ]

        var nextReq = URLRequest(url: nextURL)
        nextReq.httpMethod = "POST"
        nextReq.timeoutInterval = 6
        nextReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        nextReq.setValue("com.google.android.apps.youtube.music/7.11.50 (Linux; U; Android 14)", forHTTPHeaderField: "User-Agent")
        nextReq.httpBody = try? JSONSerialization.data(withJSONObject: ["context": contextObj, "videoId": videoID])

        guard let (nextData, nextResp) = try? await session.data(for: nextReq),
              let httpNext = nextResp as? HTTPURLResponse, (200..<300).contains(httpNext.statusCode),
              let nextStr = String(data: nextData, encoding: .utf8),
              let browseRegex = try? NSRegularExpression(pattern: "\"browseId\"\\s*:\\s*\"(MPLYt_[^\"]+)\""),
              let match = browseRegex.firstMatch(in: nextStr, range: NSRange(nextStr.startIndex..<nextStr.endIndex, in: nextStr)),
              let idRange = Range(match.range(at: 1), in: nextStr) else {
            return nil
        }

        let browseID = String(nextStr[idRange])
        var browseReq = URLRequest(url: browseURL)
        browseReq.httpMethod = "POST"
        browseReq.timeoutInterval = 6
        browseReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        browseReq.setValue("com.google.android.apps.youtube.music/7.11.50 (Linux; U; Android 14)", forHTTPHeaderField: "User-Agent")
        browseReq.httpBody = try? JSONSerialization.data(withJSONObject: ["context": contextObj, "browseId": browseID])

        guard let (browseData, browseResp) = try? await session.data(for: browseReq),
              let httpBrowse = browseResp as? HTTPURLResponse, (200..<300).contains(httpBrowse.statusCode) else {
            return nil
        }
        return Self.parseYouTubeMusicTimedLyricsJSON(
            browseData,
            title: fallbackTitle,
            artist: fallbackArtist,
            duration: duration
        )
    }

    // MARK: - Provider 2: QQ Music Synced LRC (Massive Chinese Mandopop/Cantopop + Russian Catalog!)

    private func fetchQQMusicLyrics(query: String, targetDuration: TimeInterval) async -> [LRCLIBEntryDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var searchComp = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp") else {
            return []
        }
        searchComp.queryItems = [
            URLQueryItem(name: "w", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "n", value: "3")
        ]
        guard let searchURL = searchComp.url else { return [] }
        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 6
        searchReq.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        searchReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        guard let (sData, sResp) = try? await session.data(for: searchReq),
              let sHttp = sResp as? HTTPURLResponse, (200..<300).contains(sHttp.statusCode),
              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let dataDict = sJson["data"] as? [String: Any],
              let songDict = dataDict["song"] as? [String: Any],
              let list = songDict["list"] as? [[String: Any]], !list.isEmpty else {
            return []
        }

        var results: [LRCLIBEntryDTO] = []
        for song in list.prefix(3) {
            guard let mid = song["songmid"] as? String, !mid.isEmpty else { continue }
            let songName = Self.decodeLyricsHTMLEntities((song["songname"] as? String) ?? trimmed)
            let singers = (song["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
            let albumName = Self.decodeLyricsHTMLEntities((song["albumname"] as? String) ?? "QQ Music")
            let interval = (song["interval"] as? Double) ?? Double((song["interval"] as? Int) ?? 0)

            var lrcComp = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
            lrcComp.queryItems = [
                URLQueryItem(name: "songmid", value: mid),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "nobase64", value: "1")
            ]
            guard let lrcURL = lrcComp.url else { continue }
            var lrcReq = URLRequest(url: lrcURL)
            lrcReq.timeoutInterval = 5
            lrcReq.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            lrcReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            guard let (lData, lResp) = try? await session.data(for: lrcReq),
                  let lHttp = lResp as? HTTPURLResponse, (200..<300).contains(lHttp.statusCode),
                  let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
                  let rawLyric = lJson["lyric"] as? String, !rawLyric.isEmpty else {
                continue
            }
            let decodedLRC = Self.decodeLyricsHTMLEntities(rawLyric)
            let isSynced = decodedLRC.range(of: "\\[\\d{1,3}:\\d{2}", options: .regularExpression) != nil
            results.append(
                LRCLIBEntryDTO(
                    id: abs("qq_\(mid)".hashValue) % 800_000 + 1_100_000,
                    trackName: songName,
                    artistName: singers,
                    albumName: albumName.isEmpty ? "QQ Music" : albumName,
                    duration: interval > 10 ? interval : targetDuration,
                    instrumental: false,
                    plainLyrics: isSynced ? nil : decodedLRC,
                    syncedLyrics: isSynced ? decodedLRC : nil
                )
            )
        }
        return results
    }

    // MARK: - Provider 3: NetEase Cloud Music Synced LRC (Huge Chinese, Douyin, J-Pop, K-Pop & Russian Catalog!)

    private func fetchNetEaseLyrics(query: String, targetDuration: TimeInterval) async -> [LRCLIBEntryDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let searchURL = URL(string: "https://music.163.com/api/cloudsearch/pc") else {
            return []
        }

        var searchReq = URLRequest(url: searchURL)
        searchReq.httpMethod = "POST"
        searchReq.timeoutInterval = 6
        searchReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        searchReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        searchReq.setValue("appver=2.0.2;", forHTTPHeaderField: "Cookie")
        searchReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        let formAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? trimmed
        searchReq.httpBody = "s=\(encoded)&type=1&limit=3&offset=0".data(using: .utf8)

        guard let (sData, sResp) = try? await session.data(for: searchReq),
              let sHttp = sResp as? HTTPURLResponse, (200..<300).contains(sHttp.statusCode),
              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let resultDict = sJson["result"] as? [String: Any],
              let songs = resultDict["songs"] as? [[String: Any]], !songs.isEmpty else {
            return []
        }

        var results: [LRCLIBEntryDTO] = []
        for song in songs.prefix(3) {
            guard let songID = song["id"] as? Int else { continue }
            let songName = (song["name"] as? String) ?? trimmed
            let artists = (song["ar"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
            let albumName = ((song["al"] as? [String: Any])?["name"] as? String) ?? "NetEase Music"
            let dtMs = (song["dt"] as? Double) ?? Double((song["dt"] as? Int) ?? 0)
            let songDur = dtMs > 10_000 ? (dtMs / 1000.0) : targetDuration

            guard let lrcURL = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1&kv=1&tv=-1") else {
                continue
            }
            var lrcReq = URLRequest(url: lrcURL)
            lrcReq.timeoutInterval = 5
            lrcReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            lrcReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            guard let (lData, lResp) = try? await session.data(for: lrcReq),
                  let lHttp = lResp as? HTTPURLResponse, (200..<300).contains(lHttp.statusCode),
                  let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
                  let lrcDict = lJson["lrc"] as? [String: Any],
                  let rawLyric = lrcDict["lyric"] as? String,
                  !rawLyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let isSynced = rawLyric.range(of: "\\[\\d{1,3}:\\d{2}", options: .regularExpression) != nil
            results.append(
                LRCLIBEntryDTO(
                    id: abs("ne_\(songID)".hashValue) % 800_000 + 2_100_000,
                    trackName: songName,
                    artistName: artists,
                    albumName: albumName,
                    duration: songDur,
                    instrumental: false,
                    plainLyrics: isSynced ? nil : rawLyric,
                    syncedLyrics: isSynced ? rawLyric : nil
                )
            )
        }
        return results
    }

    // MARK: - Provider 4: Kugou Music Synced LRC (Douyin / Viral Chinese & Indie Backup)

    private func fetchKugouLyrics(query: String, targetDuration: TimeInterval) async -> [LRCLIBEntryDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var searchComp = URLComponents(string: "https://lyrics.kugou.com/search") else {
            return []
        }
        searchComp.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: trimmed)
        ]
        guard let searchURL = searchComp.url else { return [] }
        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 5
        searchReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        guard let (sData, sResp) = try? await session.data(for: searchReq),
              let sHttp = sResp as? HTTPURLResponse, (200..<300).contains(sHttp.statusCode),
              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let candidates = sJson["candidates"] as? [[String: Any]],
              let best = candidates.first,
              let cid = best["id"] as? String,
              let accessKey = best["accesskey"] as? String else {
            return []
        }

        var dlComp = URLComponents(string: "https://lyrics.kugou.com/download")!
        dlComp.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: cid),
            URLQueryItem(name: "accesskey", value: accessKey),
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8")
        ]
        guard let dlURL = dlComp.url else { return [] }
        var dlReq = URLRequest(url: dlURL)
        dlReq.timeoutInterval = 5

        guard let (lData, lResp) = try? await session.data(for: dlReq),
              let lHttp = lResp as? HTTPURLResponse, (200..<300).contains(lHttp.statusCode),
              let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
              let base64 = lJson["content"] as? String,
              let decodedData = Data(base64Encoded: base64),
              let lrcText = String(data: decodedData, encoding: .utf8),
              !lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let songName = (best["song"] as? String) ?? trimmed
        let singer = (best["singer"] as? String) ?? ""
        let durMs = (best["duration"] as? Double) ?? Double((best["duration"] as? Int) ?? 0)
        let isSynced = lrcText.range(of: "\\[\\d{1,3}:\\d{2}", options: .regularExpression) != nil

        return [
            LRCLIBEntryDTO(
                id: abs("kg_\(cid)".hashValue) % 800_000 + 3_100_000,
                trackName: songName,
                artistName: singer,
                albumName: "Kugou Music",
                duration: durMs > 10_000 ? (durMs / 1000.0) : targetDuration,
                instrumental: false,
                plainLyrics: isSynced ? nil : lrcText,
                syncedLyrics: isSynced ? lrcText : nil
            )
        ]
    }

    private func fetchBackupLyricsOvh(artist: String, title: String) async -> String? {
        guard !artist.isEmpty && !title.isEmpty else { return nil }
        let encArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist
        let encTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://api.lyrics.ovh/v1/\(encArtist)/\(encTitle)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = json["lyrics"] as? String,
              !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return lyrics
    }

    private func resolveCanonicalMetadataFromCatalog(query: String, country: String = "us") async -> (title: String, artist: String)? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let trackName = first["trackName"] as? String,
              let artistName = first["artistName"] as? String else {
            return nil
        }
        return Self.extractCleanTitleAndArtist(rawTitle: trackName, rawArtist: artistName)
    }

    public func manualLyricsSearch(songTitle: String, artistName: String) async throws -> [LRCLIBEntryDTO] {
        let combinedQuery = "\(songTitle) \(artistName)".trimmingCharacters(in: .whitespacesAndNewlines)
        return await withTaskGroup(of: [LRCLIBEntryDTO].self) { group in
            group.addTask {
                (try? await self.searchLRCLIB(title: songTitle, artist: artistName)) ?? []
            }
            group.addTask {
                await self.fetchQQMusicLyrics(query: combinedQuery, targetDuration: 210)
            }
            group.addTask {
                await self.fetchNetEaseLyrics(query: combinedQuery, targetDuration: 210)
            }
            var all: [LRCLIBEntryDTO] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            // Show synchronized LRC results first!
            return all.sorted { lhs, rhs in
                let lSynced = !(lhs.syncedLyrics ?? "").isEmpty
                let rSynced = !(rhs.syncedLyrics ?? "").isEmpty
                if lSynced != rSynced { return lSynced }
                return lhs.trackName < rhs.trackName
            }
        }
    }

    public func applyManualLyricSelection(_ dto: LRCLIBEntryDTO, for track: UniversalTrack) {
        activeRequestID = UUID()
        let (parsedTitle, parsedArtist) = Self.extractCleanTitleAndArtist(rawTitle: track.title, rawArtist: track.artist)
        let cacheKey = "\(parsedArtist.lowercased())::\(parsedTitle.lowercased())"
        cacheLyrics(
            cacheKey: cacheKey,
            title: track.title,
            artist: track.artist,
            syncedLRC: dto.syncedLyrics,
            plainLyrics: dto.plainLyrics
        )
        self.currentDocument = buildDocument(
            title: track.title,
            artist: track.artist,
            syncedLRC: dto.syncedLyrics,
            plainLyrics: dto.plainLyrics,
            trackDuration: track.duration
        )
        self.loadedTrackID = track.id
        self.errorMessage = nil
    }

    private func fetchExactLRCLIB(title: String, artist: String, album: String, duration: TimeInterval) async throws -> LRCLIBEntryDTO? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if !album.isEmpty && album != "Single" && !album.contains("YouTube") && !album.contains("Audius") {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 20 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("AuraMusic iOS/1.1 (https://auramusic.local)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try JSONDecoder().decode(LRCLIBEntryDTO.self, from: data)
    }

    private func searchLRCLIB(title: String, artist: String) async throws -> [LRCLIBEntryDTO] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("AuraMusic iOS/1.1 (https://auramusic.local)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        return try JSONDecoder().decode([LRCLIBEntryDTO].self, from: data)
    }

    private func cacheLyrics(cacheKey: String, title: String, artist: String, syncedLRC: String?, plainLyrics: String?) {
        let sample = syncedLRC ?? plainLyrics ?? ""
        let lang = LRCParser.detectScriptLanguage(for: sample)
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.syncedLRC = syncedLRC
            existing.plainLyrics = plainLyrics
            existing.languageCode = lang.code
            existing.cachedAt = .now
        } else {
            let entity = PersistedCachedLyricsEntity(
                cacheKey: cacheKey,
                trackTitle: title,
                artistName: artist,
                syncedLRC: syncedLRC,
                plainLyrics: plainLyrics,
                languageCode: lang.code
            )
            context.insert(entity)
        }
        try? context.save()
    }

    private func buildDocument(
        title: String,
        artist: String,
        syncedLRC: String?,
        plainLyrics: String?,
        trackDuration: TimeInterval = 200
    ) -> TrackLyricsDocument? {
        if let syncedLRC, !syncedLRC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsedLines = LRCParser.parseSyncedLRC(syncedLRC, includeIntroDots: true)
            if !parsedLines.isEmpty {
                let fullSample = parsedLines.filter { !$0.isInstrumental }.map(\.text).joined(separator: "\n")
                let lang = LRCParser.detectScriptLanguage(for: fullSample.isEmpty ? title : fullSample)
                return TrackLyricsDocument(
                    trackTitle: title,
                    artistName: artist,
                    isSynchronized: true,
                    detectedLanguageCode: lang.code,
                    detectedLanguageDisplayName: lang.displayName,
                    syncedLines: parsedLines,
                    plainLines: parsedLines.filter { !$0.isInstrumental }.map(\.text),
                    hasTranslationAvailable: false
                )
            }
        }

        if let plainLyrics, !plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rawLines = plainLyrics
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !LRCParser.isInstrumentalMarker($0) }
            guard !rawLines.isEmpty else { return nil }

            // Automatically distribute timestamps proportionally across the track duration
            // so even plain lyrics in any language highlight line-by-line and auto-scroll smoothly!
            let totalDur = trackDuration > 30 ? trackDuration : 200.0
            let introOffset = min(6.0, totalDur * 0.05)
            let activeSpan = max(totalDur - introOffset - 6.0, Double(rawLines.count) * 2.5)
            let step = activeSpan / Double(max(rawLines.count, 1))

            var autoSyncedLines: [SyncedLyricLine] = []
            if introOffset >= 3.0 {
                autoSyncedLines.append(
                    SyncedLyricLine(
                        index: 0,
                        timestamp: 0.0,
                        text: "•••",
                        isInstrumental: true,
                        translatedText: nil
                    )
                )
            }

            for (rawIdx, text) in rawLines.enumerated() {
                let parts = text.components(separatedBy: " // ")
                let cleanOriginal = (parts.first ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanOriginal.isEmpty else { continue }
                autoSyncedLines.append(
                    SyncedLyricLine(
                        index: autoSyncedLines.count,
                        timestamp: introOffset + (Double(rawIdx) * step),
                        text: cleanOriginal,
                        isInstrumental: false,
                        translatedText: nil
                    )
                )
            }

            let lang = LRCParser.detectScriptLanguage(for: plainLyrics)
            return TrackLyricsDocument(
                trackTitle: title,
                artistName: artist,
                isSynchronized: true,
                detectedLanguageCode: lang.code,
                detectedLanguageDisplayName: lang.displayName,
                syncedLines: autoSyncedLines,
                plainLines: rawLines,
                hasTranslationAvailable: false
            )
        }

        return nil
    }
}

public struct LRCLIBEntryDTO: Codable, Identifiable, Sendable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool?
    public var plainLyrics: String?
    public var syncedLyrics: String?
}

// MARK: - Apple Music Stationary Instrumental Progress Dots (0 -> 1 -> 2 -> 3 dots)

public struct AppleMusicInstrumentalDotsView: View, Equatable {
    public let litDotsCount: Int

    public init(litDotsCount: Int) {
        self.litDotsCount = litDotsCount
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                let isLit = index < litDotsCount
                Circle()
                    .fill(Color.white.opacity(isLit ? 1.0 : 0.25))
                    .frame(width: 10, height: 10)
                    .scaleEffect(isLit ? 1.12 : 0.92)
            }
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: litDotsCount)
    }

    /// Computes how many dots (0...3) should be lit based on elapsed fraction of the pause
    public static func calculateLitDots(currentTime: TimeInterval, startTime: TimeInterval, endTime: TimeInterval) -> Int {
        let duration = endTime - startTime
        guard duration > 0.2 else { return 3 }
        let elapsed = currentTime - startTime
        guard elapsed >= 0 else { return 0 }
        let progress = elapsed / duration
        if progress >= 0.85 {
            return 3
        } else if progress >= 0.55 {
            return 2
        } else if progress >= 0.25 {
            return 1
        } else {
            return 0
        }
    }
}

// MARK: - Dedicated Equatable Lyric & Instrumental Row Views (120 FPS + Guaranteed Crisp Illumination)

private struct SyncedLyricTextRowView: View, Equatable {
    let text: String
    let isCurrent: Bool
    let isPast: Bool

    static func == (lhs: SyncedLyricTextRowView, rhs: SyncedLyricTextRowView) -> Bool {
        lhs.isCurrent == rhs.isCurrent &&
        lhs.isPast == rhs.isPast &&
        lhs.text == rhs.text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(.white.opacity(isCurrent ? 1.0 : (isPast ? 0.24 : 0.45)))
            .scaleEffect(isCurrent ? 1.05 : 0.96, anchor: .leading)
            .shadow(color: isCurrent ? .white.opacity(0.22) : .clear, radius: isCurrent ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isCurrent ? Color.white.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.22), value: isCurrent)
            .animation(.easeOut(duration: 0.22), value: isPast)
            .animation(.interpolatingSpring(stiffness: 170, damping: 24), value: isCurrent)
    }
}

private struct SyncedInstrumentalDotsRowView: View, Equatable {
    let isCurrent: Bool
    let litDotsCount: Int

    static func == (lhs: SyncedInstrumentalDotsRowView, rhs: SyncedInstrumentalDotsRowView) -> Bool {
        lhs.isCurrent == rhs.isCurrent && lhs.litDotsCount == rhs.litDotsCount
    }

    var body: some View {
        HStack {
            AppleMusicInstrumentalDotsView(litDotsCount: isCurrent ? litDotsCount : 0)
            Spacer()
        }
        .opacity(isCurrent ? 1.0 : 0.28)
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.22), value: isCurrent)
    }
}

// MARK: - Apple Music Full-Screen Synchronized Lyrics View

public struct SynchronizedLyricsView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine
    @ObservedObject var lyricsService: LyricsService = .shared
    @ObservedObject var aiEngine: AILyricsTranscriptionEngine = .shared

    @State private var activeLineIndex: Int? = nil
    @State private var activeDotStage: Int = 0
    @State private var isUserManualScrolling: Bool = false
    @State private var showTranslationOverlay: Bool = false
    @State private var showManualSearchSheet: Bool = false
    @State private var manualSongQuery: String = ""
    @State private var manualArtistQuery: String = ""
    @State private var manualSearchResults: [LRCLIBEntryDTO] = []
    @State private var isSearchingManually: Bool = false

    public init(player: UniversalAudioPlayerEngine) {
        self.player = player
    }

    public var body: some View {
        VStack(spacing: 0) {
            lyricsHeaderBar

            if lyricsService.lyricsMode == .aiAudio {
                aiLyricsModeContent
            } else if lyricsService.isLoading {
                Spacer()
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                Text("Loading Apple Music Synchronized Lyrics…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 12)
                Spacer()
            } else if let doc = lyricsService.currentDocument {
                if doc.isSynchronized {
                    synchronizedLyricsScroll(doc: doc)
                } else {
                    unsynchronizedLyricsScroll(doc: doc)
                }
            } else {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(lyricsService.errorMessage ?? "Lyrics Unavailable")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        if let track = player.currentTrack {
                            withAnimation(AuraTheme.springInteractive) {
                                lyricsService.lyricsMode = .aiAudio
                            }
                            aiEngine.startListening(for: track)
                        }
                    } label: {
                        Label("Определить текст через ИИ (10 раз)", systemImage: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [AuraTheme.accentPink, Color.purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            )
                    }

                    Button {
                        let cleaned = LyricsService.extractCleanTitleAndArtist(
                            rawTitle: player.currentTrack?.title ?? "",
                            rawArtist: player.currentTrack?.artist ?? ""
                        )
                        manualSongQuery = cleaned.title
                        manualArtistQuery = cleaned.artist
                        showManualSearchSheet = true
                    } label: {
                        Label("Search Lyrics by Song & Artist", systemImage: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.white.opacity(0.2)))
                    }
                }
                Spacer()
            }
        }
        .task(id: player.currentTrack?.id) {
            if let track = player.currentTrack {
                await lyricsService.loadLyrics(for: track)
            }
        }
        .sheet(isPresented: $showManualSearchSheet) {
            manualLyricsSearchSheet
        }
    }

    @ViewBuilder
    private var aiLyricsModeContent: some View {
        if aiEngine.state.isRunning {
            aiListeningProgressView
        } else if let aiDoc = lyricsService.aiDocument {
            synchronizedLyricsScroll(doc: aiDoc)
        } else {
            aiReadyOrErrorView
        }
    }

    private var aiListeningProgressView: some View {
        let st = aiEngine.state
        let percent = Int((max(0, min(1, st.progress)) * 100).rounded())
        let elapsedInt = Int(min(st.maxBudgetSeconds, max(0, st.elapsedSeconds)).rounded())
        let maxInt = Int(st.maxBudgetSeconds.rounded())

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                Spacer().frame(height: 16)

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [AuraTheme.accentPink.opacity(0.45), Color.purple.opacity(0.15), .clear],
                                center: .center,
                                startRadius: 6,
                                endRadius: 56
                            )
                        )
                        .frame(width: 96, height: 96)

                    Image(systemName: "sparkles")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: st.isRunning)
                }

                VStack(spacing: 6) {
                    Text("ИИ слушает песню")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Text("Прослушивание \(max(1, st.currentPass)) / \(st.totalPasses)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(AuraTheme.accentPink.opacity(0.85)))

                        Text(String(format: "0:%02d / 0:%02d", elapsedInt, maxInt))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                }

                // Animated Loading Progress Bar (загрузочная строка)
                VStack(spacing: 10) {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let clamped = max(0.03, min(1.0, st.progress))
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(height: 10)

                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [AuraTheme.accentPink, Color.purple, Color.white],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: width * CGFloat(clamped), height: 10)
                                .shadow(color: AuraTheme.accentPink.opacity(0.6), radius: 8, x: 0, y: 0)
                                .animation(.easeOut(duration: 0.25), value: st.progress)
                        }
                    }
                    .frame(height: 10)

                    HStack {
                        Text(st.stageTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text("\(percent)%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    Text(st.stageDetail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // 10-Pass Visual Step Indicators (Pass 1 = analysis, Passes 2–10 = write & verify)
                    HStack(spacing: 6) {
                        ForEach(1...st.totalPasses, id: \.self) { passIdx in
                            let isDone = passIdx < st.currentPass
                            let isActive = passIdx == st.currentPass
                            Capsule(style: .continuous)
                                .fill(
                                    isDone
                                        ? Color.white
                                        : (isActive ? AuraTheme.accentPink : Color.white.opacity(0.22))
                                )
                                .frame(height: isActive ? 6 : 4)
                                .animation(.easeInOut(duration: 0.2), value: st.currentPass)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 24)

                // Pass 1 Detected Language / Pause / Foreign-Insert Chips
                if st.detectedPrimaryLanguage != nil || st.detectedPauseCount > 0 {
                    HStack(spacing: 8) {
                        if let lang = st.detectedPrimaryLanguage {
                            aiInfoChip(icon: "globe", text: lang)
                        }
                        if let sec = st.detectedSecondaryLanguage {
                            aiInfoChip(icon: "character.bubble", text: "+\(sec)")
                        }
                        aiInfoChip(icon: "pause.circle", text: "Пауз: \(st.detectedPauseCount)")
                    }
                    .padding(.horizontal, 20)
                }

                Button {
                    aiEngine.cancel()
                } label: {
                    Text("Отменить")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .padding(.top, 4)

                Spacer().frame(height: 40)
            }
        }
    }

    private func aiInfoChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.16)))
    }

    private var aiReadyOrErrorView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            Text("ИИ-лирика по аудио")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)

            Text(
                aiEngine.state.errorMessage
                    ?? "ИИ прослушает песню 10 раз за ≤30 сек:\n1-й раз — определит язык, паузы и иноязычные вставки.\n2–10-й раз — напишет, сверит и синхронизирует текст."
            )
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)

            Button {
                if let track = player.currentTrack {
                    aiEngine.startListening(for: track, forceReanalyze: true)
                }
            } label: {
                Label("Запустить ИИ (10 прослушиваний)", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [AuraTheme.accentPink, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    )
                    .shadow(color: AuraTheme.accentPink.opacity(0.45), radius: 10, x: 0, y: 4)
            }
            .disabled(player.currentTrack == nil)

            Spacer()
        }
    }

    private var lyricsHeaderBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // Sleek Glass Mode Selector: База vs ✨ ИИ
                HStack(spacing: 3) {
                    ForEach(LyricsDisplayMode.allCases, id: \.self) { mode in
                        let isSelected = (lyricsService.lyricsMode == mode)
                        Button {
                            withAnimation(AuraTheme.springInteractive) {
                                lyricsService.lyricsMode = mode
                            }
                            if mode == .aiAudio, let track = player.currentTrack {
                                if lyricsService.aiDocument == nil && !aiEngine.state.isRunning {
                                    aiEngine.startListening(for: track)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode == .aiAudio ? "sparkles" : "waveform")
                                    .font(.system(size: 11, weight: .bold))
                                Text(mode.rawValue)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.88))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? Color.white : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.16)))

                if let doc = lyricsService.activeDocument {
                    HStack(spacing: 4) {
                        if lyricsService.lyricsMode == .aiAudio {
                            Text("ИИ 10/10")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        Text("• \(doc.detectedLanguageDisplayName.uppercased())")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.14)))
                }

                Spacer()

                if isUserManualScrolling {
                    Button {
                        withAnimation(AuraTheme.springInteractive) {
                            isUserManualScrolling = false
                        }
                    } label: {
                        Label("Sync", systemImage: "arrow.up.and.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.white))
                    }
                }

                if lyricsService.lyricsMode == .aiAudio {
                    Button {
                        if let track = player.currentTrack {
                            aiEngine.startListening(for: track, forceReanalyze: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(.white.opacity(0.16)))
                    }
                    .disabled(aiEngine.state.isRunning || player.currentTrack == nil)
                    .opacity(aiEngine.state.isRunning ? 0.4 : 1.0)
                } else {
                    Button {
                        let cleaned = LyricsService.extractCleanTitleAndArtist(
                            rawTitle: player.currentTrack?.title ?? "",
                            rawArtist: player.currentTrack?.artist ?? ""
                        )
                        manualSongQuery = cleaned.title
                        manualArtistQuery = cleaned.artist
                        showManualSearchSheet = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(.white.opacity(0.16)))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func syncActiveLineAndDots(at time: TimeInterval, in doc: TrackLyricsDocument) -> Int? {
        let nextIdx = LyricSynchronizationEngine.activeLineIndex(at: time, in: doc.syncedLines)
        let nextDots: Int
        if let idx = nextIdx, doc.syncedLines[idx].isInstrumental {
            nextDots = LyricSynchronizationEngine.litDotsCount(
                at: time,
                forLineAt: idx,
                in: doc.syncedLines,
                trackDuration: PlaybackClock.shared.duration
            )
        } else {
            nextDots = 0
        }
        if activeLineIndex != nextIdx {
            activeLineIndex = nextIdx
        }
        if activeDotStage != nextDots {
            activeDotStage = nextDots
        }
        return nextIdx
    }

    private func synchronizedLyricsScroll(doc: TrackLyricsDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // VStack guarantees exact row frames for scrollTo; .equatable() rows ensure ONLY the 2 transitioning rows redraw!
                VStack(alignment: .leading, spacing: 20) {
                    Spacer().frame(height: 24)

                    ForEach(doc.syncedLines) { line in
                        let isCurrent = (activeLineIndex == line.index)
                        let isPast = (activeLineIndex != nil) ? (line.index < activeLineIndex!) : false

                        Group {
                            if line.isInstrumental {
                                SyncedInstrumentalDotsRowView(
                                    isCurrent: isCurrent,
                                    litDotsCount: isCurrent ? activeDotStage : 0
                                )
                                .equatable()
                            } else {
                                SyncedLyricTextRowView(
                                    text: line.text,
                                    isCurrent: isCurrent,
                                    isPast: isPast
                                )
                                .equatable()
                            }
                        }
                        .id(line.index)
                        .onTapGesture {
                            isUserManualScrolling = false
                            activeLineIndex = line.index
                            activeDotStage = 0
                            player.seek(to: line.timestamp)
                            if !player.isPlaying {
                                player.resume()
                            }
                            withAnimation(.interpolatingSpring(stiffness: 145, damping: 22)) {
                                proxy.scrollTo(line.index, anchor: UnitPoint(x: 0.5, y: 0.38))
                            }
                        }
                    }

                    Spacer().frame(height: 180)
                }
                .id(doc.id)
                .padding(.horizontal, 20)
            }
            .onAppear {
                let initial = syncActiveLineAndDots(at: PlaybackClock.shared.currentTime, in: doc)
                if !doc.syncedLines.isEmpty {
                    proxy.scrollTo(initial ?? 0, anchor: UnitPoint(x: 0.5, y: 0.38))
                }
            }
            .onChange(of: doc.id) { _, _ in
                isUserManualScrolling = false
                let initial = syncActiveLineAndDots(at: PlaybackClock.shared.currentTime, in: doc)
                if !doc.syncedLines.isEmpty {
                    proxy.scrollTo(initial ?? 0, anchor: UnitPoint(x: 0.5, y: 0.38))
                }
            }
            .onReceive(PlaybackClock.shared.$currentTime) { newTime in
                let previousIdx = activeLineIndex
                let nextIdx = syncActiveLineAndDots(at: newTime, in: doc)
                if nextIdx != previousIdx, !isUserManualScrolling, let target = nextIdx {
                    withAnimation(.interpolatingSpring(stiffness: 145, damping: 22)) {
                        proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.38))
                    }
                }
            }
        }
    }

    private func unsynchronizedLyricsScroll(doc: TrackLyricsDocument) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text("Time-synchronized lyrics are unavailable for this track. Displaying original unsynchronized lyrics.")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
                .padding(.bottom, 8)

                ForEach(Array(doc.plainLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer().frame(height: 120)
            }
            .padding(.horizontal, 26)
            .padding(.top, 16)
        }
    }

    private var manualLyricsSearchSheet: some View {
        NavigationStack {
            List {
                Section("Search by Song & Artist (Original Language Preserved)") {
                    TextField("Song Title (e.g. 夜に駆ける, Dynamite, Starboy)", text: $manualSongQuery)
                    TextField("Artist Name", text: $manualArtistQuery)
                    Button {
                        Task {
                            isSearchingManually = true
                            manualSearchResults = (try? await lyricsService.manualLyricsSearch(
                                songTitle: manualSongQuery,
                                artistName: manualArtistQuery
                            )) ?? []
                            isSearchingManually = false
                        }
                    } label: {
                        HStack {
                            Text("Search LRCLIB Database")
                                .fontWeight(.semibold)
                            Spacer()
                            if isSearchingManually {
                                ProgressView()
                            }
                        }
                    }
                    .foregroundStyle(AuraTheme.accentPink)
                }

                Section("Matching Lyrics") {
                    if manualSearchResults.isEmpty && !isSearchingManually {
                        Text("Enter a song and artist above to search synchronized and plain lyrics.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manualSearchResults) { item in
                        Button {
                            if let track = player.currentTrack {
                                lyricsService.applyManualLyricSelection(item, for: track)
                            }
                            showManualSearchSheet = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.trackName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if item.syncedLyrics != nil {
                                        Text("SYNCED LRC")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(AuraTheme.accentPink)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(AuraTheme.accentPink.opacity(0.15)))
                                    } else {
                                        Text("PLAIN")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text("\(item.artistName) • \(item.albumName ?? "Single")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lyrics Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showManualSearchSheet = false }
                }
            }
        }
    }
}
