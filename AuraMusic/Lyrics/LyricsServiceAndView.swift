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
    public var translatedText: String?

    public init(
        id: UUID = UUID(),
        index: Int,
        timestamp: TimeInterval,
        text: String,
        translatedText: String? = nil
    ) {
        self.id = id
        self.index = index
        self.timestamp = timestamp
        self.text = text
        self.translatedText = translatedText
    }
}

public struct TrackLyricsDocument: Sendable {
    public let trackTitle: String
    public let artistName: String
    public let isSynchronized: Bool
    public let detectedLanguageCode: String
    public let detectedLanguageDisplayName: String
    public let syncedLines: [SyncedLyricLine]
    public let plainLines: [String]
    public let hasTranslationAvailable: Bool
}

// MARK: - Millisecond-Accurate LRC Parser

public enum LRCParser {
    /// Parses standard and extended LRC timestamps: `[mm:ss.xx]` or `[mm:ss.xxx]` or `[mm:ss]`
    /// Never invents timestamps for unsynchronized plain text.
    public static func parseSyncedLRC(_ rawLRC: String) -> [SyncedLyricLine] {
        let lines = rawLRC.components(separatedBy: .newlines)
        let pattern = "\\[(\\d{1,3}):(\\d{2})(?:[\\.:](\\d{1,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        var parsedEntries: [(timestamp: TimeInterval, text: String)] = []

        for rawLine in lines {
            let nsRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, options: [], range: nsRange)
            guard !matches.isEmpty else { continue }

            let lastMatch = matches.last!
            let contentStartIndex = rawLine.index(rawLine.startIndex, offsetBy: lastMatch.range.upperBound)
            let lyricContent = String(rawLine[contentStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

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
                let totalSeconds = (minutes * 60.0) + seconds + fraction
                parsedEntries.append((timestamp: totalSeconds, text: lyricContent))
            }
        }

        let sorted = parsedEntries.sorted { $0.timestamp < $1.timestamp }
        return sorted.enumerated().map { idx, item in
            let original = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SyncedLyricLine(
                index: idx,
                timestamp: item.timestamp,
                text: original.isEmpty ? "•••" : original,
                translatedText: nil
            )
        }
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

// MARK: - Official LRCLIB Lyrics Client + Multi-Stage Smart Resolver + SwiftData Cache

@MainActor
public final class LyricsService: ObservableObject {
    public static let shared = LyricsService()

    @Published public private(set) var currentDocument: TrackLyricsDocument?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    private let session: URLSession

    private init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns the currently active synchronized lyric line for live preview on the Apple Music player card
    public func activeLyricLineText(at currentTime: TimeInterval) -> String? {
        guard let doc = currentDocument else { return nil }
        if doc.isSynchronized {
            let t = currentTime + 0.15
            var currentText: String? = nil
            for line in doc.syncedLines {
                if t >= line.timestamp {
                    if line.text != "•••" && !line.text.isEmpty {
                        currentText = line.text
                    }
                } else {
                    break
                }
            }
            return currentText ?? doc.syncedLines.first(where: { $0.text != "•••" })?.text
        } else {
            return doc.plainLines.first(where: { !$0.isEmpty })
        }
    }

    public func loadLyrics(for track: UniversalTrack) async {
        let (parsedTitle, parsedArtist) = Self.extractCleanTitleAndArtist(rawTitle: track.title, rawArtist: track.artist)
        let cacheKey = "\(parsedArtist.lowercased())::\(parsedTitle.lowercased())"

        isLoading = true
        errorMessage = nil

        // 1. Check SwiftData local lyrics cache first (only if it has synchronized LRC)
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let cached = try? context.fetch(descriptor).first,
           !(cached.syncedLRC ?? "").isEmpty {
            self.currentDocument = buildDocument(
                title: track.title,
                artist: track.artist,
                syncedLRC: cached.syncedLRC,
                plainLyrics: cached.plainLyrics
            )
            self.isLoading = false
            return
        }

        // 2. Multi-stage LRCLIB search prioritizing time-synchronized LRC lyrics in the ORIGINAL language
        let referenceScriptText = "\(track.title) \(track.artist) \(parsedTitle) \(parsedArtist)"
        do {
            var allCandidates: [LRCLIBEntryDTO] = []

            if let exact = try? await fetchExactLRCLIB(title: parsedTitle, artist: parsedArtist, album: track.album, duration: track.duration) {
                allCandidates.append(exact)
            }

            if let search1 = try? await searchLRCLIB(title: parsedTitle, artist: parsedArtist) {
                allCandidates.append(contentsOf: search1)
            }

            // If no synced lyrics found yet, try searching by clean title alone
            if !allCandidates.contains(where: { !($0.syncedLyrics ?? "").isEmpty }) {
                if let search2 = try? await searchLRCLIB(title: parsedTitle, artist: "") {
                    allCandidates.append(contentsOf: search2)
                }
            }

            // Stage 3: Resolve canonical song title & artist via iTunes catalog metadata if YouTube title was heavily stylized
            if !allCandidates.contains(where: { !($0.syncedLyrics ?? "").isEmpty }) {
                if let canonical = await resolveCanonicalMetadataFromCatalog(query: "\(parsedTitle) \(parsedArtist)") {
                    if let search3 = try? await searchLRCLIB(title: canonical.title, artist: canonical.artist) {
                        allCandidates.append(contentsOf: search3)
                    }
                    if !allCandidates.contains(where: { !($0.syncedLyrics ?? "").isEmpty }),
                       let search4 = try? await searchLRCLIB(title: canonical.title, artist: "") {
                        allCandidates.append(contentsOf: search4)
                    }
                }
            }

            if let bestDTO = Self.selectBestOriginalLanguageCandidate(
                from: allCandidates,
                referenceText: referenceScriptText,
                targetDuration: track.duration
            ) {
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
                    plainLyrics: bestDTO.plainLyrics
                )
                self.isLoading = false
                return
            }
        }

        self.currentDocument = nil
        self.errorMessage = "No licensed lyrics found for \"\(parsedTitle)\". Tap the magnifying glass to search manually."
        self.isLoading = false
    }

    /// Splits composite titles like "Miyagi & Эндшпиль feat. Рем Дигга - I Got Love (Official Video)" into ("I Got Love", "Miyagi & Эндшпиль")
    public static func extractCleanTitleAndArtist(rawTitle: String, rawArtist: String) -> (title: String, artist: String) {
        var workingTitle = rawTitle
        var workingArtist = rawArtist
            .replacingOccurrences(of: " - Topic", with: "")
            .replacingOccurrences(of: "VEVO", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Handle Japanese/Asian corner brackets e.g. YOASOBI「アイドル」Official Music Video
        if let openBracket = workingTitle.firstIndex(of: "「"),
           let closeBracket = workingTitle.firstIndex(of: "」"),
           openBracket < closeBracket {
            let prefixArtist = String(workingTitle[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            let insideTitle = String(workingTitle[workingTitle.index(after: openBracket)..<closeBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !insideTitle.isEmpty {
                workingTitle = insideTitle
                if !prefixArtist.isEmpty {
                    workingArtist = prefixArtist
                }
            }
        }

        // 2. Strip parenthetical & bracketed video/audio noise in both Russian and English FIRST
        let bracketPatterns = [
            "\\([^)]*(?:official|audio|video|lyric|remaster|visualizer|live|hd|4k|клип|видео|аудио|премьера|официальн|текст|музыка|ost|prod)[^)]*\\)",
            "\\[[^\\]]*(?:official|audio|video|lyric|remaster|visualizer|live|hd|4k|клип|видео|аудио|премьера|официальн|текст|музыка|ost|prod)[^\\]]*\\]"
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

        // 4. Now strip trailing feat./ft./prod. from both title and artist
        let featPatterns = [
            "\\([^)]*(?:feat\\.?|ft\\.?|prod\\.?)[^)]*\\)",
            "\\[[^\\]]*(?:feat\\.?|ft\\.?|prod\\.?)[^\\]]*\\]",
            "(?i)\\b(?:feat\\.?|ft\\.?|prod\\.?)\\s+.+$",
            "(?i)\\b(?:official\\s+music\\s+video|official\\s+video|official\\s+audio|lyric\\s+video|премьера\\s+клипа|официальный\\s+клип).*$"
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

    /// Selects the best lyric entry while strictly preserving the song's original language and rejecting English translations/romanizations
    private static func selectBestOriginalLanguageCandidate(
        from candidates: [LRCLIBEntryDTO],
        referenceText: String,
        targetDuration: TimeInterval
    ) -> LRCLIBEntryDTO? {
        let valid = candidates.filter { !($0.syncedLyrics ?? "").isEmpty || !($0.plainLyrics ?? "").isEmpty }
        guard !valid.isEmpty else { return nil }

        let expectsCyrillic = containsScript(referenceText, pattern: "\\p{Cyrillic}")
        let expectsJapanese = containsScript(referenceText, pattern: "[\\p{Hiragana}\\p{Katakana}]")
        let expectsKorean = containsScript(referenceText, pattern: "\\p{Hangul}")

        let scored = valid.map { item -> (dto: LRCLIBEntryDTO, score: Int) in
            let textSample = (item.syncedLyrics ?? item.plainLyrics ?? "")
            let metaSample = "\(item.trackName) \(item.albumName ?? "")"
            var score = 0

            // Strongly prefer time-synchronized LRC lyrics
            if !(item.syncedLyrics ?? "").isEmpty {
                score += 100
            }

            // Penalize any entry marked as a translation or romanization
            if metaSample.range(of: "translation|translated|romanized|romaji|перевод|english ver", options: .regularExpression) != nil {
                score -= 250
            }

            // Enforce original script preservation
            let hasCyrillic = containsScript(textSample, pattern: "\\p{Cyrillic}")
            let hasJapanese = containsScript(textSample, pattern: "[\\p{Hiragana}\\p{Katakana}]")
            let hasKorean = containsScript(textSample, pattern: "\\p{Hangul}")

            if expectsCyrillic {
                score += hasCyrillic ? 150 : -120
            } else if expectsJapanese {
                score += hasJapanese ? 150 : -150
            } else if expectsKorean {
                score += hasKorean ? 150 : -150
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

    private static func containsScript(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func resolveCanonicalMetadataFromCatalog(query: String) async -> (title: String, artist: String)? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
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
        try await searchLRCLIB(title: songTitle, artist: artistName)
    }

    public func applyManualLyricSelection(_ dto: LRCLIBEntryDTO, for track: UniversalTrack) {
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
            plainLyrics: dto.plainLyrics
        )
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

    private func buildDocument(title: String, artist: String, syncedLRC: String?, plainLyrics: String?) -> TrackLyricsDocument? {
        if let syncedLRC, !syncedLRC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsedLines = LRCParser.parseSyncedLRC(syncedLRC)
            if !parsedLines.isEmpty {
                let fullSample = parsedLines.map(\.text).joined(separator: "\n")
                let lang = LRCParser.detectScriptLanguage(for: fullSample)
                let hasTrans = parsedLines.contains { $0.translatedText != nil }
                return TrackLyricsDocument(
                    trackTitle: title,
                    artistName: artist,
                    isSynchronized: true,
                    detectedLanguageCode: lang.code,
                    detectedLanguageDisplayName: lang.displayName,
                    syncedLines: parsedLines,
                    plainLines: parsedLines.map(\.text),
                    hasTranslationAvailable: hasTrans
                )
            }
        }

        if let plainLyrics, !plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = plainLyrics
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let lang = LRCParser.detectScriptLanguage(for: plainLyrics)
            return TrackLyricsDocument(
                trackTitle: title,
                artistName: artist,
                isSynchronized: false,
                detectedLanguageCode: lang.code,
                detectedLanguageDisplayName: lang.displayName,
                syncedLines: [],
                plainLines: lines,
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

// MARK: - Apple Music Stationary Instrumental Progress Dots (1/3 -> 1 dot, 2/3 -> 2 dots, 3/3 -> 3 dots)

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
        let progress = elapsed / duration
        if progress >= 0.90 {
            return 3
        } else if progress >= 0.66 {
            return 2
        } else if progress >= 0.33 {
            return 1
        } else {
            return 0
        }
    }
}

// MARK: - High-Performance Equatable Lyric Row (Prevents Re-Rendering Inactive Lines)

private struct EquatableSyncedLyricRowView: View, Equatable {
    let line: SyncedLyricLine
    let isCurrent: Bool
    let showTranslationOverlay: Bool
    let litDotsCount: Int

    static func == (lhs: EquatableSyncedLyricRowView, rhs: EquatableSyncedLyricRowView) -> Bool {
        lhs.line.id == rhs.line.id &&
        lhs.isCurrent == rhs.isCurrent &&
        lhs.showTranslationOverlay == rhs.showTranslationOverlay &&
        lhs.litDotsCount == rhs.litDotsCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if line.text == "•••" {
                AppleMusicInstrumentalDotsView(litDotsCount: isCurrent ? litDotsCount : 0)
            } else {
                Text(line.text)
                    .font(.system(size: isCurrent ? 29 : 24, weight: .bold))
                    .foregroundStyle(.white.opacity(isCurrent ? 1.0 : 0.34))
            }

            if showTranslationOverlay, let translated = line.translatedText {
                Text(translated)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(isCurrent ? 0.85 : 0.30))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Apple Music Full-Screen Synchronized Lyrics View

public struct SynchronizedLyricsView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine
    @ObservedObject var lyricsService: LyricsService = .shared

    @State private var isUserManualScrolling: Bool = false
    @State private var highlightedLineIndex: Int? = nil
    @State private var showTranslationOverlay: Bool = false
    @State private var showManualSearchSheet: Bool = false
    @State private var manualSongQuery: String = ""
    @State private var manualArtistQuery: String = ""
    @State private var manualSearchResults: [LRCLIBEntryDTO] = []
    @State private var isSearchingManually: Bool = false

    public init(player: UniversalAudioPlayerEngine) {
        self.player = player
    }

    private func computeActiveLineIndex(at time: TimeInterval, in doc: TrackLyricsDocument) -> Int? {
        guard doc.isSynchronized else { return nil }
        let current = time + 0.18
        var matched: Int? = nil
        for line in doc.syncedLines {
            if current >= line.timestamp {
                matched = line.index
            } else {
                break
            }
        }
        return matched
    }

    private var activeLineIndex: Int? {
        if let highlightedLineIndex { return highlightedLineIndex }
        guard let doc = lyricsService.currentDocument else { return nil }
        return computeActiveLineIndex(at: player.currentTime, in: doc)
    }

    private var isInIntroBeforeFirstLine: Bool {
        guard let doc = lyricsService.currentDocument,
              doc.isSynchronized,
              let first = doc.syncedLines.first else {
            return false
        }
        return player.currentTime < first.timestamp
    }

    public var body: some View {
        VStack(spacing: 0) {
            lyricsHeaderBar

            if lyricsService.isLoading {
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

    private var lyricsHeaderBar: some View {
        HStack(spacing: 10) {
            if let doc = lyricsService.currentDocument {
                HStack(spacing: 6) {
                    Image(systemName: doc.isSynchronized ? "waveform" : "text.alignleft")
                        .font(.system(size: 11, weight: .bold))
                    Text(doc.isSynchronized ? "APPLE MUSIC SING SYNC" : "LYRICS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    Text("• \(doc.detectedLanguageDisplayName.uppercased())")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.18)))

                if doc.hasTranslationAvailable {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showTranslationOverlay.toggle()
                        }
                    } label: {
                        Image(systemName: "character.bubble.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(showTranslationOverlay ? Color.black : Color.white)
                            .padding(7)
                            .background(Circle().fill(showTranslationOverlay ? Color.white : Color.white.opacity(0.18)))
                    }
                }
            }

            Spacer()

            if isUserManualScrolling {
                Button {
                    withAnimation(AuraTheme.springInteractive) {
                        isUserManualScrolling = false
                    }
                } label: {
                    Label("Resume Sync", systemImage: "arrow.up.and.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                }
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
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private func synchronizedLyricsScroll(doc: TrackLyricsDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Spacer().frame(height: 20)

                    if isInIntroBeforeFirstLine, let firstLine = doc.syncedLines.first {
                        let introDots = AppleMusicInstrumentalDotsView.calculateLitDots(
                            currentTime: player.currentTime,
                            startTime: 0,
                            endTime: firstLine.timestamp
                        )
                        AppleMusicInstrumentalDotsView(litDotsCount: introDots)
                            .id(-1)
                    }

                    ForEach(doc.syncedLines) { line in
                        let isCurrent = (activeLineIndex == line.index)
                        let nextTimestamp: TimeInterval = (line.index + 1 < doc.syncedLines.count)
                            ? doc.syncedLines[line.index + 1].timestamp
                            : max(player.duration, line.timestamp + 6.0)
                        let dotStage = (isCurrent && line.text == "•••")
                            ? AppleMusicInstrumentalDotsView.calculateLitDots(
                                currentTime: player.currentTime,
                                startTime: line.timestamp,
                                endTime: nextTimestamp
                            )
                            : 0

                        VStack(alignment: .leading, spacing: 6) {
                            if line.text == "•••" {
                                AppleMusicInstrumentalDotsView(litDotsCount: isCurrent ? dotStage : 0)
                            } else {
                                Text(line.text)
                                    .font(.system(size: isCurrent ? 30 : 23, weight: .bold))
                                    .foregroundStyle(.white.opacity(isCurrent ? 1.0 : 0.30))
                            }

                            if showTranslationOverlay, let translated = line.translatedText {
                                Text(translated)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white.opacity(isCurrent ? 0.88 : 0.28))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isCurrent ? Color.white.opacity(0.10) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .id(line.index)
                        .onTapGesture {
                            isUserManualScrolling = false
                            player.seek(to: line.timestamp)
                            if !player.isPlaying {
                                player.resume()
                            }
                            highlightedLineIndex = line.index
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(line.index, anchor: .center)
                            }
                        }
                    }

                    Spacer().frame(height: 150)
                }
                .padding(.horizontal, 20)
            }
            .onAppear {
                if let initial = computeActiveLineIndex(at: player.currentTime, in: doc) {
                    highlightedLineIndex = initial
                    proxy.scrollTo(initial, anchor: .center)
                }
            }
            .onReceive(player.$currentTime) { newTime in
                let nextIdx = computeActiveLineIndex(at: newTime, in: doc)
                if nextIdx != highlightedLineIndex {
                    highlightedLineIndex = nextIdx
                    if let target = nextIdx {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
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
