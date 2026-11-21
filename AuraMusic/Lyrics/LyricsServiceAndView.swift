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
            // Support inline dual-language LRC rows separated by " / " or " | " without replacing original script
            let parts = item.text.components(separatedBy: " // ")
            let original = parts.first ?? item.text
            let translation = parts.count > 1 ? parts[1] : nil
            return SyncedLyricLine(
                index: idx,
                timestamp: item.timestamp,
                text: original.isEmpty ? "•••" : original,
                translatedText: translation
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

// MARK: - Official LRCLIB Lyrics Client + SwiftData Cache

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

    public func loadLyrics(for track: UniversalTrack) async {
        let cleanTitle = TrackMatchingEngine.normalizeTitle(track.title)
        let cacheKey = "\(track.artist.lowercased())::\(track.title.lowercased())"

        isLoading = true
        errorMessage = nil

        // 1. Check SwiftData local lyrics cache first
        let context = PersistenceController.shared.context
        let descriptor = FetchDescriptor<PersistedCachedLyricsEntity>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let cached = try? context.fetch(descriptor).first {
            self.currentDocument = buildDocument(
                title: track.title,
                artist: track.artist,
                syncedLRC: cached.syncedLRC,
                plainLyrics: cached.plainLyrics
            )
            self.isLoading = false
            return
        }

        // 2. Query LRCLIB Exact Match API (`https://lrclib.net/api/get`)
        do {
            if let dto = try await fetchExactLRCLIB(track: track) ?? (try await searchLRCLIB(title: track.title, artist: track.artist).first) ?? (try await searchLRCLIB(title: cleanTitle, artist: track.artist).first) {
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
                self.isLoading = false
                return
            }
        } catch {
            // Try fallback search
        }

        self.currentDocument = nil
        self.errorMessage = "No licensed lyrics found for \"\(track.title)\" by \(track.artist). Tap Search Lyrics to query manually."
        self.isLoading = false
    }

    public func manualLyricsSearch(songTitle: String, artistName: String) async throws -> [LRCLIBEntryDTO] {
        try await searchLRCLIB(title: songTitle, artist: artistName)
    }

    public func applyManualLyricSelection(_ dto: LRCLIBEntryDTO, for track: UniversalTrack) {
        let cacheKey = "\(track.artist.lowercased())::\(track.title.lowercased())"
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

    private func fetchExactLRCLIB(track: UniversalTrack) async throws -> LRCLIBEntryDTO? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if !track.album.isEmpty && track.album != "Single" {
            items.append(URLQueryItem(name: "album_name", value: track.album))
        }
        if track.duration > 10 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("AuraMusic iOS/1.0 (https://auramusic.local)", forHTTPHeaderField: "User-Agent")

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
        request.setValue("AuraMusic iOS/1.0 (https://auramusic.local)", forHTTPHeaderField: "User-Agent")

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

// MARK: - Apple Music Full-Screen Synchronized Lyrics View

public struct SynchronizedLyricsView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine
    @ObservedObject var lyricsService: LyricsService = .shared

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

    private var activeLineIndex: Int? {
        guard let doc = lyricsService.currentDocument, doc.isSynchronized else {
            return nil
        }
        let current = player.currentTime + 0.12
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

    public var body: some View {
        VStack(spacing: 0) {
            lyricsHeaderBar

            if lyricsService.isLoading {
                Spacer()
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                Text("Loading Original Script Lyrics…")
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
                        manualSongQuery = player.currentTrack?.title ?? ""
                        manualArtistQuery = player.currentTrack?.artist ?? ""
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
                    Text(doc.isSynchronized ? "TIME-SYNCED" : "PLAIN LYRICS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    Text("• \(doc.detectedLanguageDisplayName.uppercased())")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.16)))

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
                manualSongQuery = player.currentTrack?.title ?? ""
                manualArtistQuery = player.currentTrack?.artist ?? ""
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
                LazyVStack(alignment: .leading, spacing: 24) {
                    Spacer().frame(height: 36)

                    ForEach(doc.syncedLines) { line in
                        let isCurrent = (activeLineIndex == line.index)
                        let distance = abs((activeLineIndex ?? 0) - line.index)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(line.text)
                                .font(.system(size: isCurrent ? 29 : 24, weight: .bold))
                                .foregroundStyle(.white.opacity(isCurrent ? 1.0 : 0.36))
                                .scaleEffect(isCurrent ? 1.02 : 0.97, anchor: .leading)
                                .blur(radius: isUserManualScrolling || isCurrent ? 0 : min(CGFloat(distance) * 0.45, 1.8))

                            if showTranslationOverlay, let translated = line.translatedText {
                                Text(translated)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(isCurrent ? 0.85 : 0.30))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .id(line.index)
                        .onTapGesture {
                            isUserManualScrolling = false
                            withAnimation(AuraTheme.springInteractive) {
                                player.seek(to: line.timestamp)
                                if !player.isPlaying {
                                    player.resume()
                                }
                            }
                        }
                        .animation(AuraTheme.springInteractive, value: activeLineIndex)
                    }

                    Spacer().frame(height: 160)
                }
                .padding(.horizontal, 26)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    isUserManualScrolling = true
                }
            )
            .onChange(of: activeLineIndex) { _, newIndex in
                guard !isUserManualScrolling, let newIndex else { return }
                withAnimation(.spring(response: 0.48, dampingFraction: 0.85)) {
                    proxy.scrollTo(newIndex, anchor: .center)
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
                        .font(.system(size: 21, weight: .semibold))
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
