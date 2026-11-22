import Foundation
import SwiftUI

// MARK: - Lyrics Display Mode (Original Database vs User-Created Custom Lyrics)

public enum LyricsDisplayMode: String, CaseIterable, Sendable {
    case standard = "Оригинал"
    case custom = "Своя лирика"
}

// MARK: - Custom Lyric Entry Model (Supports Single Line, Dual Simultaneous Lines & Timed Pauses)

public struct CustomLyricEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case lyric = "Текст"
        case pause = "Пауза"
    }

    public var id: UUID
    public var kind: Kind
    /// Raw song audio timestamp in seconds (matches `PlaybackClock.shared.currentTime` 1-to-1).
    public var timestamp: TimeInterval
    public var primaryText: String
    /// Optional second text sung simultaneously with `primaryText` (duet, backing vocals, ad-lib, or dual language).
    public var secondaryText: String?
    /// Explicit duration for `.pause` entries in seconds (drives Apple Music `• • •` dot fill speed).
    public var pauseDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        kind: Kind = .lyric,
        timestamp: TimeInterval,
        primaryText: String = "",
        secondaryText: String? = nil,
        pauseDuration: TimeInterval = 5.0
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = max(0, timestamp)
        self.primaryText = primaryText
        let trimmedSecondary = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secondaryText = (trimmedSecondary?.isEmpty == false) ? trimmedSecondary : nil
        self.pauseDuration = max(1.0, min(120.0, pauseDuration))
    }

    public var isDualText: Bool {
        kind == .lyric && !(secondaryText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Lossless Custom LRC Serializer & Importer

public enum CustomLyricsDocumentBuilder {
    public static let dualTextSeparator = " || "

    /// Compiles user-created entries into clean, strictly monotonic, millisecond-accurate LRC:
    /// - Pause with explicit duration: `[mm:ss.xx]•••{dur=6.5}`
    /// - Single lyric line: `[mm:ss.xx]Line text`
    /// - Dual simultaneous lyric line: `[mm:ss.xx]Main text || Second simultaneous text`
    public static func buildLRC(from entries: [CustomLyricEntry]) -> String {
        let sorted = entries.sorted { lhs, rhs in
            if abs(lhs.timestamp - rhs.timestamp) > 0.005 {
                return lhs.timestamp < rhs.timestamp
            }
            // If a pause and lyric share a timestamp, place pause first
            if lhs.kind != rhs.kind { return lhs.kind == .pause }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var lines: [String] = []
        var lastTS: TimeInterval = -0.05

        for entry in sorted {
            let safeTS = max(0, max(entry.timestamp, lastTS + 0.05))
            switch entry.kind {
            case .pause:
                let dur = max(1.0, min(120.0, entry.pauseDuration))
                let durTag = String(format: "%.1f", dur)
                lines.append("\(formatLRCTimestamp(safeTS))•••{dur=\(durTag)}")
                lastTS = safeTS
            case .lyric:
                let main = entry.primaryText
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let secondary = (entry.secondaryText ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !main.isEmpty || !secondary.isEmpty else { continue }
                if !main.isEmpty && !secondary.isEmpty {
                    lines.append("\(formatLRCTimestamp(safeTS))\(main)\(dualTextSeparator)\(secondary)")
                } else {
                    lines.append("\(formatLRCTimestamp(safeTS))\(main.isEmpty ? secondary : main)")
                }
                lastTS = safeTS
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Imports an existing `TrackLyricsDocument` (custom or original database lyrics) into editable `CustomLyricEntry` rows.
    public static func entries(from document: TrackLyricsDocument, trackDuration: TimeInterval) -> [CustomLyricEntry] {
        var result: [CustomLyricEntry] = []
        let lines = document.syncedLines
        for idx in 0..<lines.count {
            let line = lines[idx]
            if line.isInstrumental {
                let nextTS = (idx + 1 < lines.count)
                    ? lines[idx + 1].timestamp
                    : max(trackDuration, line.timestamp + 5.0)
                let inferredDur = line.explicitDuration ?? max(2.0, min(30.0, nextTS - line.timestamp))
                result.append(
                    CustomLyricEntry(
                        kind: .pause,
                        timestamp: line.timestamp,
                        primaryText: "",
                        secondaryText: nil,
                        pauseDuration: inferredDur
                    )
                )
            } else {
                result.append(
                    CustomLyricEntry(
                        kind: .lyric,
                        timestamp: line.timestamp,
                        primaryText: line.text,
                        secondaryText: line.secondaryText
                    )
                )
            }
        }
        return result
    }

    /// Parses pasted multi-line lyrics into ready-to-time entries (supports `Текст 1 || Текст 2` and `•••` / `пауза`).
    public static func parseBulkLines(
        _ rawText: String,
        startingAt startTime: TimeInterval,
        stepSeconds: TimeInterval = 3.5
    ) -> [CustomLyricEntry] {
        let rawLines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var entries: [CustomLyricEntry] = []
        var cursor = max(0, startTime)
        for raw in rawLines {
            let lower = raw.lowercased()
            if LRCParser.isInstrumentalMarker(raw) || lower == "пауза" || lower == "pause" {
                entries.append(CustomLyricEntry(kind: .pause, timestamp: cursor, pauseDuration: 5.0))
                cursor += 5.0
            } else if raw.contains(dualTextSeparator) {
                let parts = raw.components(separatedBy: dualTextSeparator)
                let first = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let second = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(CustomLyricEntry(kind: .lyric, timestamp: cursor, primaryText: first, secondaryText: second))
                cursor += stepSeconds
            } else {
                entries.append(CustomLyricEntry(kind: .lyric, timestamp: cursor, primaryText: raw))
                cursor += stepSeconds
            }
        }
        return entries
    }

    public static func formatLRCTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let secs = clamped - Double(mins * 60)
        return String(format: "[%02d:%05.2f]", mins, secs)
    }

    public static func formatDisplayTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let rem = clamped - Double(mins * 60)
        return String(format: "%d:%04.1f", mins, rem)
    }
}

// MARK: - Full Interactive Manual Lyrics Creator Studio

public struct CustomLyricsStudioSheet: View {
    public let track: UniversalTrack

    @ObservedObject private var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject private var clock: PlaybackClock = .shared
    @ObservedObject private var lyricsService: LyricsService = .shared
    @ObservedObject private var persistence: PersistenceController = .shared
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [CustomLyricEntry] = []
    @State private var editingEntry: CustomLyricEntry? = nil
    @State private var isCreatingNewEntry: Bool = false
    @State private var initialDualTextEnabled: Bool = false
    @State private var showBulkPasteSheet: Bool = false
    @State private var bulkPasteText: String = ""
    @State private var isTapSyncMode: Bool = false
    @State private var tapSyncCursorIndex: Int = 0
    @State private var isScrubbingMiniBar: Bool = false
    @State private var scrubDisplayTime: Double = 0

    public init(track: UniversalTrack) {
        self.track = track
    }

    private var rawTotalDuration: TimeInterval {
        if player.currentTrack?.id == track.id, clock.duration > 5 {
            return clock.duration
        }
        return max(track.duration, 30.0)
    }

    private var activeTrim: TrackTrimRange? {
        guard let saved = persistence.trimRange(for: track),
              saved.isEffectivelyTrimmed(for: rawTotalDuration) else {
            return nil
        }
        return saved.normalized(for: rawTotalDuration)
    }

    private var trimStart: TimeInterval {
        activeTrim?.startSeconds ?? 0
    }

    private var displayTotalDuration: TimeInterval {
        activeTrim?.effectiveDuration(for: rawTotalDuration) ?? rawTotalDuration
    }

    private var currentRawTime: TimeInterval {
        (player.currentTrack?.id == track.id) ? clock.currentTime : trimStart
    }

    private var currentDisplayTime: TimeInterval {
        max(0, min(displayTotalDuration, currentRawTime - trimStart))
    }

    private var activeEntryID: UUID? {
        let now = currentRawTime + 0.15
        var matched: CustomLyricEntry? = nil
        for entry in entries {
            if entry.timestamp <= now {
                matched = entry
            } else {
                break
            }
        }
        return matched?.id
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                liveAudioControlDeck

                Divider()

                quickCreationToolbar

                if isTapSyncMode && !entries.isEmpty {
                    tapSyncActionBanner
                }

                Divider()

                if entries.isEmpty {
                    emptyStudioPlaceholder
                } else {
                    entriesTimelineList
                }
            }
            .navigationTitle("Редактор лирики")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        saveCustomLyricsAndDismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AuraTheme.accentPink)
                    .disabled(entries.isEmpty)
                }
            }
            .onAppear {
                loadInitialEntries()
            }
            .sheet(item: $editingEntry) { target in
                CustomLyricEntryEditorSheet(
                    entry: target,
                    isNew: isCreatingNewEntry,
                    defaultDualTextEnabled: initialDualTextEnabled,
                    trimStart: trimStart,
                    displayTotalDuration: displayTotalDuration,
                    currentRawTimeProvider: { currentRawTime },
                    onPreviewAt: { rawTime in
                        ensureTrackPlayingAndSeek(to: rawTime)
                    },
                    onSave: { updated in
                        upsertEntry(updated)
                        editingEntry = nil
                        isCreatingNewEntry = false
                        initialDualTextEnabled = false
                    },
                    onDelete: {
                        entries.removeAll { $0.id == target.id }
                        editingEntry = nil
                        isCreatingNewEntry = false
                        initialDualTextEnabled = false
                    }
                )
            }
            .sheet(isPresented: $showBulkPasteSheet) {
                bulkPasteSheetView
            }
        }
    }

    // MARK: - 1. Sticky Live Audio Player Deck (Trim-Aware Time!)

    private var liveAudioControlDeck: some View {
        let shownTime = isScrubbingMiniBar ? scrubDisplayTime : currentDisplayTime
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                AuraArtworkView(url: persistence.effectiveArtworkURL(for: track), size: 38, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(CustomLyricsDocumentBuilder.formatDisplayTimestamp(shownTime)) / \(TrackTrimRange.formatClock(displayTotalDuration))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.accentPink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AuraTheme.accentPink.opacity(0.14)))
            }

            Slider(
                value: Binding(
                    get: { isScrubbingMiniBar ? scrubDisplayTime : currentDisplayTime },
                    set: { newDisplay in
                        isScrubbingMiniBar = true
                        scrubDisplayTime = max(0, min(displayTotalDuration, newDisplay))
                    }
                ),
                in: 0...max(1.0, displayTotalDuration),
                onEditingChanged: { editing in
                    if !editing {
                        let rawTarget = trimStart + scrubDisplayTime
                        ensureTrackPlayingAndSeek(to: rawTarget, forceResume: false)
                        isScrubbingMiniBar = false
                    }
                }
            )
            .tint(AuraTheme.accentPink)

            HStack(spacing: 12) {
                microSeekButton(label: "-3с", delta: -3.0)
                microSeekButton(label: "-1с", delta: -1.0)

                Spacer()

                Button {
                    if player.currentTrack?.id != track.id {
                        player.play(track)
                    } else if player.isPlaying {
                        player.pause()
                    } else {
                        player.resume()
                    }
                } label: {
                    Image(systemName: (player.currentTrack?.id == track.id && player.isPlaying) ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 36)
                        .background(Capsule().fill(AuraTheme.accentPink))
                }
                .buttonStyle(.plain)

                Spacer()

                microSeekButton(label: "+1с", delta: 1.0)
                microSeekButton(label: "+3с", delta: 3.0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func microSeekButton(label: String, delta: TimeInterval) -> some View {
        Button {
            let minRaw = trimStart
            let maxRaw = trimStart + displayTotalDuration
            let target = max(minRaw, min(maxRaw, currentRawTime + delta))
            ensureTrackPlayingAndSeek(to: target, forceResume: false)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2. Quick 1-Tap Action Strip (+ Текст, + 2 текста, + Пауза, Ещё)

    private var quickCreationToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    isCreatingNewEntry = true
                    initialDualTextEnabled = false
                    editingEntry = CustomLyricEntry(
                        kind: .lyric,
                        timestamp: currentRawTime,
                        primaryText: "",
                        secondaryText: nil
                    )
                } label: {
                    Label("Текст", systemImage: "plus.bubble.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(AuraTheme.accentPink))
                }
                .buttonStyle(.plain)

                Button {
                    isCreatingNewEntry = true
                    initialDualTextEnabled = true
                    editingEntry = CustomLyricEntry(
                        kind: .lyric,
                        timestamp: currentRawTime,
                        primaryText: "",
                        secondaryText: nil
                    )
                } label: {
                    Label("2 текста сразу", systemImage: "text.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.purple))
                }
                .buttonStyle(.plain)

                Button {
                    isCreatingNewEntry = true
                    initialDualTextEnabled = false
                    editingEntry = CustomLyricEntry(
                        kind: .pause,
                        timestamp: currentRawTime,
                        pauseDuration: 5.0
                    )
                } label: {
                    Label("Пауза •••", systemImage: "pause.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Button {
                    isTapSyncMode.toggle()
                    if isTapSyncMode {
                        tapSyncCursorIndex = min(tapSyncCursorIndex, max(0, entries.count - 1))
                    } else {
                        sortEntries()
                    }
                } label: {
                    Label(isTapSyncMode ? "Tap-Sync ВКЛ" : "Tap-Sync", systemImage: "hand.tap.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isTapSyncMode ? .white : AuraTheme.accentPink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isTapSyncMode ? Color.green : AuraTheme.accentPink.opacity(0.14)))
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        bulkPasteText = ""
                        showBulkPasteSheet = true
                    } label: {
                        Label("Вставить весь текст списком…", systemImage: "doc.on.clipboard")
                    }

                    if let origDoc = lyricsService.currentDocument, !origDoc.syncedLines.isEmpty {
                        Button {
                            entries = CustomLyricsDocumentBuilder.entries(from: origDoc, trackDuration: rawTotalDuration)
                            sortEntries()
                        } label: {
                            Label("Взять оригинальную лирику за основу", systemImage: "square.and.arrow.down")
                        }
                    }

                    if !entries.isEmpty {
                        Divider()
                        Button {
                            shiftAllTimestamps(by: -0.5)
                        } label: {
                            Label("Сдвинуть всё на -0.5 сек", systemImage: "gobackward")
                        }
                        Button {
                            shiftAllTimestamps(by: 0.5)
                        } label: {
                            Label("Сдвинуть всё на +0.5 сек", systemImage: "goforward")
                        }
                        Divider()
                        Button(role: .destructive) {
                            entries.removeAll()
                            isTapSyncMode = false
                        } label: {
                            Label("Очистить все строки", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 3. Live Tap-to-Sync Banner

    private var tapSyncActionBanner: some View {
        let safeIdx = max(0, min(entries.count - 1, tapSyncCursorIndex))
        let target = entries[safeIdx]
        let previewLabel = target.kind == .pause
            ? "••• Пауза (\(String(format: "%.1f", target.pauseDuration))с)"
            : (target.isDualText ? "\(target.primaryText) / \(target.secondaryText ?? "")" : target.primaryText)

        return VStack(spacing: 8) {
            HStack {
                Text("Строка \(safeIdx + 1) из \(entries.count): \(previewLabel)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("С начала") { tapSyncCursorIndex = 0 }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AuraTheme.accentPink)
            }

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                entries[safeIdx].timestamp = currentRawTime
                if safeIdx + 1 < entries.count {
                    tapSyncCursorIndex = safeIdx + 1
                } else {
                    isTapSyncMode = false
                    sortEntries()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stopwatch.fill")
                    Text("Поставить метку (\(CustomLyricsDocumentBuilder.formatDisplayTimestamp(currentDisplayTime))) → далее")
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.green))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 4. Empty State & Timeline List

    private var emptyStudioPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(AuraTheme.accentPink)
            Text("Создайте свою лирику")
                .font(.system(size: 20, weight: .bold))
            Text("Включите песню сверху и нажимайте «+ Текст», «+ 2 текста сразу» или «+ Пауза •••» в нужный момент. Можно также вставить готовый текст списком и расставить время одним нажатием.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button {
                    bulkPasteText = ""
                    showBulkPasteSheet = true
                } label: {
                    Label("Вставить текст", systemImage: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                if let origDoc = lyricsService.currentDocument, !origDoc.syncedLines.isEmpty {
                    Button {
                        entries = CustomLyricsDocumentBuilder.entries(from: origDoc, trackDuration: rawTotalDuration)
                        sortEntries()
                    } label: {
                        Label("Из оригинала", systemImage: "square.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AuraTheme.accentPink))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var entriesTimelineList: some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isPlayingNow = (activeEntryID == entry.id)
                let isTapTarget = isTapSyncMode && index == tapSyncCursorIndex
                let shownTS = max(0, entry.timestamp - trimStart)

                HStack(alignment: .center, spacing: 10) {
                    // Tappable timestamp pill -> seeks straight to this entry to test sync!
                    Button {
                        ensureTrackPlayingAndSeek(to: entry.timestamp, forceResume: true)
                    } label: {
                        Text(CustomLyricsDocumentBuilder.formatDisplayTimestamp(shownTS))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isPlayingNow ? .white : AuraTheme.accentPink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isPlayingNow ? AuraTheme.accentPink : AuraTheme.accentPink.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)

                    // Content preview (Pause with duration OR Single/Dual Simultaneous Text)
                    VStack(alignment: .leading, spacing: 3) {
                        if entry.kind == .pause {
                            HStack(spacing: 6) {
                                Text("• • •")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(.primary)
                                Text("Пауза \(String(format: "%.1f", entry.pauseDuration)) сек")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            HStack(spacing: 8) {
                                Button("-0.5с") {
                                    adjustPauseDuration(id: entry.id, delta: -0.5)
                                }
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .buttonStyle(.plain)

                                Button("+0.5с") {
                                    adjustPauseDuration(id: entry.id, delta: 0.5)
                                }
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .buttonStyle(.plain)
                            }
                        } else {
                            Text(entry.primaryText.isEmpty ? "(пустая строка)" : entry.primaryText)
                                .font(.system(size: 15, weight: isPlayingNow ? .bold : .semibold))
                                .foregroundStyle(isPlayingNow ? AuraTheme.accentPink : .primary)
                                .lineLimit(2)

                            if let sec = entry.secondaryText, !sec.isEmpty {
                                HStack(spacing: 5) {
                                    Text("2×")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.purple))
                                    Text(sec)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.purple)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isTapSyncMode {
                            tapSyncCursorIndex = index
                        } else {
                            isCreatingNewEntry = false
                            initialDualTextEnabled = false
                            editingEntry = entry
                        }
                    }

                    // 1-Tap "Stamp Current Time Here" button
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                            entries[idx].timestamp = currentRawTime
                            sortEntries()
                        }
                    } label: {
                        Image(systemName: "stopwatch")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
                .listRowBackground(
                    isTapTarget
                        ? Color.green.opacity(0.14)
                        : (isPlayingNow ? AuraTheme.accentPink.opacity(0.08) : Color.clear)
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        var copy = entry
                        copy.id = UUID()
                        copy.timestamp = min(trimStart + displayTotalDuration, entry.timestamp + (entry.kind == .pause ? entry.pauseDuration : 2.5))
                        upsertEntry(copy)
                    } label: {
                        Label("Копия", systemImage: "plus.square.on.square")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 5. Bulk Paste Sheet

    private var bulkPasteSheetView: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Вставьте строки песни (каждая с новой строки). Чтобы сделать два текста одновременно, напишите их через `||`, например:\n`I got love || (окутала меня)`\nДля паузы напишите `•••` или `пауза`.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                TextEditor(text: $bulkPasteText)
                    .font(.system(size: 15))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .padding(.horizontal, 16)

                Spacer()
            }
            .navigationTitle("Вставить текст списком")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showBulkPasteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить и синхронизировать") {
                        let startTS = entries.last.map { $0.timestamp + 3.0 } ?? currentRawTime
                        let parsed = CustomLyricsDocumentBuilder.parseBulkLines(bulkPasteText, startingAt: startTS)
                        entries.append(contentsOf: parsed)
                        sortEntries()
                        if !entries.isEmpty {
                            isTapSyncMode = true
                            tapSyncCursorIndex = max(0, entries.count - parsed.count)
                        }
                        showBulkPasteSheet = false
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AuraTheme.accentPink)
                    .disabled(bulkPasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadInitialEntries() {
        if let existingCustom = lyricsService.loadCachedCustomLyrics(for: track) {
            entries = CustomLyricsDocumentBuilder.entries(from: existingCustom, trackDuration: rawTotalDuration)
            sortEntries()
        }
    }

    private func upsertEntry(_ updated: CustomLyricEntry) {
        if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[idx] = updated
        } else {
            entries.append(updated)
        }
        sortEntries()
    }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            if abs(lhs.timestamp - rhs.timestamp) > 0.005 {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func adjustPauseDuration(id: UUID, delta: TimeInterval) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].pauseDuration = max(1.0, min(60.0, entries[idx].pauseDuration + delta))
    }

    private func shiftAllTimestamps(by delta: TimeInterval) {
        for idx in entries.indices {
            entries[idx].timestamp = max(trimStart, entries[idx].timestamp + delta)
        }
        sortEntries()
    }

    private func ensureTrackPlayingAndSeek(to rawTime: TimeInterval, forceResume: Bool = true) {
        if player.currentTrack?.id != track.id {
            player.play(track)
        }
        player.seek(to: max(0, rawTime))
        if forceResume && !player.isPlaying {
            player.resume()
        }
    }

    private func saveCustomLyricsAndDismiss() {
        let lrc = CustomLyricsDocumentBuilder.buildLRC(from: entries)
        if let doc = lyricsService.saveCustomLyrics(syncedLRC: lrc, for: track) {
            lyricsService.setActiveCustomDocument(doc)
            lyricsService.setPreferredLyricsMode(.custom, for: track)
            OfflineDownloadManager.shared.notifyLyricsChanged(for: track)
        }
        dismiss()
    }
}

// MARK: - Detailed Single Entry Editor (Start Time ±0.1s, Pause Length, Dual Simultaneous Text)

private struct CustomLyricEntryEditorSheet: View {
    let isNew: Bool
    let trimStart: TimeInterval
    let displayTotalDuration: TimeInterval
    let currentRawTimeProvider: () -> TimeInterval
    let onPreviewAt: (TimeInterval) -> Void
    let onSave: (CustomLyricEntry) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var entryID: UUID
    @State private var kind: CustomLyricEntry.Kind
    @State private var displayTimestamp: Double
    @State private var primaryText: String
    @State private var enableDualText: Bool
    @State private var secondaryText: String
    @State private var pauseDuration: Double

    init(
        entry: CustomLyricEntry,
        isNew: Bool,
        defaultDualTextEnabled: Bool = false,
        trimStart: TimeInterval,
        displayTotalDuration: TimeInterval,
        currentRawTimeProvider: @escaping () -> TimeInterval,
        onPreviewAt: @escaping (TimeInterval) -> Void,
        onSave: @escaping (CustomLyricEntry) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.isNew = isNew
        self.trimStart = trimStart
        self.displayTotalDuration = displayTotalDuration
        self.currentRawTimeProvider = currentRawTimeProvider
        self.onPreviewAt = onPreviewAt
        self.onSave = onSave
        self.onDelete = onDelete
        _entryID = State(initialValue: entry.id)
        _kind = State(initialValue: entry.kind)
        _displayTimestamp = State(initialValue: max(0, min(displayTotalDuration, entry.timestamp - trimStart)))
        _primaryText = State(initialValue: entry.primaryText)
        let hasDual = defaultDualTextEnabled || (entry.secondaryText != nil)
        _enableDualText = State(initialValue: hasDual)
        _secondaryText = State(initialValue: (entry.secondaryText ?? "").trimmingCharacters(in: .whitespaces))
        _pauseDuration = State(initialValue: max(1.0, entry.pauseDuration))
    }

    private var canSave: Bool {
        if kind == .pause { return true }
        return !primaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (enableDualText && !secondaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Тип элемента") {
                    Picker("Тип", selection: $kind) {
                        Text("Текст песни").tag(CustomLyricEntry.Kind.lyric)
                        Text("Пауза • • •").tag(CustomLyricEntry.Kind.pause)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Время появления: \(CustomLyricsDocumentBuilder.formatDisplayTimestamp(displayTimestamp))") {
                    Slider(
                        value: $displayTimestamp,
                        in: 0...max(1.0, displayTotalDuration)
                    )
                    .tint(AuraTheme.accentPink)

                    HStack(spacing: 8) {
                        stepTimeButton("-1с", delta: -1.0)
                        stepTimeButton("-0.1с", delta: -0.1)
                        stepTimeButton("+0.1с", delta: 0.1)
                        stepTimeButton("+1с", delta: 1.0)
                    }

                    HStack {
                        Button {
                            let cur = max(0, min(displayTotalDuration, currentRawTimeProvider() - trimStart))
                            displayTimestamp = cur
                        } label: {
                            Label("Взять текущее время", systemImage: "stopwatch.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AuraTheme.accentPink)
                        }

                        Spacer()

                        Button {
                            onPreviewAt(max(trimStart, trimStart + displayTimestamp - 0.8))
                        } label: {
                            Label("Прослушать", systemImage: "play.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                }

                if kind == .pause {
                    Section {
                        HStack {
                            Text("Длительность паузы")
                            Spacer()
                            Text("\(String(format: "%.1f", pauseDuration)) сек")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AuraTheme.accentPink)
                        }

                        Slider(value: $pauseDuration, in: 1.0...45.0, step: 0.5)
                            .tint(AuraTheme.accentPink)

                        HStack(spacing: 8) {
                            ForEach([3.0, 5.0, 8.0, 12.0, 15.0], id: \.self) { preset in
                                Button("\(Int(preset))с") {
                                    pauseDuration = preset
                                }
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        abs(pauseDuration - preset) < 0.2
                                            ? AuraTheme.accentPink
                                            : Color.primary.opacity(0.08)
                                    )
                                )
                                .foregroundStyle(abs(pauseDuration - preset) < 0.2 ? .white : .primary)
                                .buttonStyle(.plain)
                            }
                        }

                        let endDisp = min(displayTotalDuration, displayTimestamp + pauseDuration)
                        Text("Точки • • • будут заполняться с \(CustomLyricsDocumentBuilder.formatDisplayTimestamp(displayTimestamp)) до \(CustomLyricsDocumentBuilder.formatDisplayTimestamp(endDisp))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Настройка паузы • • •")
                    }
                } else {
                    Section("Текст строки") {
                        TextField("Основной текст (например: Окутала меня)", text: $primaryText, axis: .vertical)
                            .lineLimit(1...3)

                        Toggle(isOn: $enableDualText.animation(.easeInOut(duration: 0.2))) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Два текста одновременно")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Дуэт, бэк-вокал, эдлиб или второй язык в ту же секунду")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(Color.purple)

                        if enableDualText {
                            TextField("Второй текст одновременно (например: I got love)", text: $secondaryText, axis: .vertical)
                                .lineLimit(1...3)
                                .foregroundStyle(Color.purple)
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Удалить этот элемент", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? (kind == .pause ? "Новая пауза" : "Новая строка") : "Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        let built = CustomLyricEntry(
                            id: entryID,
                            kind: kind,
                            timestamp: trimStart + displayTimestamp,
                            primaryText: primaryText,
                            secondaryText: enableDualText ? secondaryText : nil,
                            pauseDuration: pauseDuration
                        )
                        onSave(built)
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AuraTheme.accentPink)
                    .disabled(!canSave)
                }
            }
        }
    }

    private func stepTimeButton(_ title: String, delta: TimeInterval) -> some View {
        Button(title) {
            displayTimestamp = max(0, min(displayTotalDuration, displayTimestamp + delta))
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .buttonStyle(.plain)
    }
}
