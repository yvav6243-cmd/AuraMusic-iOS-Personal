import AVFoundation
import Combine
import MediaPlayer
import QuartzCore
import WebKit
import XCTest
@testable import AuraMusic

final class AuraMusicCoreTests: XCTestCase {
    // MARK: - Core Provider & URL Tests

    func testCrossProviderTrackGroupingAndMatching() {
        let matcher = TrackMatchingEngine()

        let appleTrack = UniversalTrack(
            provider: .appleMusic,
            providerTrackID: "am-101",
            title: "Starboy (feat. Daft Punk)",
            artist: "The Weeknd",
            album: "Starboy",
            duration: 230,
            isrc: "USUG11600976",
            isStreamable: false
        )

        let audiusTrack = UniversalTrack(
            provider: .audius,
            providerTrackID: "au-202",
            title: "Starboy [Official Audio]",
            artist: "The Weeknd & Daft Punk",
            album: "Starboy",
            duration: 231,
            streamURL: URL(string: "https://discoveryprovider.audius.co/v1/tracks/au-202/stream"),
            isStreamable: true,
            isDownloadPermitted: true
        )

        let spotifyTrack = UniversalTrack(
            provider: .spotify,
            providerTrackID: "sp-303",
            title: "Starboy",
            artist: "The Weeknd, Daft Punk",
            album: "Starboy",
            duration: 230,
            isrc: "USUG11600976"
        )

        let groups = matcher.groupMatchingTracks([appleTrack, audiusTrack, spotifyTrack])
        XCTAssertEqual(groups.count, 1, "Same song across Apple Music, Audius, and Spotify should be grouped into one result")
        XCTAssertEqual(groups[0].variants.count, 3)
        XCTAssertEqual(groups[0].bestPlayableVariant.provider, .audius, "Best playable variant should prioritize full direct audio stream")
    }

    func testMillisecondSyncedLRCParserAndOriginalLanguagePreservation() {
        let sampleJapaneseLRC = """
        [00:12.40]沈むように溶けてゆくように
        [00:16.85]二人だけの空が広がる夜に // In the night where a sky just for the two of us spreads
        [01:04.05]「さよなら」だけだった
        """

        let parsed = LRCParser.parseSyncedLRC(sampleJapaneseLRC)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].timestamp, 12.40, accuracy: 0.01)
        XCTAssertEqual(parsed[0].text, "沈むように溶けてゆくように")
        XCTAssertEqual(parsed[1].text, "二人だけの空が広がる夜に", "Original Japanese script must never be replaced by translation")
        XCTAssertEqual(parsed[1].translatedText, "In the night where a sky just for the two of us spreads")
        XCTAssertEqual(parsed[2].timestamp, 64.05, accuracy: 0.01)
    }

    func testAppleMusicSharedPlaylistURLParser() throws {
        let importer = AppleMusicPlaylistImporter()

        let parsedUS = try importer.parseAppleMusicPlaylistURL("https://music.apple.com/us/playlist/example/123456789")
        XCTAssertEqual(parsedUS.storefront, "us")
        XCTAssertEqual(parsedUS.playlistID, "123456789")
        XCTAssertEqual(parsedUS.slugName, "example")

        let parsedJP = try importer.parseAppleMusicPlaylistURL("https://music.apple.com/jp/playlist/j-pop-now/pl.f4d106fed2bd41149aaacabb233eb5eb")
        XCTAssertEqual(parsedJP.storefront, "jp")
        XCTAssertEqual(parsedJP.playlistID, "pl.f4d106fed2bd41149aaacabb233eb5eb")
        XCTAssertEqual(parsedJP.slugName, "j-pop-now")
    }

    // MARK: - Exhaustive Lyrics Highlight & Pause Dots Sync Tests

    func testIntroDotsToFirstSungLineSeamlessTransition() {
        let russianLRC = """
        [00:14.84] Подо мной M5, Asphalt 8 (воу)
        [00:16.23] У неё Birkin цвета осень (воу)
        [00:17.97] Она закурит, но я бросил (воу)
        """
        let lines = LRCParser.parseSyncedLRC(russianLRC, includeIntroDots: true)
        XCTAssertEqual(lines.count, 4, "Should insert one clean intro dots row at index 0")
        XCTAssertTrue(lines[0].isInstrumental)
        XCTAssertEqual(lines[0].timestamp, 0.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "Подо мной M5, Asphalt 8 (воу)")

        // During intro (t = 0.0 .. 14.50), index 0 (intro dots) MUST be active and dots progress 0 -> 1 -> 2 -> 3
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 0.0, in: lines), 0)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 0.0, forLineAt: 0, in: lines, trackDuration: 136), 0)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 4.5, forLineAt: 0, in: lines, trackDuration: 136), 1)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 9.0, forLineAt: 0, in: lines, trackDuration: 136), 2)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 13.0, forLineAt: 0, in: lines, trackDuration: 136), 3)

        // Exact transition out of intro dots onto first sung line (at 14.84 - 0.25 = 14.59s)
        let firstLitIndex = LyricSynchronizationEngine.activeLineIndex(at: 14.60, in: lines)
        XCTAssertEqual(firstLitIndex, 1, "First sung line MUST light up immediately after intro dots")
        let row1State = LyricSynchronizationEngine.rowVisualState(forLineAt: 1, activeIndex: firstLitIndex, currentTime: 14.60, in: lines, trackDuration: 136)
        XCTAssertTrue(row1State.isCurrent, "First sung line must be lit (isCurrent == true)")
        XCTAssertFalse(row1State.isPast)

        // Check right at and after exact timestamp (14.84s, 15.10s, 15.80s) — must NEVER drop to nil or revert to dots!
        for t in [14.84, 15.0, 15.5, 15.9] {
            let idx = LyricSynchronizationEngine.activeLineIndex(at: t, in: lines)
            XCTAssertEqual(idx, 1, "Line 1 must remain lit at t=\(t)")
        }

        // Transitions cleanly to line 2
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 16.05, in: lines), 2)
    }

    func testMidSongPauseDotsToNextSungLineNeverDropsHighlight() {
        let macanStyleLRC = """
        [00:14.84] Подо мной M5, Asphalt 8 (воу)
        [00:59.19] Ice занижает градус в роксе (у, а-а)
        [01:03.59]
        [01:17.05] Не меняю душу на пачки лавэ (воу)
        [01:18.69] Пацаны меняют кузовы чёрных BMW
        [01:20.35] Наши везде, наши в LA
        [02:02.97]
        """
        let lines = LRCParser.parseSyncedLRC(macanStyleLRC, includeIntroDots: true)
        // Expected: [0] intro ••• (0.0), [1] Подо мной (14.84), [2] Ice (59.19), [3] ••• (63.59), [4] Не меняю (77.05), [5] Пацаны (78.69), [6] Наши (80.35)
        // Trailing [02:02.97] empty line MUST be stripped!
        XCTAssertEqual(lines.count, 7)
        XCTAssertTrue(lines[0].isInstrumental)
        XCTAssertTrue(lines[3].isInstrumental)
        XCTAssertFalse(lines.last!.isInstrumental, "Trailing empty LRC tag at end of song must be stripped")
        XCTAssertEqual(lines[4].text, "Не меняю душу на пачки лавэ (воу)")

        // During mid-song pause (63.59 .. 77.05)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 63.40, in: lines), 3)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 64.0, forLineAt: 3, in: lines, trackDuration: 136), 0)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 67.5, forLineAt: 3, in: lines, trackDuration: 136), 1)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 71.5, forLineAt: 3, in: lines, trackDuration: 136), 2)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 75.5, forLineAt: 3, in: lines, trackDuration: 136), 3)

        // Immediately after pause dots end (77.05 - 0.25 = 76.80s): line 4 MUST light up and stay lit!
        for t in [76.85, 77.05, 77.50, 78.20] {
            let idx = LyricSynchronizationEngine.activeLineIndex(at: t, in: lines)
            XCTAssertEqual(idx, 4, "Line immediately after pause dots MUST light up at t=\(t)")
            let state = LyricSynchronizationEngine.rowVisualState(forLineAt: 4, activeIndex: idx, currentTime: t, in: lines, trackDuration: 136)
            XCTAssertTrue(state.isCurrent)
            let pauseState = LyricSynchronizationEngine.rowVisualState(forLineAt: 3, activeIndex: idx, currentTime: t, in: lines, trackDuration: 136)
            XCTAssertFalse(pauseState.isCurrent)
            XCTAssertTrue(pauseState.isPast)
            XCTAssertEqual(pauseState.litDotsCount, 0)
        }

        // Next lines continue seamlessly
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 78.70, in: lines), 5)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 80.50, in: lines), 6)
        // End of song stays lit on final sung line (never drops to trailing dots)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 130.0, in: lines), 6)
    }

    func testMultipleMidSongPausesFullFrameByFrameSimulation() {
        // Real structure of The Weeknd - Blinding Lights with intro + 3 mid-song pauses + trailing empty line
        let blindingLightsLRC = """
        [00:14.15] Yeah
        [00:17.73]
        [00:27.85] I've been tryna call
        [00:30.65] I've been on my own for long enough
        [00:33.38] Maybe you can show me how to love, maybe
        [01:26.41]
        [01:35.03] I'm running out of time
        [01:37.80] 'Cause I can see the sun light up the sky
        [02:44.86]
        [02:52.77] (Hey, hey, hey)
        [02:56.00] I said, ooh, I'm blinded by the lights
        [03:18.00]
        """
        let lines = LRCParser.parseSyncedLRC(blindingLightsLRC, includeIntroDots: true)
        var visitedIndices = Set<Int>()
        var previousIndex = -1

        // Simulate continuous playback every 50ms from 0.00s to 200.00s
        var t: TimeInterval = 0.0
        while t <= 200.0 {
            let idx = LyricSynchronizationEngine.activeLineIndex(at: t, in: lines)
            XCTAssertNotNil(idx, "Active index must NEVER be nil during playback at t=\(t)")
            if let idx {
                XCTAssertGreaterThanOrEqual(idx, previousIndex, "Highlight index must advance monotonically during forward playback at t=\(t)")
                previousIndex = idx
                visitedIndices.insert(idx)
            }
            t += 0.05
        }

        // Assert EVERY SINGLE line (all intro dots, all 3 pauses, and every single sung line after every pause!) was illuminated!
        XCTAssertEqual(visitedIndices.count, lines.count, "Every single line including lines after intro & all 3 pauses must light up")
    }

    func testEarlyStartSongUnderThreeSecondsHasNoDoubleIntroAndLightsImmediately() {
        let earlyJapaneseLRC = """
        [00:00.58] 無敵の笑顔で荒らすメディア
        [00:03.54] 知りたいその秘密ミステリアス
        [00:06.12] 抜けてるとこさえ彼女のエリア
        """
        let lines = LRCParser.parseSyncedLRC(earlyJapaneseLRC, includeIntroDots: true)
        XCTAssertEqual(lines.count, 3, "Songs starting under 3.0s should NOT insert an intro dot row")
        XCTAssertFalse(lines[0].isInstrumental)

        // Even at t = 0.0, because first lyric starts at 0.58s (<= 1.0s), line 0 pre-lights so start never looks unlit!
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 0.0, in: lines), 0)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 0.60, in: lines), 0)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 3.55, in: lines), 1)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 6.20, in: lines), 2)
    }

    func testLeadingEmptyLinesCollapsedIntoSingleIntroDotsRow() {
        let lrcWithMultipleLeadingEmpty = """
        [00:00.00]
        [00:02.50] ♪
        [00:06.00] ...
        [00:15.00] Первая настоящая строчка
        [00:18.50] Вторая строчка
        """
        let lines = LRCParser.parseSyncedLRC(lrcWithMultipleLeadingEmpty, includeIntroDots: true)
        XCTAssertEqual(lines.count, 3, "Multiple leading empty/symbol lines must collapse into ONE intro dot row")
        XCTAssertTrue(lines[0].isInstrumental)
        XCTAssertEqual(lines[0].timestamp, 0.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "Первая настоящая строчка")
        XCTAssertEqual(lines[1].timestamp, 15.0, accuracy: 0.001)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 14.80, in: lines), 1)
    }

    func testPauseMarkerCollidingWithRealLyricNeverStealsHighlight() {
        // Real-world broken LRC: empty marker at exact same timestamp OR 0.1s after/before a real lyric!
        let collidingLRC = """
        [00:10.00] Line before
        [00:20.00] Line that must light up
        [00:20.00]
        [00:25.00]
        [00:25.15] Second line that must light up
        [00:30.00] Third line
        [00:30.20]
        """
        let lines = LRCParser.parseSyncedLRC(collidingLRC, includeIntroDots: true)
        // None of the colliding empty markers should survive!
        let instrumentalLines = lines.filter { $0.isInstrumental }
        XCTAssertEqual(instrumentalLines.count, 1, "Only the intro dots (0.0 -> 10.0) should remain; colliding pause markers must be dropped")

        XCTAssertEqual(lines[1].text, "Line before")
        XCTAssertEqual(lines[2].text, "Line that must light up")
        XCTAssertEqual(lines[3].text, "Second line that must light up")
        XCTAssertEqual(lines[4].text, "Third line")

        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 20.0, in: lines), 2)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 25.15, in: lines), 3)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 30.25, in: lines), 4)
    }

    func testConsecutiveMidSongPauseMarkersCollapsedToOne() {
        let consecutivePausesLRC = """
        [00:05.00] Verse one
        [00:10.00]
        [00:14.00] ♪
        [00:18.00] (Instrumental)
        [00:24.00] Chorus after long break
        """
        let lines = LRCParser.parseSyncedLRC(consecutivePausesLRC, includeIntroDots: true)
        // [0] intro (0.0), [1] Verse one (5.0), [2] pause ••• (10.0), [3] Chorus (24.0)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[2].isInstrumental)
        XCTAssertEqual(lines[2].timestamp, 10.0, accuracy: 0.01)
        XCTAssertEqual(lines[3].text, "Chorus after long break")

        // Dots span full 10.0 -> 24.0 (14s) seamlessly without resetting midway!
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 10.5, forLineAt: 2, in: lines, trackDuration: 180), 0)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 14.0, forLineAt: 2, in: lines, trackDuration: 180), 1)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 18.0, forLineAt: 2, in: lines, trackDuration: 180), 2)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 22.5, forLineAt: 2, in: lines, trackDuration: 180), 3)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 23.80, in: lines), 3)
    }

    func testMicroPauseBreathMarkersUnderTwoSecondsAreStripped() {
        let microPauseLRC = """
        [00:10.00] First bar
        [00:13.00]
        [00:14.20] Second bar right after short breath
        [00:18.00]
        [00:26.00] Third bar after real 8s instrumental break
        """
        let lines = LRCParser.parseSyncedLRC(microPauseLRC, includeIntroDots: true)
        // [0] intro (0.0), [1] First bar (10.0), [2] Second bar (14.20) [micro-pause stripped!], [3] ••• (18.0), [4] Third bar (26.0)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[1].text, "First bar")
        XCTAssertEqual(lines[2].text, "Second bar right after short breath")
        XCTAssertTrue(lines[3].isInstrumental)
        XCTAssertEqual(lines[4].text, "Third bar after real 8s instrumental break")
    }

    func testDuplicateTimestampSimultaneousLyricsMergedSoNeitherIsSkipped() {
        // Real Eminem - Lose Yourself pattern where two vocals share exact timestamp [02:03.04]
        let duplicateLRC = """
        [02:00.00] Snap back to reality
        [02:03.04] You better
        [02:03.04] The soul's escaping, through this hole that is gaping
        [02:06.10] This world is mine for the taking
        """
        let lines = LRCParser.parseSyncedLRC(duplicateLRC, includeIntroDots: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].text.contains("You better"))
        XCTAssertTrue(lines[1].text.contains("The soul's escaping"))
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 123.04, in: lines), 1)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 126.10, in: lines), 2)
    }

    func testLRCOffsetHeaderAndEnhancedWordTagsAndBOMSafety() {
        let bomAndOffsetLRC = "\u{FEFF}[offset:500]\n[00:10.50] <00:10.50>Hello <00:10.90>world\n[00:15.50] <00:15.50>Next <00:15.80>line"
        let lines = LRCParser.parseSyncedLRC(bomAndOffsetLRC, includeIntroDots: false)
        XCTAssertEqual(lines.count, 2)
        // [offset:500] shifts 10.50 -> 10.00 and 15.50 -> 15.00
        XCTAssertEqual(lines[0].timestamp, 10.0, accuracy: 0.01)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[1].timestamp, 15.0, accuracy: 0.01)
        XCTAssertEqual(lines[1].text, "Next line")
    }

    func testMultiTimestampChorusLinesExpandedAndOrdered() {
        let multiTagLRC = """
        [00:10.00] Verse one
        [00:20.00][00:50.00] Repeated chorus line
        [00:35.00] Verse two
        """
        let lines = LRCParser.parseSyncedLRC(multiTagLRC, includeIntroDots: true)
        XCTAssertEqual(lines.count, 5) // intro + 4 lines
        XCTAssertEqual(lines[1].text, "Verse one")
        XCTAssertEqual(lines[2].text, "Repeated chorus line")
        XCTAssertEqual(lines[2].timestamp, 20.0, accuracy: 0.01)
        XCTAssertEqual(lines[3].text, "Verse two")
        XCTAssertEqual(lines[4].text, "Repeated chorus line")
        XCTAssertEqual(lines[4].timestamp, 50.0, accuracy: 0.01)

        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 20.0, in: lines), 2)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 50.0, in: lines), 4)
    }

    func testScrubbingForwardBackwardAndRestartToZeroNeverSticks() {
        let sampleLRC = """
        [00:12.00] Line 1
        [00:18.00]
        [00:30.00] Line 2 after pause
        [00:36.00] Line 3
        """
        let lines = LRCParser.parseSyncedLRC(sampleLRC, includeIntroDots: true)
        // [0] intro (0.0), [1] Line 1 (12.0), [2] ••• (18.0), [3] Line 2 (30.0), [4] Line 3 (36.0)

        // Jump straight to end
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 40.0, in: lines), 4)
        // Scrub backward into mid-song pause
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 22.0, in: lines), 2)
        XCTAssertEqual(LyricSynchronizationEngine.litDotsCount(at: 22.0, forLineAt: 2, in: lines, trackDuration: 60), 1)
        // Scrub all the way back to 0.0 (start / repeat-one restart)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 0.0, in: lines), 0)
        // Scrub forward right onto line after pause
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 30.0, in: lines), 3)
        // Scrub backward right before pause ends, then step forward 0.5s
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 29.5, in: lines), 2)
        XCTAssertEqual(LyricSynchronizationEngine.activeLineIndex(at: 30.0, in: lines), 3)
    }

    func testYouTubeURLAndSlowedTitleExtractionForLyrics() {
        XCTAssertEqual(
            YouTubeMusicProvider.extractYouTubeVideoID(from: "https://youtu.be/YkY4X_OaF6o?si=test"),
            "YkY4X_OaF6o"
        )
        XCTAssertEqual(
            YouTubeMusicProvider.extractYouTubeVideoID(from: "https://music.youtube.com/watch?v=J7p4bzqLvCw&feature=share"),
            "J7p4bzqLvCw"
        )
        XCTAssertEqual(
            YouTubeMusicProvider.extractYouTubeVideoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )

        let cleaned = LyricsService.extractCleanTitleAndArtist(
            rawTitle: "Miyagi & Эндшпиль feat. Рем Дигга - I Got Love (slowed + reverb) #tiktok",
            rawArtist: "Random Remix Channel"
        )
        XCTAssertEqual(cleaned.title, "I Got Love")
        XCTAssertEqual(cleaned.artist, "Miyagi")
    }

    @MainActor
    func testBackgroundPauseRejectsStalePlayTicksAndAllowsExplicitResume() async throws {
        let engine = UniversalAudioPlayerEngine.shared
        engine.activeYouTubeVideoID = "YkY4X_OaF6o"

        // Simulate playing track at 25.0s
        engine.handleYouTubePlayerEvent(currentTime: 25.0, duration: 277.0, stateCode: 1, userPaused: false, userResumed: true)
        XCTAssertTrue(engine.isPlaying)

        // 1. User taps Pause from Lock Screen / Control Center / Background
        engine.handleYouTubePlayerEvent(currentTime: 25.2, duration: 277.0, stateCode: 2, userPaused: true, userResumed: false)
        XCTAssertFalse(engine.isPlaying, "Background/Lock Screen pause must immediately set isPlaying = false")

        // 2. Stale in-flight JS play tick arriving immediately (< 0.55s) after pause -> must NOT unpause!
        engine.handleYouTubePlayerEvent(currentTime: 25.3, duration: 277.0, stateCode: 1, userPaused: false, userResumed: false)
        XCTAssertFalse(engine.isPlaying, "Immediate stale play tick while user-paused must NEVER resume playback")

        // 3. Explicit Play tap from Lock Screen / Control Center (userResumed: true) -> must resume immediately!
        engine.handleYouTubePlayerEvent(currentTime: 25.4, duration: 277.0, stateCode: 1, userPaused: false, userResumed: true)
        XCTAssertTrue(engine.isPlaying, "Explicit Lock Screen / Control Center Play must resume playback")

        // 4. Direct pause() followed by native WebKit Lock Screen Play after 0.65s -> MUST resume even without userResumed flag!
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        try await Task.sleep(nanoseconds: 650_000_000)
        engine.handleYouTubePlayerEvent(currentTime: 26.0, duration: 277.0, stateCode: 1, userPaused: false, userResumed: false)
        XCTAssertTrue(engine.isPlaying, "Lock Screen Play after >0.6s pause must always resume playback cleanly")

        // 5. Repeat pause -> direct resume() cycle
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.resume()
        XCTAssertTrue(engine.isPlaying, "resume() must always re-enable playback in background")

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testTwoPhaseAudioSessionOptionsAndAllRemoteCommandsEnabled() {
        // Phase 1 (active playback): .mixWithOthers MUST be set so WKWebView WebContent & silent keep-alive
        // NEVER trigger AVAudioSession.interruptionNotification (.began) causing every new song to start paused!
        XCTAssertTrue(
            UniversalAudioPlayerEngine.activePlaybackAudioSessionOptions.contains(.mixWithOthers),
            "Active playback audio session MUST include .mixWithOthers so WKWebView never self-interrupts on startup"
        )
        XCTAssertTrue(UniversalAudioPlayerEngine.activePlaybackAudioSessionOptions.contains(.allowAirPlay))
        XCTAssertTrue(UniversalAudioPlayerEngine.activePlaybackAudioSessionOptions.contains(.allowBluetoothA2DP))

        // Phase 2 (background soft-pause): .mixWithOthers MUST NOT be set so AuraMusic owns MPRemoteCommandCenter
        // and the Lock Screen Play button stays 100% enabled and clickable!
        XCTAssertFalse(
            UniversalAudioPlayerEngine.backgroundPausedLockScreenAudioSessionOptions.contains(.mixWithOthers),
            "Background-paused Lock Screen audio session MUST omit .mixWithOthers so Lock Screen Play stays enabled"
        )
        XCTAssertTrue(UniversalAudioPlayerEngine.backgroundPausedLockScreenAudioSessionOptions.contains(.allowAirPlay))
        XCTAssertTrue(UniversalAudioPlayerEngine.backgroundPausedLockScreenAudioSessionOptions.contains(.allowBluetoothA2DP))

        // Initialize shared engine so remote command center is configured
        _ = UniversalAudioPlayerEngine.shared
        let commands = MPRemoteCommandCenter.shared()
        XCTAssertTrue(commands.playCommand.isEnabled, "Lock Screen Play command MUST be enabled")
        XCTAssertTrue(commands.pauseCommand.isEnabled, "Lock Screen Pause command MUST be enabled")
        XCTAssertTrue(commands.togglePlayPauseCommand.isEnabled, "Toggle Play/Pause command MUST be enabled")
        XCTAssertTrue(commands.nextTrackCommand.isEnabled, "Next Track command MUST be enabled")
        XCTAssertTrue(commands.previousTrackCommand.isEnabled, "Previous Track command MUST be enabled")
        XCTAssertTrue(commands.changePlaybackPositionCommand.isEnabled, "Lock Screen Scrubber command MUST be enabled")
    }

    @MainActor
    func testLockScreenNowPlayingPlaybackStateAndRepeatedPauseResumeCycles() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "YkY4X_OaF6o",
            title: "I Got Love",
            artist: "Miyagi & Эндшпиль",
            album: "I Got Love",
            duration: 277.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        engine.handleYouTubePlayerEvent(currentTime: 42.0, duration: 277.0, stateCode: 1, userPaused: false, userResumed: true)

        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)

        // Repeatedly cycle Pause -> Play 5 times (simulating Lock Screen / Control Center / AirPods taps)
        for cycle in 1...5 {
            engine.pause()
            XCTAssertFalse(engine.isPlaying, "Cycle \(cycle): pause() must set isPlaying = false")
            XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused, "Cycle \(cycle): Lock Screen playbackState must be .paused so Play button is enabled")
            XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)

            engine.resume()
            XCTAssertTrue(engine.isPlaying, "Cycle \(cycle): resume() must set isPlaying = true")
            XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing, "Cycle \(cycle): Lock Screen playbackState must flip back to .playing")
            XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        }

        // Verify togglePlayPause() works cleanly in both directions when spaced >= 1.0s apart
        engine.resetPlayPauseCooldownForTesting()
        XCTAssertTrue(engine.togglePlayPause(at: 100.0))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)

        XCTAssertTrue(engine.togglePlayPause(at: 101.2))
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    private final class TestWKNavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    func testBackgroundSoftPauseAndResumeWebKitJSRuntime() async throws {
        // Test the ACTUAL production WKWebView configuration & injected JS bridge on a live iOS Simulator WebView!
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                "<!doctype html><html><head><title>AuraTest</title></head><body><video id='v' playsinline></video></body></html>",
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        // Wait up to 3s for atDocumentEnd bridge script to finalize if needed
        var bridgeReady = false
        for _ in 0..<15 {
            if let ready = try? await webView.evaluateJavaScript("typeof window.auraControl === 'object' && typeof window.auraControl.pauseInBackground === 'function' && typeof window.auraControl.resume === 'function'") as? Bool,
               ready {
                bridgeReady = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(bridgeReady, "Production window.auraControl bridge must be installed in WKWebView")

        // 1. Enter background and trigger pauseInBackground() -> MUST natively mute & mark soft-paused
        let pauseState = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.enterBackground(1200);
          window.auraControl.pauseInBackground();
          var v = document.querySelector('video');
          return {
            inBg: window._auraAppInBackground === true,
            softPaused: window._auraSoftPaused === true,
            userPaused: window._auraUserPaused === true,
            realMuted: window._auraOrigMutedDesc ? window._auraOrigMutedDesc.get.call(v) : false,
            rate: v ? v.playbackRate : -1
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(pauseState?["inBg"] as? Bool, true)
        XCTAssertEqual(pauseState?["softPaused"] as? Bool, true)
        XCTAssertEqual(pauseState?["userPaused"] as? Bool, true)
        XCTAssertEqual(pauseState?["realMuted"] as? Bool, true, "pauseInBackground MUST silence <video> natively via origMutedDesc")
        XCTAssertEqual(pauseState?["rate"] as? Double ?? -1, 0.25, accuracy: 0.01)

        // 2. Trigger resume() while still in background -> MUST unmute, restore 1.0x playbackRate, and clear soft-pause!
        let resumeState = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.resume();
          var v = document.querySelector('video');
          return {
            softPaused: window._auraSoftPaused === true,
            userPaused: window._auraUserPaused === true,
            realMuted: window._auraOrigMutedDesc ? window._auraOrigMutedDesc.get.call(v) : true,
            rate: v ? v.playbackRate : -1
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(resumeState?["softPaused"] as? Bool, false)
        XCTAssertEqual(resumeState?["userPaused"] as? Bool, false)
        XCTAssertEqual(resumeState?["realMuted"] as? Bool, false, "resume() MUST unmute <video> natively")
        XCTAssertEqual(resumeState?["rate"] as? Double ?? -1, 1.0, accuracy: 0.01)

        // 3. Pause again in background, then return to foreground -> MUST cleanly exit soft-pause while staying paused!
        let fgState = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.pauseInBackground();
          window.auraControl.enterForeground();
          var v = document.querySelector('video');
          return {
            inBg: window._auraAppInBackground === true,
            softPaused: window._auraSoftPaused === true,
            userPaused: window._auraUserPaused === true,
            realMuted: window._auraOrigMutedDesc ? window._auraOrigMutedDesc.get.call(v) : true,
            rate: v ? v.playbackRate : -1
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(fgState?["inBg"] as? Bool, false)
        XCTAssertEqual(fgState?["softPaused"] as? Bool, false)
        XCTAssertEqual(fgState?["userPaused"] as? Bool, true)
        XCTAssertEqual(fgState?["realMuted"] as? Bool, false)
        XCTAssertEqual(fgState?["rate"] as? Double ?? -1, 1.0, accuracy: 0.01)
    }

    @MainActor
    func testPlaybackClockDecouplingProducesZeroRootEngineInvalidations() {
        let engine = UniversalAudioPlayerEngine.shared
        var engineChangeCount = 0
        var clockChangeCount = 0

        let engineSub = engine.objectWillChange.sink { _ in
            engineChangeCount += 1
        }
        let clockSub = PlaybackClock.shared.objectWillChange.sink { _ in
            clockChangeCount += 1
        }
        defer {
            engineSub.cancel()
            clockSub.cancel()
        }

        // Simulate 200 playback clock updates (like 40 seconds of continuous playback)
        engine.duration = 240.0
        for step in 1...200 {
            engine.currentTime = Double(step) * 0.2
        }

        XCTAssertEqual(
            engineChangeCount,
            0,
            "High-frequency currentTime/duration ticks MUST NEVER trigger UniversalAudioPlayerEngine.objectWillChange (root cause of SwiftUI lag)"
        )
        XCTAssertGreaterThanOrEqual(clockChangeCount, 200, "PlaybackClock must still emit every time update to scrubber and lyrics")
    }

    // MARK: - Startup Playback & 1-Second Play/Pause Cooldown Tests

    func testPlayPauseCooldownGateAllowsExactlyOncePerSecond() {
        var gate = PlayPauseCooldownGate(cooldownInterval: 1.0)

        XCTAssertTrue(gate.tryConsume(at: 0.0), "First press must always be accepted")
        XCTAssertFalse(gate.tryConsume(at: 0.001), "Press 1ms later must be blocked")
        XCTAssertFalse(gate.tryConsume(at: 0.25), "Press 250ms later must be blocked")
        XCTAssertFalse(gate.tryConsume(at: 0.50), "Press 500ms later must be blocked")
        XCTAssertFalse(gate.tryConsume(at: 0.999), "Press 999ms later must be blocked")

        XCTAssertTrue(gate.tryConsume(at: 1.0), "Press at exact 1.0s mark must be accepted")
        XCTAssertFalse(gate.tryConsume(at: 1.4), "Press 400ms after second press must be blocked")
        XCTAssertFalse(gate.tryConsume(at: 1.999), "Press 999ms after second press must be blocked")
        XCTAssertTrue(gate.tryConsume(at: 2.05), "Press after >=1.0s must be accepted")

        gate.recordAction(at: 5.0)
        XCTAssertFalse(gate.tryConsume(at: 5.8), "recordAction must arm the 1.0s cooldown")
        XCTAssertTrue(gate.tryConsume(at: 6.0), "Action after 1.0s from recordAction must be accepted")

        gate.reset()
        XCTAssertTrue(gate.tryConsume(at: 6.01), "reset() must clear cooldown immediately")
    }

    @MainActor
    func testEngineTogglePlayPauseRespectsOneSecondCooldownAndBlocksRapidDoubleTaps() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "cooldown-test-01",
            title: "Starboy",
            artist: "The Weeknd",
            album: "Starboy",
            duration: 230.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        engine.resetPlayPauseCooldownForTesting()
        XCTAssertTrue(engine.isPlaying)

        // Burst of 5 rapid taps within 1 second: ONLY the very first tap may pause!
        XCTAssertTrue(engine.togglePlayPause(at: 10.0), "First tap at 10.0s must pause")
        XCTAssertFalse(engine.isPlaying)

        for rapidTime in [10.05, 10.25, 10.50, 10.95] {
            XCTAssertFalse(engine.togglePlayPause(at: rapidTime), "Rapid tap at \(rapidTime)s (<1.0s) must be blocked")
            XCTAssertFalse(engine.isPlaying, "Playback state must stay paused during 1s cooldown at \(rapidTime)s")
        }

        // Next tap after >= 1.0s resumes cleanly
        XCTAssertTrue(engine.togglePlayPause(at: 11.05), "Tap at 11.05s (>=1.0s) must resume")
        XCTAssertTrue(engine.isPlaying)

        // Another rapid burst while playing: must NOT pause until 1.0s elapses
        XCTAssertFalse(engine.togglePlayPause(at: 11.20))
        XCTAssertFalse(engine.togglePlayPause(at: 11.99))
        XCTAssertTrue(engine.isPlaying)

        // Tap at 12.10s pauses again
        XCTAssertTrue(engine.togglePlayPause(at: 12.10))
        XCTAssertFalse(engine.isPlaying)

        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testNewSongAlwaysStartsPlayingNeverStartsPausedEvenAfterPreviousTrackWasPaused() {
        let engine = UniversalAudioPlayerEngine.shared
        let trackA = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "startup-track-A",
            title: "Track A",
            artist: "Artist A",
            album: "Album A",
            duration: 210.0,
            isStreamable: true
        )
        let trackB = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "startup-track-B",
            title: "Track B",
            artist: "Artist B",
            album: "Album B",
            duration: 195.0,
            isStreamable: true
        )
        let trackC = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "startup-track-C",
            title: "Track C",
            artist: "Artist C",
            album: "Album C",
            duration: 240.0,
            isStreamable: true
        )

        engine.play(trackA)
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)

        // Starting a new song after being paused MUST immediately start playing (never paused!)
        engine.play(trackB)
        XCTAssertTrue(engine.isPlaying, "New song MUST start with isPlaying = true, never paused")
        XCTAssertEqual(engine.currentTrack?.id, trackB.id)
        XCTAssertEqual(engine.currentTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)

        // Pause Track B, immediately switch to Track C
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.play(trackC)
        XCTAssertTrue(engine.isPlaying, "Switching to Track C from paused state MUST start playing immediately")
        XCTAssertEqual(engine.currentTrack?.id, trackC.id)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testSpuriousAudioSessionInterruptionDuringTrackStartupNeverPausesNewSong() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "startup-interrupt-01",
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            duration: 200.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        XCTAssertTrue(engine.isPlaying)

        // Simulate mediaserverd firing spurious .interruptionNotification (.began) while WKWebView starts audio
        let now = CACurrentMediaTime()
        engine.handleAudioSessionInterruptionBegan(at: now + 0.4)
        XCTAssertTrue(engine.isPlaying, "Spurious interruption 0.4s into track startup MUST NOT pause the new song")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        engine.handleAudioSessionInterruptionBegan(at: now + 1.8)
        XCTAssertTrue(engine.isPlaying, "Spurious interruption 1.8s into track startup MUST NOT pause the new song")

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testRealAudioSessionInterruptionAfterStartupWindowProperlyPausesTrack() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "real-interrupt-01",
            title: "Asphalt 8",
            artist: "MACAN",
            album: "12",
            duration: 136.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        XCTAssertTrue(engine.isPlaying)

        // Simulate a genuine interruption (e.g., incoming phone call) 5 seconds after track start
        engine.handleAudioSessionInterruptionBegan(at: CACurrentMediaTime() + 5.0)
        XCTAssertFalse(engine.isPlaying, "Real audio interruption after startup window MUST pause playback")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)

        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testPlayingNewTrackResetsPlayPauseCooldownImmediately() {
        let engine = UniversalAudioPlayerEngine.shared
        let trackA = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "reset-cd-A",
            title: "Song A",
            artist: "Artist",
            album: "Album",
            duration: 180.0,
            isStreamable: true
        )
        let trackB = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "reset-cd-B",
            title: "Song B",
            artist: "Artist",
            album: "Album",
            duration: 180.0,
            isStreamable: true
        )

        engine.play(trackA)
        engine.resetPlayPauseCooldownForTesting()
        XCTAssertTrue(engine.togglePlayPause(at: 200.0))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.togglePlayPause(at: 200.2), "Cooldown is active on Track A")

        // Playing a brand-new song resets the cooldown immediately
        engine.play(trackB)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.togglePlayPause(at: 200.25), "New song must reset cooldown so user can pause immediately if desired")
        XCTAssertFalse(engine.isPlaying)

        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testDuplicateRemotePauseAndToggleWithinOneSecondNeverDoubleToggles() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "dup-remote-01",
            title: "I Got Love",
            artist: "Miyagi & Эндшпиль",
            album: "I Got Love",
            duration: 277.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        XCTAssertTrue(engine.isPlaying)

        // Pause arrives (e.g., from Lock Screen pauseCommand), then 20ms later a duplicate togglePlayPause arrives
        engine.pause()
        XCTAssertFalse(engine.isPlaying)

        let toggledAgain = engine.togglePlayPause(at: CACurrentMediaTime() + 0.02)
        XCTAssertFalse(toggledAgain, "Duplicate togglePlayPause 20ms after pause() MUST be blocked by 1.0s cooldown")
        XCTAssertFalse(engine.isPlaying, "Song must remain paused and never bounce back to playing")

        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testInitialTransientYouTubePausedTicksBeforeAudioStartsNeverSetIsPlayingFalse() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "transient-yt-01",
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            duration: 243.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        XCTAssertTrue(engine.isPlaying)

        // 1. Unsolicited paused tick at t=0.0 before video starts
        engine.handleYouTubePlayerEvent(currentTime: 0.0, duration: 243.0, stateCode: 2, userPaused: false, userResumed: false)
        XCTAssertTrue(engine.isPlaying, "Transient initial YouTube state=2 at t=0.0 must NOT pause a starting song")

        // 2. Unsolicited paused tick at t=0.25 during ABR quality switch in first 3.0s
        engine.handleYouTubePlayerEvent(currentTime: 0.25, duration: 243.0, stateCode: 2, userPaused: false, userResumed: false)
        XCTAssertTrue(engine.isPlaying, "Transient ABR paused tick within first 3.0s must NOT pause a starting song")

        // 3. Explicit user pause (userPaused: true) MUST STILL pause immediately even during startup
        engine.handleYouTubePlayerEvent(currentTime: 0.30, duration: 243.0, stateCode: 2, userPaused: true, userResumed: false)
        XCTAssertFalse(engine.isPlaying, "Explicit user pause must immediately pause even during startup window")

        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testStalePreviousTrackWebViewMessageNeverPausesNewlyStartedTrack() async throws {
        let engine = UniversalAudioPlayerEngine.shared
        let oldTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "OLD_VID_111",
            title: "Old Track",
            artist: "Artist",
            album: "Album",
            duration: 200.0,
            isStreamable: true
        )
        let newTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "NEW_VID_222",
            title: "New Track",
            artist: "Artist",
            album: "Album",
            duration: 210.0,
            isStreamable: true
        )

        let oldView = AuthorizedYouTubeIFramePlayerView(videoID: oldTrack.providerTrackID)
        let staleCoordinator = oldView.makeCoordinator()
        staleCoordinator.loadedVideoID = oldTrack.providerTrackID

        // User starts New Track
        engine.play(newTrack)
        engine.activeYouTubeVideoID = newTrack.providerTrackID
        XCTAssertTrue(engine.isPlaying)

        // Old WebView emits stale userPaused tick and stale remotePause during teardown
        staleCoordinator.handleBridgePayload([
            "type": "tick",
            "currentTime": 45.0,
            "duration": 200.0,
            "state": 2,
            "userPaused": true,
            "userResumed": false
        ])
        staleCoordinator.handleBridgePayload(["type": "remotePause"])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(engine.isPlaying, "Stale pause messages from a previous track's WebView MUST NEVER pause the new song")
        XCTAssertEqual(engine.activeYouTubeVideoID, newTrack.providerTrackID)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testWebKitStartupPauseProtectionBlocksUnsolicitedPauseButAllowsExplicitUserPause() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                "<!doctype html><html><head><title>StartupTest</title></head><body><video id='v' playsinline></video></body></html>",
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        // Wait for bridge + initial 180ms interval to attach <video> event listeners
        var ready = false
        for _ in 0..<15 {
            if let ok = try? await webView.evaluateJavaScript("typeof window.auraControl === 'object' && document.querySelector('video') && document.querySelector('video')._auraListenersAttached === true") as? Bool,
               ok {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready, "WebKit bridge and video listeners must attach on load")

        // 1. Verify fresh page starts unpaused with active 4s startup protection
        let initialState = try await webView.evaluateJavaScript("""
        (function() {
          return {
            userPaused: window._auraUserPaused === true,
            softPaused: window._auraSoftPaused === true,
            startupProtected: (window._auraStartupProtectUntil || 0) > Date.now()
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(initialState?["userPaused"] as? Bool, false)
        XCTAssertEqual(initialState?["softPaused"] as? Bool, false)
        XCTAssertEqual(initialState?["startupProtected"] as? Bool, true)

        // 2. Simulate unsolicited YouTube ABR/init pause event during startup window -> MUST NOT flip _auraUserPaused!
        let afterGlitchPause = try await webView.evaluateJavaScript("""
        (function() {
          var v = document.querySelector('video');
          v._auraHasPlayedOnce = true;
          v.dispatchEvent(new Event('pause'));
          return {
            userPaused: window._auraUserPaused === true,
            allowPause: window._auraAllowPause === true
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(afterGlitchPause?["userPaused"] as? Bool, false, "Unsolicited startup pause event MUST NOT mark song user-paused")
        XCTAssertEqual(afterGlitchPause?["allowPause"] as? Bool, false)

        // 3. Explicit user pause via window.auraControl.pause() MUST clear startup guard & pause immediately!
        let afterExplicitPause = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.pause();
          return {
            userPaused: window._auraUserPaused === true,
            startupProtectUntil: window._auraStartupProtectUntil || 0
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(afterExplicitPause?["userPaused"] as? Bool, true, "Explicit user pause MUST work immediately even during startup window")
        XCTAssertEqual(afterExplicitPause?["startupProtectUntil"] as? Double ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Regression Tests for Unpause Lockout Bug (Run #78 Root Cause)

    @MainActor
    func testRepeatingPausedHeartbeatsNeverLockPlayPauseCooldownAndUnpauseWorksAfterOneSecond() async throws {
        // EXACT reproduction of Run #78 bug:
        // User pauses song, WebKit sends repeating state=2/userPaused=true ticks every ~150ms,
        // and 1.1s later user taps Play (togglePlayPause) -> MUST SUCCEED and unpause immediately!
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "unpause-regression-01",
            title: "Starboy",
            artist: "The Weeknd",
            album: "Starboy",
            duration: 230.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        engine.resetPlayPauseCooldownForTesting()
        XCTAssertTrue(engine.isPlaying)

        // 1. User taps Pause at real wall time t0
        let t0 = CACurrentMediaTime()
        XCTAssertTrue(engine.togglePlayPause(at: t0), "Initial Pause tap must succeed")
        XCTAssertFalse(engine.isPlaying)

        // 2. Simulate 8 repeating JS paused ticks arriving over 1.2s while paused
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 150_000_000)
            engine.handleYouTubePlayerEvent(
                currentTime: 32.0,
                duration: 230.0,
                stateCode: 2,
                userPaused: true,
                userResumed: false
            )
            XCTAssertFalse(engine.isPlaying)
        }

        // 3. Now (~1.2s after initial Pause) user taps Play -> MUST IMMEDIATELY UNPAUSE!
        let didUnpause = engine.togglePlayPause(at: CACurrentMediaTime())
        XCTAssertTrue(didUnpause, "Repeating paused ticks MUST NEVER lock the 1.0s Play/Pause cooldown!")
        XCTAssertTrue(engine.isPlaying, "Song MUST unpause immediately when tapping Play after >=1.0s")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testStaleInFlightPausedTickImmediatelyAfterResumeNeverSnapsBackToPause() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "inflight-pause-race-01",
            title: "I Got Love",
            artist: "Miyagi & Эндшпиль",
            album: "I Got Love",
            duration: 277.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        engine.pause()
        XCTAssertFalse(engine.isPlaying)

        // User taps Play -> resume() runs
        engine.resume()
        XCTAssertTrue(engine.isPlaying)

        // 20ms later, an in-flight { state: 2, userPaused: true } tick that was queued before resume() arrives!
        engine.handleYouTubePlayerEvent(
            currentTime: 44.0,
            duration: 277.0,
            stateCode: 2,
            userPaused: true,
            userResumed: false
        )
        XCTAssertTrue(engine.isPlaying, "Stale in-flight paused tick right after resume() MUST NEVER snap Play back to Pause")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testRepeatedIdempotentPauseCallsWhileAlreadyPausedNeverExtendOneSecondCooldown() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "idempotent-pause-01",
            title: "Asphalt 8",
            artist: "MACAN",
            album: "12",
            duration: 136.0,
            isStreamable: true
        )

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        engine.resetPlayPauseCooldownForTesting()
        XCTAssertTrue(engine.isPlaying)

        // Pause transitions playing -> paused at t = 50.0s (arms cooldown to 50.0)
        engine.pause(recordCooldownAt: 50.0)
        XCTAssertFalse(engine.isPlaying)

        // Redundant duplicate pause() arrives at t = 50.7s while ALREADY paused -> MUST NOT extend cooldown!
        engine.pause(recordCooldownAt: 50.7)
        XCTAssertFalse(engine.isPlaying)

        // User taps Play at t = 51.05s (>= 1.0s after 50.0s, < 1.0s after 50.7s) -> MUST SUCCEED!
        XCTAssertTrue(
            engine.togglePlayPause(at: 51.05),
            "Idempotent pause() while already paused must NEVER extend the 1.0s cooldown"
        )
        XCTAssertTrue(engine.isPlaying)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testResumeRecoversGracefullyWhenTrackLoadedWithoutActivePlayer() {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "recover-empty-player-01",
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            duration: 200.0,
            isStreamable: true
        )

        engine.play(track)
        engine.pause()
        engine.activeYouTubeVideoID = nil
        XCTAssertFalse(engine.isPlaying)

        // Tapping Play when activeYouTubeVideoID == nil and primaryPlayer has no item must recover & restart playback!
        engine.resume()
        XCTAssertTrue(engine.isPlaying, "resume() must recover and restart track playback when no active player item exists")
        XCTAssertEqual(engine.currentTrack?.id, track.id)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testWebKitPauseDoesNotSpamState2TicksAndResumeClearsUserPausedCleanly() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                "<!doctype html><html><head><title>NoSpamTest</title></head><body><video id='v' playsinline></video></body></html>",
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        var ready = false
        for _ in 0..<15 {
            if let ok = try? await webView.evaluateJavaScript("typeof window.auraControl === 'object' && document.querySelector('video') && document.querySelector('video')._auraListenersAttached === true") as? Bool,
               ok {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready)

        // 1. Trigger pause() and reset counter check
        let countAfterPause = try await webView.evaluateJavaScript("""
        (function() {
          window._auraPausedTickPostCount = 0;
          window.auraControl.pause();
          return window._auraPausedTickPostCount;
        })()
        """) as? Int
        XCTAssertEqual(countAfterPause, 1, "pause() should emit exactly one state=2 transition tick")

        // 2. Wait 600ms (>3 intervals of 180ms) while paused -> count MUST stay 1 (ZERO repeating state=2 spam!)
        try await Task.sleep(nanoseconds: 600_000_000)
        let countAfterWaiting = try await webView.evaluateJavaScript("window._auraPausedTickPostCount") as? Int
        XCTAssertEqual(countAfterWaiting, 1, "180ms WebKit interval MUST NOT spam state=2 ticks while paused")

        // 3. Same check for background soft-pause -> wait 600ms -> STILL ZERO spam!
        let countAfterBgSoftPause = try await webView.evaluateJavaScript("""
        (function() {
          window._auraPausedTickPostCount = 0;
          window.auraControl.enterBackground(1200);
          window.auraControl.pauseInBackground();
          return window._auraPausedTickPostCount;
        })()
        """) as? Int
        XCTAssertEqual(countAfterBgSoftPause, 1)

        try await Task.sleep(nanoseconds: 600_000_000)
        let countAfterBgWaiting = try await webView.evaluateJavaScript("window._auraPausedTickPostCount") as? Int
        XCTAssertEqual(countAfterBgWaiting, 1, "Background soft-pause MUST NOT spam state=2 ticks either")

        // 4. Resume clears _auraUserPaused and _auraSoftPaused cleanly
        let resumed = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.resume();
          var v = document.querySelector('video');
          return {
            userPaused: window._auraUserPaused === true,
            softPaused: window._auraSoftPaused === true,
            realMuted: window._auraOrigMutedDesc ? window._auraOrigMutedDesc.get.call(v) : true,
            rate: v ? v.playbackRate : -1
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(resumed?["userPaused"] as? Bool, false)
        XCTAssertEqual(resumed?["softPaused"] as? Bool, false)
        XCTAssertEqual(resumed?["realMuted"] as? Bool, false)
        XCTAssertEqual(resumed?["rate"] as? Double ?? -1, 1.0, accuracy: 0.01)
    }

    // MARK: - Background Persistence & Lock Screen Previous/Next (No ±5s Skip) Tests

    @MainActor
    func testLockScreenDisablesSkip5SecondsCommandsAndEnablesPreviousNextTrackCommands() {
        _ = UniversalAudioPlayerEngine.shared
        let commands = MPRemoteCommandCenter.shared()

        XCTAssertFalse(commands.skipBackwardCommand.isEnabled, "skipBackwardCommand (±5s/15s) MUST be disabled so Lock Screen shows ⏮ Previous Track")
        XCTAssertFalse(commands.skipForwardCommand.isEnabled, "skipForwardCommand (±5s/15s) MUST be disabled so Lock Screen shows ⏭ Next Track")
        XCTAssertFalse(commands.seekBackwardCommand.isEnabled, "seekBackwardCommand MUST be disabled so Lock Screen shows ⏮ Previous Track")
        XCTAssertFalse(commands.seekForwardCommand.isEnabled, "seekForwardCommand MUST be disabled so Lock Screen shows ⏭ Next Track")

        XCTAssertTrue(commands.previousTrackCommand.isEnabled, "previousTrackCommand (⏮) MUST be enabled on Lock Screen")
        XCTAssertTrue(commands.nextTrackCommand.isEnabled, "nextTrackCommand (⏭) MUST be enabled on Lock Screen")
    }

    @MainActor
    func testBackgroundKeepAliveWAVIsValidAndContainsNonZeroSubAudibleDither() throws {
        let wav = UniversalAudioPlayerEngine.buildSubAudibleKeepAliveWAVData()
        XCTAssertEqual(wav.count, 44 + 44100 * 2 * 2, "WAV must be 2 seconds of 44.1kHz 16-bit mono PCM")
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")

        // Verify PCM payload is NOT all-zero digital silence (so iOS 17/18 mediaserverd never drops background audio assertion)
        let pcmSlice = wav.subdata(in: 44..<wav.count)
        let hasNonZeroEnergy = pcmSlice.contains { $0 != 0 }
        XCTAssertTrue(hasNonZeroEnergy, "Keep-alive WAV MUST contain sub-audible non-zero dither instead of all-zero bytes")

        // Verify AVAudioPlayer parses and prepares it cleanly
        let player = try AVAudioPlayer(data: wav)
        XCTAssertGreaterThan(player.duration, 1.9)
    }

    @MainActor
    func testSwitchingBetweenYouTubeTracksPreservesLiveWebViewWithoutNilTeardown() {
        let engine = UniversalAudioPlayerEngine.shared
        let trackA = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "BG_NEXT_VID_A",
            title: "Track A",
            artist: "Artist A",
            album: "Album",
            duration: 210.0,
            isStreamable: true
        )
        let trackB = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "BG_NEXT_VID_B",
            title: "Track B",
            artist: "Artist B",
            album: "Album",
            duration: 195.0,
            isStreamable: true
        )

        engine.play(trackA, queue: [trackA, trackB])
        engine.activeYouTubeVideoID = trackA.providerTrackID
        XCTAssertEqual(engine.upNextQueue.count, 1)

        // Tap Next Track (⏭): MUST NOT nil out activeYouTubeVideoID (which would destroy WKWebView in background!)
        engine.skipToNext()
        XCTAssertEqual(engine.currentTrack?.id, trackB.id)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNotNil(engine.activeYouTubeVideoID, "Switching between YouTube tracks MUST preserve live WKWebView in background")

        // Tap Previous Track (⏮) when currentTime <= 3.5s: switches cleanly back to Track A without tearing down WKWebView
        engine.currentTime = 1.0
        engine.skipToPrevious()
        XCTAssertEqual(engine.currentTrack?.id, trackA.id)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNotNil(engine.activeYouTubeVideoID)

        engine.pause()
        engine.activeYouTubeVideoID = nil
    }

    @MainActor
    func testWebKitBlocksYouTubeSeekBackwardSeekForwardAndResistsBackgroundPauseSuspension() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                "<!doctype html><html><head><title>BgControlsTest</title></head><body><div id='movie_player'></div><video id='v' playsinline></video></body></html>",
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        var ready = false
        for _ in 0..<15 {
            if let ok = try? await webView.evaluateJavaScript("typeof window.auraControl === 'object' && document.querySelector('video') && document.querySelector('video')._auraListenersAttached === true") as? Bool,
               ok {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready)

        // 1. Simulate YouTube JS attempting to register ±5s seekbackward / seekforward -> MUST be blocked!
        let seekBlockResult = try await webView.evaluateJavaScript("""
        (function() {
          window._auraBlockedSeekActions = 0;
          if (navigator.mediaSession && navigator.mediaSession.setActionHandler) {
            navigator.mediaSession.setActionHandler('seekbackward', function() {});
            navigator.mediaSession.setActionHandler('seekforward', function() {});
          }
          return {
            hasMediaSession: !!(navigator.mediaSession && navigator.mediaSession.setActionHandler),
            blockedSeekCount: window._auraBlockedSeekActions || 0,
            trackControlsRegistered: window._auraRegisteredTrackControls === true
          };
        })()
        """) as? [String: Any]
        if (seekBlockResult?["hasMediaSession"] as? Bool) == true {
            XCTAssertGreaterThanOrEqual(seekBlockResult?["blockedSeekCount"] as? Int ?? 0, 2, "YouTube seekbackward/seekforward (±5s) handlers MUST be blocked")
            XCTAssertEqual(seekBlockResult?["trackControlsRegistered"] as? Bool, true)
        }

        // 2. Enter background, expire _auraBgProtectUntil (simulating 10+ seconds in background), then dispatch unsolicited iOS suspension pause!
        // MUST NOT flip _auraUserPaused = true or turn off background music!
        let bgSurviveResult = try await webView.evaluateJavaScript("""
        (function() {
          var v = document.querySelector('video');
          v._auraHasPlayedOnce = true;
          window.auraControl.enterBackground(8000);
          window._auraBgProtectUntil = 0;
          window._auraStartupProtectUntil = 0;
          v.dispatchEvent(new Event('pause'));
          return {
            inBg: window._auraAppInBackground === true,
            userPaused: window._auraUserPaused === true,
            softPaused: window._auraSoftPaused === true
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(bgSurviveResult?["inBg"] as? Bool, true)
        XCTAssertEqual(bgSurviveResult?["userPaused"] as? Bool, false, "Unsolicited background pause from iOS WebKit MUST NEVER turn off music")
        XCTAssertEqual(bgSurviveResult?["softPaused"] as? Bool, false)

        // 3. Test in-place background track switch via window.auraControl.loadVideo(nextID)
        let inPlaceSwitch = try await webView.evaluateJavaScript("""
        (function() {
          window._loadedById = null;
          var mp = document.getElementById('movie_player');
          mp.loadVideoById = function(id) { window._loadedById = id; };
          window.auraControl.pauseInBackground();
          var switched = window.auraControl.loadVideo('NEXT_TRACK_999');
          return {
            switched: switched === true,
            loadedId: window._loadedById,
            userPaused: window._auraUserPaused === true,
            softPaused: window._auraSoftPaused === true
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(inPlaceSwitch?["switched"] as? Bool, true, "loadVideo must switch tracks in-place via movie_player.loadVideoById")
        XCTAssertEqual(inPlaceSwitch?["loadedId"] as? String, "NEXT_TRACK_999")
        XCTAssertEqual(inPlaceSwitch?["userPaused"] as? Bool, false)
        XCTAssertEqual(inPlaceSwitch?["softPaused"] as? Bool, false)
    }

    // MARK: - Hardware System Volume Slider Tests

    @MainActor
    func testSystemVolumeControllerClampsAndStepsVolumeCleanly() {
        XCTAssertEqual(SystemVolumeController.clampedVolume(-0.4), 0.0, accuracy: 0.0001)
        XCTAssertEqual(SystemVolumeController.clampedVolume(1.8), 1.0, accuracy: 0.0001)
        XCTAssertEqual(SystemVolumeController.clampedVolume(.nan), 0.5, accuracy: 0.0001)

        let mockSlider = UISlider(frame: CGRect(x: 0, y: 0, width: 200, height: 28))
        mockSlider.minimumValue = 0
        mockSlider.maximumValue = 1
        mockSlider.value = 0.5

        let controller = SystemVolumeController.shared
        controller.registerSlider(mockSlider)

        let raised = controller.stepVolume(by: 0.15)
        XCTAssertEqual(raised, 0.65, accuracy: 0.001)
        XCTAssertEqual(mockSlider.value, 0.65, accuracy: 0.001)
        XCTAssertEqual(UniversalAudioPlayerEngine.shared.volume, 0.65, accuracy: 0.001)

        let lowered = controller.stepVolume(by: -0.25)
        XCTAssertEqual(lowered, 0.40, accuracy: 0.001)
        XCTAssertEqual(mockSlider.value, 0.40, accuracy: 0.001)

        // Clamping at boundaries
        XCTAssertEqual(controller.stepVolume(by: 5.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(controller.stepVolume(by: -5.0), 0.0, accuracy: 0.001)

        // Restore clean level
        _ = controller.setSystemVolume(0.8)
    }

    @MainActor
    func testHardwareVolumeSliderContainerLayoutsMPVolumeViewWithCustomTrackAndThumb() {
        let container = AuraSystemVolumeContainerView(frame: CGRect(x: 0, y: 0, width: 280, height: 30))
        container.layoutIfNeeded()

        XCTAssertTrue(container.volumeView.showsVolumeSlider, "MPVolumeView must show the hardware volume slider")
        XCTAssertEqual(container.volumeView.frame.width, 280, accuracy: 0.5)
        XCTAssertEqual(container.volumeView.frame.height, 28, accuracy: 0.5)
        XCTAssertNotNil(container.volumeView.minimumVolumeSliderImage(for: .normal))
        XCTAssertNotNil(container.volumeView.maximumVolumeSliderImage(for: .normal))
        XCTAssertNotNil(container.volumeView.volumeThumbImage(for: .normal))
        XCTAssertNotNil(container.volumeView.volumeThumbImage(for: .highlighted))
    }

    @MainActor
    func testEngineSyncsObservedHardwareVolumeCleanly() {
        let engine = UniversalAudioPlayerEngine.shared
        engine.syncObservedHardwareVolume(0.35)
        XCTAssertEqual(engine.volume, 0.35, accuracy: 0.001)

        engine.syncObservedHardwareVolume(1.5)
        XCTAssertEqual(engine.volume, 1.0, accuracy: 0.001)

        engine.syncObservedHardwareVolume(-0.2)
        XCTAssertEqual(engine.volume, 0.0, accuracy: 0.001)

        engine.syncObservedHardwareVolume(0.85)
    }

    // MARK: - Smooth Zero-Load Scrubber Interpolation Tests

    func testPlaybackClockSmoothInterpolationAdvancesLinearlyAndCapsStallExtrapolation() {
        // Between 250ms ticks, 30 FPS interpolation advances smoothly and linearly
        let t0 = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 100.00, duration: 200.0, isPlaying: true, isBuffering: false)
        let t1 = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 100.05, duration: 200.0, isPlaying: true, isBuffering: false)
        let t2 = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 100.15, duration: 200.0, isPlaying: true, isBuffering: false)
        let t3 = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 100.25, duration: 200.0, isPlaying: true, isBuffering: false)

        XCTAssertEqual(t0, 42.00, accuracy: 0.0001)
        XCTAssertEqual(t1, 42.05, accuracy: 0.0001)
        XCTAssertEqual(t2, 42.15, accuracy: 0.0001)
        XCTAssertEqual(t3, 42.25, accuracy: 0.0001)

        // Caps stall extrapolation at +0.65s so bar never runs away on slow network
        let stalled = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 105.0, duration: 200.0, isPlaying: true, isBuffering: false)
        XCTAssertEqual(stalled, 42.65, accuracy: 0.0001)

        // Clamps cleanly at song duration
        let endClamped = PlaybackClock.computeInterpolatedTime(anchorTime: 199.8, anchorWallTime: 100.0, nowWallTime: 100.5, duration: 200.0, isPlaying: true, isBuffering: false)
        XCTAssertEqual(endClamped, 200.0, accuracy: 0.0001)

        // Freezes immediately when paused or buffering
        let paused = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 100.5, duration: 200.0, isPlaying: false, isBuffering: false)
        XCTAssertEqual(paused, 42.0, accuracy: 0.0001)
        let buffering = PlaybackClock.computeInterpolatedTime(anchorTime: 42.0, anchorWallTime: 100.0, nowWallTime: 100.5, duration: 200.0, isPlaying: true, isBuffering: true)
        XCTAssertEqual(buffering, 42.0, accuracy: 0.0001)
    }

    @MainActor
    func testPlaybackClockRefreshSyncAnchorPreventsJumpAfterLongPause() {
        let clock = PlaybackClock.shared
        clock.duration = 200.0
        clock.currentTime = 50.0
        // Simulate 15 seconds elapsing while paused, then refreshSyncAnchor on resume
        let resumeWall = clock.lastSyncWallTime + 15.0
        clock.refreshSyncAnchor(at: resumeWall)

        let immediateDisplay = clock.interpolatedTime(at: resumeWall + 0.01, isPlaying: true, isBuffering: false)
        XCTAssertEqual(immediateDisplay, 50.01, accuracy: 0.001, "Refreshing sync anchor on resume must prevent any forward jump after long pause")
    }

    @MainActor
    func testPlaybackClockInterpolationProducesZeroObjectWillChangeInvalidations() {
        let engine = UniversalAudioPlayerEngine.shared
        let clock = PlaybackClock.shared
        clock.duration = 240.0
        clock.currentTime = 30.0
        let anchor = clock.lastSyncWallTime

        var engineInvalidations = 0
        var clockInvalidations = 0
        let subEngine = engine.objectWillChange.sink { _ in engineInvalidations += 1 }
        let subClock = clock.objectWillChange.sink { _ in clockInvalidations += 1 }
        defer {
            subEngine.cancel()
            subClock.cancel()
        }

        // Simulate 10 seconds of 30 FPS scrubber rendering (300 frames)
        for frame in 0..<300 {
            let t = anchor + Double(frame) / 30.0
            _ = clock.interpolatedTime(at: t, isPlaying: true, isBuffering: false)
        }

        XCTAssertEqual(engineInvalidations, 0, "Smooth scrubber interpolation must cause ZERO engine invalidations")
        XCTAssertEqual(clockInvalidations, 0, "Smooth scrubber interpolation must cause ZERO clock invalidations")
    }

    // MARK: - 3-Layer YouTube Ad Blocker Tests (WKContentRuleList + JSON Strip + Live Ad Handler)

    @MainActor
    func testYouTubeContentBlockerRulesCompileSuccessfullyInWebKit() async throws {
        // Verify JSON is valid and never blocks song audio endpoints (googlevideo.com / youtubei/v1/player)
        let data = try XCTUnwrap(YouTubeAdBlockerRuleManager.contentBlockerRulesJSON.data(using: .utf8))
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rules.count, 10)
        XCTAssertFalse(YouTubeAdBlockerRuleManager.contentBlockerRulesJSON.contains("googlevideo"), "Must never block googlevideo song audio streams")

        // Actually compile via Apple's native WebKit WKContentRuleListStore on iOS Simulator!
        let compiled = await YouTubeAdBlockerRuleManager.shared.ensureCompiledRuleList()
        XCTAssertNotNil(compiled, "Apple WebKit WKContentRuleListStore MUST compile YouTube ad-blocker rules cleanly with zero errors")
    }

    @MainActor
    func testWebKitStripsYouTubeAdPlacementsFromInitialResponseAndJSONParse() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                """
                <!doctype html><html><head><title>AdStripTest</title></head><body>
                <script>
                var ytInitialPlayerResponse = {
                  videoDetails: { title: "Starboy", videoId: "34Na4j8AVgA" },
                  adPlacements: [{ adPlacementRenderer: { config: "preroll" } }],
                  playerAds: [{ playerLegacyDesktopWatchAdsRenderer: {} }],
                  adSlots: [{ adSlotRenderer: { slot: "midroll" } }],
                  adBreakHeartbeatParams: "secret-ad-token"
                };
                </script>
                <div id='movie_player'></div>
                <video id='v' playsinline></video>
                </body></html>
                """,
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        let result = try await webView.evaluateJavaScript("""
        (function() {
          var parsed = JSON.parse('{"videoDetails":{"title":"Blinding Lights"},"adPlacements":[{"id":1}],"playerAds":[{"id":2}],"adSlots":[{"id":3}],"adBreakHeartbeatParams":"abc"}');
          return {
            initTitle: window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails ? window.ytInitialPlayerResponse.videoDetails.title : '',
            initAdPlacements: window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.adPlacements ? window.ytInitialPlayerResponse.adPlacements.length : -1,
            initPlayerAds: window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.playerAds ? window.ytInitialPlayerResponse.playerAds.length : -1,
            initAdSlots: window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.adSlots ? window.ytInitialPlayerResponse.adSlots.length : -1,
            initHasHeartbeat: !!(window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.adBreakHeartbeatParams),
            parsedTitle: parsed.videoDetails ? parsed.videoDetails.title : '',
            parsedAdPlacements: parsed.adPlacements ? parsed.adPlacements.length : -1,
            parsedPlayerAds: parsed.playerAds ? parsed.playerAds.length : -1,
            parsedAdSlots: parsed.adSlots ? parsed.adSlots.length : -1,
            parsedHasHeartbeat: !!parsed.adBreakHeartbeatParams
          };
        })()
        """) as? [String: Any]

        XCTAssertEqual(result?["initTitle"] as? String, "Starboy", "Real song metadata must remain intact")
        XCTAssertEqual(result?["initAdPlacements"] as? Int, 0)
        XCTAssertEqual(result?["initPlayerAds"] as? Int, 0)
        XCTAssertEqual(result?["initAdSlots"] as? Int, 0)
        XCTAssertEqual(result?["initHasHeartbeat"] as? Bool, false)

        XCTAssertEqual(result?["parsedTitle"] as? String, "Blinding Lights")
        XCTAssertEqual(result?["parsedAdPlacements"] as? Int, 0)
        XCTAssertEqual(result?["parsedPlayerAds"] as? Int, 0)
        XCTAssertEqual(result?["parsedAdSlots"] as? Int, 0)
        XCTAssertEqual(result?["parsedHasHeartbeat"] as? Bool, false)
    }

    @MainActor
    func testWebKitLiveAdDetectorMutesFastForwardsSkipsAndRestoresSongCleanly() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                """
                <!doctype html><html><head><title>LiveAdTest</title></head><body>
                <div id='movie_player' class='ad-showing'>
                  <button class='ytp-ad-skip-button-modern' onclick='window._skipClicked = true;'>Skip</button>
                </div>
                <video id='v' playsinline></video>
                </body></html>
                """,
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        var ready = false
        for _ in 0..<15 {
            if let ok = try? await webView.evaluateJavaScript("typeof window._auraHandleActiveAd === 'function'") as? Bool, ok {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready)

        // 1. Trigger live ad handler while `ad-showing` is active -> MUST mute natively, click Skip, and accelerate to 16x!
        let duringAd = try await webView.evaluateJavaScript("""
        (function() {
          var v = document.querySelector('video');
          var handled = window._auraHandleActiveAd(v);
          return {
            handled: handled === true,
            inAd: window._auraInAd === true,
            skipClicked: window._skipClicked === true,
            realMuted: window._auraOrigMutedDesc ? window._auraOrigMutedDesc.get.call(v) : false,
            rate: v ? v.playbackRate : -1
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(duringAd?["handled"] as? Bool, true)
        XCTAssertEqual(duringAd?["inAd"] as? Bool, true)
        XCTAssertEqual(duringAd?["skipClicked"] as? Bool, true, "Skip ad button must be auto-clicked")
        XCTAssertEqual(duringAd?["realMuted"] as? Bool, true, "Ad audio must be natively muted immediately")
        XCTAssertEqual(duringAd?["rate"] as? Double ?? -1, 16.0, accuracy: 0.01, "Ad must be fast-forwarded at 16x")

        // 2. Ad ends (`ad-showing` & skip button removed) -> MUST immediately unmute and restore 1.0x speed for the real song!
        let afterAd = try await webView.evaluateJavaScript("""
        (function() {
          var mp = document.getElementById('movie_player');
          mp.classList.remove('ad-showing');
          mp.innerHTML = '';
          var v = document.querySelector('video');
          var handled = window._auraHandleActiveAd(v);
          return {
            handled: handled === true,
            inAd: window._auraInAd === true,
            realMuted: window._auraOrigMutedDesc ? window._auraOrigMutedDesc.get.call(v) : true,
            rate: v ? v.playbackRate : -1
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(afterAd?["handled"] as? Bool, false)
        XCTAssertEqual(afterAd?["inAd"] as? Bool, false)
        XCTAssertEqual(afterAd?["realMuted"] as? Bool, false, "Real song must be unmuted immediately once ad finishes")
        XCTAssertEqual(afterAd?["rate"] as? Double ?? -1, 1.0, accuracy: 0.01, "Real song playback rate must return to 1.0x")
    }

    // MARK: - Expanded Chinese & Russian Multi-Provider Lyrics Tests

    func testChineseAndRussianTitleExtractionWithGuillemetsAndBrackets() {
        let jayChou = LyricsService.extractCleanTitleAndArtist(
            rawTitle: "周杰伦《晴天》官方MV",
            rawArtist: "杰威尔音乐 JVR Music"
        )
        XCTAssertEqual(jayChou.title, "晴天")
        XCTAssertEqual(jayChou.artist, "周杰伦")

        let gem = LyricsService.extractCleanTitleAndArtist(
            rawTitle: "鄧紫棋《光年之外》【動態歌詞】",
            rawArtist: "Music Channel"
        )
        XCTAssertEqual(gem.title, "光年之外")
        XCTAssertEqual(gem.artist, "鄧紫棋")

        let kino = LyricsService.extractCleanTitleAndArtist(
            rawTitle: "Кино - Группа крови (Официальный клип) [HD]",
            rawArtist: "KINO Official"
        )
        XCTAssertEqual(kino.title, "Группа крови")
        XCTAssertEqual(kino.artist, "Кино")

        let tdd = LyricsService.extractCleanTitleAndArtist(
            rawTitle: "Три дня дождя — Отпускай (Премьера 2024)",
            rawArtist: "IZBA"
        )
        XCTAssertEqual(tdd.title, "Отпускай")
        XCTAssertEqual(tdd.artist, "Три дня дождя")
    }

    func testOriginalLanguageSelectionPreservesChineseHanAndRussianCyrillicAndRejectsInstrumentalPlaceholder() {
        // 1. Chinese song: must pick Chinese Han synced LRC, reject Pinyin/English translation & reject QQ instrumental placeholder
        let pinyinCandidate = LRCLIBEntryDTO(
            id: 1,
            trackName: "晴天 (Pinyin Romanized)",
            artistName: "Jay Chou",
            albumName: "Pinyin",
            duration: 269,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "[00:29.00]Gu shi de xiao huang hua"
        )
        let qqPlaceholder = LRCLIBEntryDTO(
            id: 2,
            trackName: "晴天",
            artistName: "周杰伦",
            albumName: "QQ Music",
            duration: 269,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "[00:00.00]纯音乐，请欣赏"
        )
        let chineseSynced = LRCLIBEntryDTO(
            id: 3,
            trackName: "晴天",
            artistName: "周杰伦",
            albumName: "叶惠美",
            duration: 269,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "[00:29.00]故事的小黄花\n[00:32.50]从出生那年就飘着"
        )

        let pickedCN = LyricsService.selectBestOriginalLanguageCandidate(
            from: [pinyinCandidate, qqPlaceholder, chineseSynced],
            referenceText: "周杰伦 晴天",
            targetTitle: "晴天",
            targetArtist: "周杰伦",
            targetDuration: 269
        )
        XCTAssertEqual(pickedCN?.id, 3, "Must select authentic Chinese Han synced LRC over Pinyin or instrumental placeholder")

        // 2. Russian song: must pick Russian Cyrillic synced LRC over English translation
        let engTranslation = LRCLIBEntryDTO(
            id: 10,
            trackName: "Группа крови (English Translation)",
            artistName: "Kino",
            albumName: "Translation",
            duration: 285,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "[00:30.00]Warm place, but the streets wait"
        )
        let ruSynced = LRCLIBEntryDTO(
            id: 11,
            trackName: "Группа крови",
            artistName: "Кино",
            albumName: "YouTube Music Synced",
            duration: 285,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "[00:30.00]Тёплое место, но улицы ждут\n[00:35.00]Отпечатков наших ног"
        )

        let pickedRU = LyricsService.selectBestOriginalLanguageCandidate(
            from: [engTranslation, ruSynced],
            referenceText: "Кино Группа крови",
            targetTitle: "Группа крови",
            targetArtist: "Кино",
            targetDuration: 285
        )
        XCTAssertEqual(pickedRU?.id, 11, "Must select original Russian Cyrillic synced LRC over English translation")
    }

    func testYouTubeMusicTimedLyricsJSONParserConvertsMillisecondsToSyncedLRC() throws {
        let sampleJSON = """
        {
          "contents": {
            "elementRenderer": {
              "timedLyricsModel": {
                "timedLyricsData": [
                  { "lyricLine": "♪", "cueRange": { "startTimeMilliseconds": "0", "endTimeMilliseconds": "8870" } },
                  { "lyricLine": "I got love, I got love", "cueRange": { "startTimeMilliseconds": "8870", "endTimeMilliseconds": "14920" } },
                  { "lyricLine": "Окутала меня, окутала", "cueRange": { "startTimeMilliseconds": "15100", "endTimeMilliseconds": "19500" } },
                  { "lyricLine": "Небо в алмазах - лето", "cueRange": { "startTimeMilliseconds": "20450", "endTimeMilliseconds": "24000" } }
                ]
              }
            }
          }
        }
        """
        let data = try XCTUnwrap(sampleJSON.data(using: .utf8))
        let dto = try XCTUnwrap(
            LyricsService.parseYouTubeMusicTimedLyricsJSON(data, title: "I Got Love", artist: "Miyagi", duration: 277)
        )
        XCTAssertEqual(dto.albumName, "YouTube Music Synced")
        let syncedLRC = try XCTUnwrap(dto.syncedLyrics)
        let parsed = LRCParser.parseSyncedLRC(syncedLRC, includeIntroDots: true)
        XCTAssertEqual(parsed.count, 4, "Should have intro dots + 3 sung lines")
        XCTAssertTrue(parsed[0].isInstrumental)
        XCTAssertEqual(parsed[1].text, "I got love, I got love")
        XCTAssertEqual(parsed[1].timestamp, 8.87, accuracy: 0.01)
        XCTAssertEqual(parsed[2].text, "Окутала меня, окутала")
        XCTAssertEqual(parsed[2].timestamp, 15.10, accuracy: 0.01)

        // Plain-only YouTube Music shelf fallback (no cueRange)
        let plainJSON = """
        {
          "contents": {
            "timedLyricsData": [
              { "lyricLine": "故事的小黃花從出生那年就飄著" },
              { "lyricLine": "童年的盪鞦韆隨記憶一直晃到現在" },
              { "lyricLine": "吹著前奏望著天空" }
            ]
          }
        }
        """
        let plainData = try XCTUnwrap(plainJSON.data(using: .utf8))
        let plainDTO = try XCTUnwrap(
            LyricsService.parseYouTubeMusicTimedLyricsJSON(plainData, title: "晴天", artist: "周杰伦", duration: 269)
        )
        XCTAssertNil(plainDTO.syncedLyrics)
        XCTAssertTrue(plainDTO.plainLyrics?.contains("故事的小黃花") == true)
    }

    func testHTMLEntityDecodingForQQMusicLyrics() {
        let raw = "[00:10.00]I&apos;m &quot;ready&quot; &amp; here&#58;&#32;now&#10;[00:15.00]Don&#39;t stop"
        let decoded = LyricsService.decodeLyricsHTMLEntities(raw)
        XCTAssertEqual(decoded, "[00:10.00]I'm \"ready\" & here: now\n[00:15.00]Don't stop")
    }

    // MARK: - Full-Length Offline Downloads, Playlist Batching, Offline Priority & Background Custom Artwork Tests

    func testFullLengthDownloadValidatorStrictlyRejects30SecondPreviewsAndAdClips() {
        // 30-second iTunes preview or 15-second YouTube ad clip MUST be rejected for full-length songs (>= 60s)
        XCTAssertFalse(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 29.8, expectedTrackDuration: 210.0))
        XCTAssertFalse(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 30.0, expectedTrackDuration: 185.0))
        XCTAssertFalse(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 15.0, expectedTrackDuration: 240.0))
        XCTAssertFalse(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 2.0, expectedTrackDuration: 40.0))

        // Full-length audio passes cleanly
        XCTAssertTrue(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 208.5, expectedTrackDuration: 210.0))
        XCTAssertTrue(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 145.0, expectedTrackDuration: 150.0))
        // Genuinely short interlude (< 60s) passes cleanly
        XCTAssertTrue(OfflineDownloadManager.isFullLengthDurationValid(actualDuration: 38.0, expectedTrackDuration: 40.0))

        // Sanitizer strips range/rn/rbuf/ump/srfvp while preserving pot= and mime=audio%2Fmp4
        let raw = "https://rr3---sn-test.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4&range=0-65535&rn=2&rbuf=0&ump=1&srfvp=1&pot=VALID_TOKEN"
        let clean = YouTubeWebKitAudioExtractor.sanitizeFullLengthYouTubeStreamURL(raw)
        XCTAssertNotNil(clean)
        let cleanStr = clean?.absoluteString ?? ""
        XCTAssertTrue(cleanStr.contains("itag=140"))
        XCTAssertTrue(cleanStr.contains("pot=VALID_TOKEN"))
        XCTAssertFalse(cleanStr.contains("range="))
        XCTAssertFalse(cleanStr.contains("ump="))
        XCTAssertFalse(cleanStr.contains("srfvp="))
    }

    @MainActor
    func testOfflineDownloadAlwaysPlaysFirstEvenWhenOnlineAndAcrossProviders() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlDir = docs.appendingPathComponent("AuraDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let relPath = "AuraDownloads/offline_priority_test.wav"
        let fullURL = docs.appendingPathComponent(relPath)
        try UniversalAudioPlayerEngine.buildSubAudibleKeepAliveWAVData().write(to: fullURL, options: .atomic)
        defer {
            OfflineDownloadManager.shared.removeDownload(trackID: "youtubeMusic:OFFLINE_VID_1")
            try? FileManager.default.removeItem(at: fullURL)
        }

        let ytTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "OFFLINE_VID_1",
            title: "Starboy",
            artist: "The Weeknd",
            album: "Starboy",
            duration: 230.0,
            isStreamable: true
        )
        OfflineDownloadManager.shared.registerCompletedDownloadForTesting(track: ytTrack, relativePath: relPath)

        // 1. Direct match resolves offline file
        XCTAssertEqual(OfflineDownloadManager.shared.completedLocalRelativePath(for: ytTrack), relPath)

        // 2. Same video via `.youtube` provider resolves the exact same offline file
        let ytVideoTrack = UniversalTrack(
            provider: .youtube,
            providerTrackID: "OFFLINE_VID_1",
            title: "Starboy (Official Video)",
            artist: "The Weeknd",
            album: "YouTube",
            duration: 230.0,
            isStreamable: true
        )
        XCTAssertEqual(OfflineDownloadManager.shared.completedLocalRelativePath(for: ytVideoTrack), relPath)

        // 3. Same song via `.appleMusic` catalog chart resolves the downloaded offline file too!
        let appleVariant = UniversalTrack(
            provider: .appleMusic,
            providerTrackID: "am-999111",
            title: "Starboy",
            artist: "The Weeknd",
            album: "Starboy",
            duration: 230.0,
            isStreamable: false
        )
        XCTAssertEqual(OfflineDownloadManager.shared.completedLocalRelativePath(for: appleVariant), relPath)

        // 4. Playing the YouTube track immediately uses native AVPlayer offline (activeYouTubeVideoID == nil -> 0 ads, 0 WebKit wait!)
        let engine = UniversalAudioPlayerEngine.shared
        engine.play(ytTrack)
        XCTAssertNil(engine.activeYouTubeVideoID, "Downloaded offline song MUST play natively via AVPlayer without loading WKWebView")
        XCTAssertEqual(engine.playbackStatusBanner, "Offline Audio")
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
    }

    @MainActor
    func testPlaylistDownloadSummaryTracksCompletedAndTotalAccurately() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlDir = docs.appendingPathComponent("AuraDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let relPath = "AuraDownloads/playlist_summary_t1.wav"
        let fullURL = docs.appendingPathComponent(relPath)
        try UniversalAudioPlayerEngine.buildSubAudibleKeepAliveWAVData().write(to: fullURL, options: .atomic)
        defer {
            OfflineDownloadManager.shared.removeDownload(trackID: "youtubeMusic:PL_T1")
            try? FileManager.default.removeItem(at: fullURL)
        }

        let t1 = UniversalTrack(provider: .youtubeMusic, providerTrackID: "PL_T1", title: "Song One", artist: "Artist A", album: "A", duration: 200)
        let t2 = UniversalTrack(provider: .youtubeMusic, providerTrackID: "PL_T2", title: "Song Two", artist: "Artist B", album: "B", duration: 210)
        let t3 = UniversalTrack(provider: .youtubeMusic, providerTrackID: "PL_T3", title: "Song Three", artist: "Artist C", album: "C", duration: 220)

        OfflineDownloadManager.shared.registerCompletedDownloadForTesting(track: t1, relativePath: relPath)
        let summary = OfflineDownloadManager.shared.playlistDownloadSummary(for: [t1, t2, t3])
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.active, 0)
        XCTAssertEqual(summary.total, 3)
    }

    @MainActor
    func testOfflineLyricsCacheKeyMatchesNormalizedYouTubeAndCleanTitles() {
        let ytTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "DYptgVvkVLQ",
            title: "周杰伦《晴天》官方MV",
            artist: "JVR Music",
            album: "YouTube Music",
            duration: 269
        )
        let cleanTrack = UniversalTrack(
            provider: .appleMusic,
            providerTrackID: "cn-101",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            duration: 269
        )
        XCTAssertEqual(
            LyricsService.lyricsCacheKey(for: ytTrack),
            LyricsService.lyricsCacheKey(for: cleanTrack),
            "Offline cached lyrics must resolve consistently between YouTube and clean catalog titles"
        )
    }

    @MainActor
    func testCustomSongArtworkUpdatesLockScreenNowPlayingImmediatelyAndEncodesBase64DataURIForWebKit() async throws {
        let defaultRemoteURL = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/default_cover.jpg")!
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "CUSTOM_ART_BG_01",
            title: "Custom Cover Song",
            artist: "Test Artist",
            album: "Test Album",
            artworkURL: defaultRemoteURL,
            duration: 215.0,
            isStreamable: true
        )

        // Generate two distinct in-memory JPEG photos (red, then green)
        func makeSolidPhotoData(_ color: UIColor) -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
            let img = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            }
            return img.jpegData(compressionQuality: 0.9)!
        }

        let persistence = PersistenceController.shared
        let engine = UniversalAudioPlayerEngine.shared
        defer {
            _ = persistence.setCustomTrackArtwork(imageData: nil, for: track, defaultArtworkURL: defaultRemoteURL)
            engine.pause()
            engine.activeYouTubeVideoID = nil
        }

        // 1. Apply first custom photo -> must save versioned file & resolve via live relative path
        let firstURL = try XCTUnwrap(
            persistence.setCustomTrackArtwork(imageData: makeSolidPhotoData(.systemRed), for: track, defaultArtworkURL: defaultRemoteURL)
        )
        XCTAssertTrue(firstURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(persistence.hasCustomArtwork(for: track))
        XCTAssertEqual(persistence.effectiveArtworkURL(for: track), firstURL)

        // 2. Start playing -> Lock Screen MPNowPlayingInfoCenter MUST immediately carry custom MPMediaItemArtwork on frame 0!
        engine.play(track)
        XCTAssertEqual(engine.currentTrack?.artworkURL, firstURL)
        XCTAssertNotNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
            "Custom song cover photo MUST be attached immediately to Lock Screen MPNowPlayingInfoCenter"
        )

        // 3. Base64 JPEG data URI for WKWebView navigator.mediaSession (since WebKit blocks file:// URLs!)
        let rawDataURI = await ArtworkCacheManager.shared.base64JPEGDataURI(for: firstURL)
        let dataURI = try XCTUnwrap(rawDataURI)
        XCTAssertTrue(dataURI.hasPrefix("data:image/jpeg;base64,"), "Custom photo must encode to data:image/jpeg;base64 URI for WebKit Lock Screen")

        // 4. Replace with second custom photo -> must get a fresh versioned URL & update Lock Screen immediately
        try await Task.sleep(nanoseconds: 10_000_000)
        let secondURL = try XCTUnwrap(
            persistence.setCustomTrackArtwork(imageData: makeSolidPhotoData(.systemGreen), for: track, defaultArtworkURL: defaultRemoteURL)
        )
        XCTAssertNotEqual(firstURL, secondURL, "Changing photo must create a fresh versioned file URL so caches never stick on old image")
        engine.applyUpdatedArtworkURL(secondURL, forTrackID: track.id)
        XCTAssertEqual(engine.currentTrack?.artworkURL, secondURL)
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])

        // 5. Reset back to default album cover
        let restored = persistence.setCustomTrackArtwork(imageData: nil, for: track, defaultArtworkURL: defaultRemoteURL)
        XCTAssertEqual(restored, defaultRemoteURL)
        XCTAssertFalse(persistence.hasCustomArtwork(for: track))
    }

    // MARK: - External App Auto-Pause (TikTok / YouTube) & 10-Pass <=30s AI Audio Lyrics Tests

    @MainActor
    func testTikTokOrYouTubeSilenceSecondaryAudioHintImmediatelyPausesPlaybackWithoutFighting() async throws {
        let engine = UniversalAudioPlayerEngine.shared
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "TIKTOK_PAUSE_01",
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up",
            duration: 243.0,
            isStreamable: true
        )
        defer {
            engine.pause()
            engine.activeYouTubeVideoID = nil
        }

        engine.play(track)
        engine.activeYouTubeVideoID = track.providerTrackID
        XCTAssertTrue(engine.isPlaying)

        // 1. In foreground within first 2.5s of track start, own WKWebView startup hint MUST NOT pause the song
        engine.handleSilenceSecondaryAudioHint(type: .begin, at: CACurrentMediaTime() + 0.3, isAppActive: true)
        XCTAssertTrue(engine.isPlaying, "Foreground WKWebView startup must not self-pause via secondary audio hint")

        // 2. When user switches to TikTok or YouTube (AuraMusic in background -> isAppActive == false),
        // iOS fires silenceSecondaryAudioHint (.begin) -> AuraMusic MUST pause IMMEDIATELY!
        engine.handleSilenceSecondaryAudioHint(type: .begin, at: CACurrentMediaTime() + 0.4, isAppActive: false)
        XCTAssertFalse(engine.isPlaying, "Opening TikTok or YouTube video MUST immediately pause AuraMusic")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)

        // 3. Resume works cleanly after user closes TikTok/YouTube, and WebKit externalAudioPause bridge also pauses immediately
        engine.resume()
        XCTAssertTrue(engine.isPlaying)

        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: track.providerTrackID)
        let coord = playerView.makeCoordinator()
        coord.loadedVideoID = track.providerTrackID
        coord.handleBridgePayload(["type": "externalAudioPause"])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(engine.isPlaying, "WebKit externalAudioPause (navigator.audioSession interrupted) MUST immediately pause AuraMusic")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)
    }

    @MainActor
    func testWebKitExternalAudioInterruptionPausesVideoAndNeverAutoResumesOverTikTok() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                "<!doctype html><html><body><div id='movie_player'></div><video id='v' playsinline></video></body></html>",
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        var ready = false
        for _ in 0..<15 {
            if let ok = try? await webView.evaluateJavaScript("typeof window.auraControl === 'object' && typeof window.auraControl.pauseForExternalApp === 'function'") as? Bool, ok {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertTrue(ready, "WebKit bridge must expose window.auraControl.pauseForExternalApp")

        // Simulate background playback interrupted by TikTok/YouTube -> pauseForExternalApp + keepAliveInBackground MUST stay paused!
        let interruptedState = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.enterBackground(8000);
          window.auraControl.pauseForExternalApp();
          window.auraControl.keepAliveInBackground();
          return {
            externalInterrupted: window._auraExternalInterrupted === true,
            userPaused: window._auraUserPaused === true,
            softPaused: window._auraSoftPaused === true
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(interruptedState?["externalInterrupted"] as? Bool, true)
        XCTAssertEqual(interruptedState?["userPaused"] as? Bool, true, "External app pause must mark song paused")
        XCTAssertEqual(interruptedState?["softPaused"] as? Bool, false, "External app pause must genuinely pause instead of soft-playing")

        // Resuming later must cleanly clear _auraExternalInterrupted
        let resumedState = try await webView.evaluateJavaScript("""
        (function() {
          window.auraControl.resume();
          return {
            externalInterrupted: window._auraExternalInterrupted === true,
            userPaused: window._auraUserPaused === true
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(resumedState?["externalInterrupted"] as? Bool, false)
        XCTAssertEqual(resumedState?["userPaused"] as? Bool, false)
    }

    func testAILyricsPass1PauseDetectorIdentifiesIntroAndMidSongPausesFromRMSEnvelope() {
        // Build 30.0s RMS envelope at 0.1s per frame (300 frames):
        // 0.0-4.0s intro silence | 4.0-12.0s verse | 12.0-13.0s 1s short breath | 13.0-19.0s chorus | 19.0-24.0s 5s bridge pause | 24.0-30.0s outro
        var rms = [Float]()
        for i in 0..<300 {
            let t = Double(i) * 0.1
            if t < 4.0 {
                rms.append(0.002)
            } else if t < 12.0 {
                rms.append(0.35)
            } else if t < 13.0 {
                rms.append(0.004) // short 1.0s breath -> must be ignored (< 2.4s)
            } else if t < 19.0 {
                rms.append(0.42)
            } else if t < 24.0 {
                rms.append(0.003) // 5.0s instrumental break -> must be detected!
            } else {
                rms.append(0.33)
            }
        }

        let pauses = AILyricsTranscriptionEngine.detectPauseIntervals(
            rmsFrames: rms,
            frameDuration: 0.1,
            trackDuration: 30.0,
            minPauseDuration: 2.4
        )
        XCTAssertEqual(pauses.count, 2, "Pass 1 DSP must detect intro pause and 5s mid-song pause while ignoring 1s breath")
        XCTAssertEqual(pauses[0].start, 0.0, accuracy: 0.15)
        XCTAssertEqual(pauses[0].end, 4.0, accuracy: 0.15)
        XCTAssertEqual(pauses[1].start, 19.0, accuracy: 0.15)
        XCTAssertEqual(pauses[1].end, 24.0, accuracy: 0.15)
    }

    func testAILyricsForeignWordMergerReplacesLowConfidenceSegmentsAndPreservesNativeWords() {
        let primaryTokens: [AIWordToken] = [
            AIWordToken(text: "Окутала", timestamp: 5.0, duration: 0.5, confidence: 0.92, languageCode: "ru"),
            AIWordToken(text: "меня", timestamp: 5.6, duration: 0.4, confidence: 0.90, languageCode: "ru"),
            AIWordToken(text: "ай", timestamp: 8.0, duration: 0.25, confidence: 0.34, languageCode: "ru"),
            AIWordToken(text: "гат", timestamp: 8.35, duration: 0.25, confidence: 0.31, languageCode: "ru"),
            AIWordToken(text: "лав", timestamp: 8.70, duration: 0.35, confidence: 0.38, languageCode: "ru")
        ]
        let secondaryTokens: [AIWordToken] = [
            AIWordToken(text: "Oh", timestamp: 5.05, duration: 0.4, confidence: 0.55, languageCode: "en"), // weaker than Russian 0.92 -> MUST NOT replace!
            AIWordToken(text: "I", timestamp: 8.02, duration: 0.22, confidence: 0.89, languageCode: "en"),
            AIWordToken(text: "got", timestamp: 8.36, duration: 0.24, confidence: 0.91, languageCode: "en"),
            AIWordToken(text: "love", timestamp: 8.72, duration: 0.34, confidence: 0.94, languageCode: "en")
        ]

        let result = AILyricsTranscriptionEngine.mergeForeignLanguageTokens(
            primaryTokens: primaryTokens,
            secondaryTokens: secondaryTokens
        )
        XCTAssertEqual(result.foreignReplacements, 3, "All 3 low-confidence English hook words must be replaced cleanly")
        XCTAssertEqual(result.merged.map(\.text), ["Окутала", "меня", "I", "got", "love"])
    }

    @MainActor
    func testAILyricsMultiPassConsensusAndSyncedLRCBuilderProducesValidMonotonicLyricsWithPauses() throws {
        // Overlapping passes with a boundary duplicate and slight timestamp jitter
        let passA: [AIWordToken] = [
            AIWordToken(text: "Небо", timestamp: 6.0, duration: 0.4, confidence: 0.85, languageCode: "ru"),
            AIWordToken(text: "в", timestamp: 6.5, duration: 0.15, confidence: 0.82, languageCode: "ru"),
            AIWordToken(text: "алмазах", timestamp: 6.75, duration: 0.55, confidence: 0.88, languageCode: "ru"),
            AIWordToken(text: "I", timestamp: 16.0, duration: 0.2, confidence: 0.90, languageCode: "en"),
            AIWordToken(text: "got", timestamp: 16.3, duration: 0.25, confidence: 0.91, languageCode: "en"),
            AIWordToken(text: "love", timestamp: 16.65, duration: 0.4, confidence: 0.94, languageCode: "en")
        ]
        let passB: [AIWordToken] = [
            AIWordToken(text: "алмазах", timestamp: 6.80, duration: 0.52, confidence: 0.91, languageCode: "ru"), // boundary overlap
            AIWordToken(text: "I", timestamp: 16.02, duration: 0.22, confidence: 0.88, languageCode: "en")
        ]

        let reconciled = AILyricsTranscriptionEngine.reconcileMultiPassTokens(passes: [passA, passB])
        XCTAssertEqual(reconciled.map(\.text), ["Небо", "в", "алмазах", "I", "got", "love"])

        let pauses = [
            AIPauseInterval(start: 0.0, end: 5.8),
            AIPauseInterval(start: 8.2, end: 15.6)
        ]
        let lrc = AILyricsTranscriptionEngine.buildSyncedLRCFromTokens(
            tokens: reconciled,
            pauses: pauses,
            trackDuration: 25.0
        )
        let parsed = LRCParser.parseSyncedLRC(lrc, includeIntroDots: true)
        XCTAssertGreaterThanOrEqual(parsed.count, 4, "Must include intro dots, verse line, mid-song pause dots, and hook line")
        XCTAssertTrue(parsed[0].isInstrumental, "Intro pause must render as ••• dots")
        XCTAssertTrue(parsed.contains(where: { $0.text == "Небо в алмазах" }))
        XCTAssertTrue(parsed.contains(where: { $0.text == "I got love" }))
        XCTAssertTrue(parsed.filter(\.isInstrumental).count >= 2, "Both intro and mid-song pause must be marked with •••")

        // Verify strictly increasing timestamps
        for idx in 1..<parsed.count {
            XCTAssertGreaterThan(parsed[idx].timestamp, parsed[idx - 1].timestamp)
        }

        // Verify SwiftData AI cache round-trip using separate "ai::" namespace (never overwrites standard lyrics!)
        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "AI_LRC_TEST_01",
            title: "I Got Love",
            artist: "Miyagi",
            album: "Single",
            duration: 25.0
        )
        XCTAssertTrue(LyricsService.aiLyricsCacheKey(for: track).hasPrefix("ai::"))
        let saved = try XCTUnwrap(LyricsService.shared.saveAILyrics(syncedLRC: lrc, for: track))
        XCTAssertTrue(saved.isSynchronized)
        let reloaded = try XCTUnwrap(LyricsService.shared.loadCachedAILyrics(for: track))
        XCTAssertEqual(reloaded.syncedLines.count, saved.syncedLines.count)
    }

    func testAILyricsTenPassContractAnd30SecondHardBudgetEnforced() {
        XCTAssertEqual(AILyricsTranscriptionEngine.totalRequiredPasses, 10)
        XCTAssertEqual(AILyricsTranscriptionEngine.maxDurationBudgetSeconds, 30.0, accuracy: 0.001)

        // Pass 1 must explain language, pauses, and foreign-language word detection
        let p1 = AILyricsTranscriptionEngine.passDescriptor(for: 1, primaryLang: nil, secondaryLang: nil, pauseCount: 0, foreignCount: 0)
        XCTAssertTrue(p1.title.contains("1/10"))
        XCTAssertTrue(p1.detail.lowercased().contains("язык"))
        XCTAssertTrue(p1.detail.lowercased().contains("пауз"))

        // Passes 2...10 must all have valid Russian descriptors
        for pass in 2...10 {
            let desc = AILyricsTranscriptionEngine.passDescriptor(for: pass, primaryLang: "Русский", secondaryLang: "English", pauseCount: 3, foreignCount: 5)
            XCTAssertTrue(desc.title.contains("\(pass)/10"), "Pass \(pass) title must display \(pass)/10")
            XCTAssertFalse(desc.detail.isEmpty)
        }

        // Budget enforcement: remaining time strictly caps per-pass timeout and stops at 0 when expired
        let now = Date()
        let deadline = now.addingTimeInterval(28.5)
        XCTAssertEqual(
            AILyricsTranscriptionEngine.computePassTimeout(hardDeadline: deadline, preferred: 4.0, reserveForLater: 6.0, now: now),
            4.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            AILyricsTranscriptionEngine.computePassTimeout(hardDeadline: deadline, preferred: 4.0, reserveForLater: 27.0, now: now),
            1.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            AILyricsTranscriptionEngine.computePassTimeout(hardDeadline: deadline, preferred: 4.0, reserveForLater: 28.4, now: now),
            0.0,
            accuracy: 0.001
        )
    }

    func testInfoPlistDeclaresSpeechRecognitionUsageDescriptionForAILyrics() {
        let appBundle = Bundle(for: UniversalAudioPlayerEngine.self)
        let usage = appBundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        XCTAssertNotNil(usage, "NSSpeechRecognitionUsageDescription MUST be present in Info.plist so Speech permission never crashes on iOS")
        XCTAssertFalse((usage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Real Offline Download Engine, YouTube Innertube Resolver & M4A Audio Extraction Tests

    func testYouTubeInnertubePlayerJSONParserPrioritizesProgressiveMP4Itag18AndRejectsUnplayable() throws {
        let okJSON = """
        {
          "playabilityStatus": { "status": "OK" },
          "videoDetails": { "videoId": "YkY4X_OaF6o", "title": "I Got Love", "lengthSeconds": "277" },
          "streamingData": {
            "formats": [
              {
                "itag": 22,
                "url": "https://rr1---sn-test.googlevideo.com/videoplayback?itag=22&mime=video/mp4",
                "mimeType": "video/mp4; codecs=\\"avc1.64001F, mp4a.40.2\\"",
                "approxDurationMs": "277120"
              },
              {
                "itag": 18,
                "url": "https://rr1---sn-test.googlevideo.com/videoplayback?itag=18&mime=video/mp4",
                "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"",
                "approxDurationMs": "277120"
              }
            ],
            "adaptiveFormats": [
              {
                "itag": 140,
                "url": "https://rr1---sn-test.googlevideo.com/videoplayback?itag=140&mime=audio/mp4",
                "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"",
                "bitrate": 131164,
                "approxDurationMs": "277120"
              },
              {
                "itag": 251,
                "url": "https://rr1---sn-test.googlevideo.com/videoplayback?itag=251&mime=audio/webm",
                "mimeType": "audio/webm; codecs=\\"opus\\"",
                "bitrate": 140000
              }
            ]
          }
        }
        """
        let data = try XCTUnwrap(okJSON.data(using: .utf8))
        let streams = YouTubeInnertubeAudioResolver.parsePlayerResponseJSON(data)
        XCTAssertEqual(streams.count, 3, "Should keep progressive mp4 (18, 22) + adaptive audio/mp4 (140) and exclude WebM")
        XCTAssertEqual(streams[0].itag, 18, "Compact HTTP-200 progressive itag=18 MUST be prioritized first!")
        XCTAssertTrue(streams[0].isProgressiveMP4)
        XCTAssertEqual(streams[0].durationSeconds, 277.12, accuracy: 0.1)
        XCTAssertEqual(streams[0].headers["User-Agent"], YouTubeInnertubeAudioResolver.androidUserAgent)
        XCTAssertEqual(streams[2].itag, 140)
        XCTAssertFalse(streams[2].isProgressiveMP4)

        // Unplayable / LOGIN_REQUIRED must return empty list cleanly
        let blockedJSON = """
        {
          "playabilityStatus": { "status": "LOGIN_REQUIRED", "reason": "Sign in to confirm" },
          "streamingData": { "formats": [{ "itag": 18, "url": "https://example.com/a.mp4", "mimeType": "video/mp4" }] }
        }
        """
        let blockedData = try XCTUnwrap(blockedJSON.data(using: .utf8))
        XCTAssertTrue(YouTubeInnertubeAudioResolver.parsePlayerResponseJSON(blockedData).isEmpty)
    }

    func testExtractAudioOnlyM4AProducesPlayablePureAudioFileWithZeroVideoTracks() async throws {
        // Generate a real 2-second 44.1kHz WAV source and convert via OfflineDownloadManager.extractAudioOnlyM4A
        let tmpDir = FileManager.default.temporaryDirectory
        let sourceWAV = tmpDir.appendingPathComponent("extract_src_\(UUID().uuidString).wav")
        let destM4A = tmpDir.appendingPathComponent("extract_out_\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: sourceWAV)
            try? FileManager.default.removeItem(at: destM4A)
        }

        let wavData = await UniversalAudioPlayerEngine.buildSubAudibleKeepAliveWAVData()
        try wavData.write(to: sourceWAV, options: .atomic)
        let success = await OfflineDownloadManager.extractAudioOnlyM4A(from: sourceWAV, to: destM4A)
        XCTAssertTrue(success, "extractAudioOnlyM4A must convert audio source into a valid .m4a file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destM4A.path))

        let asset = AVURLAsset(url: destM4A)
        let (isPlayable, dur, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
        XCTAssertTrue(isPlayable, "Exported .m4a must be natively playable by AVPlayer")
        XCTAssertGreaterThanOrEqual(dur.seconds, 1.8)
        XCTAssertTrue(tracks.contains { $0.mediaType == .audio }, "Exported .m4a must contain an audio track")
        XCTAssertFalse(tracks.contains { $0.mediaType == .video }, "Exported .m4a must contain ZERO video tracks")
    }

    @MainActor
    func testRealEndToEndFullLengthOfflineDownloadSavesPlayableM4AAndPlaysOfflineFirst() async throws {
        // Live end-to-end test: resolves real YouTube full-length track via ANDROID Innertube API,
        // downloads the complete file off-main-thread, strips video to lossless .m4a, verifies >= 150s full duration,
        // caches lyrics, and plays offline via native AVPlayer (0 ads, 0 WKWebView)!
        let candidates: [UniversalTrack] = [
            UniversalTrack(
                provider: .youtubeMusic,
                providerTrackID: "fHI8X4OXluQ",
                title: "Blinding Lights",
                artist: "The Weeknd",
                album: "After Hours",
                duration: 203.0,
                isStreamable: true
            ),
            UniversalTrack(
                provider: .youtubeMusic,
                providerTrackID: "YkY4X_OaF6o",
                title: "I Got Love",
                artist: "Miyagi & Эндшпиль",
                album: "I Got Love",
                duration: 277.0,
                isStreamable: true
            )
        ]

        let manager = OfflineDownloadManager.shared
        let engine = UniversalAudioPlayerEngine.shared
        var downloadedTrack: UniversalTrack? = nil
        var completedItem: DownloadTaskItem? = nil

        for track in candidates {
            manager.removeDownload(trackID: track.id)
            let resolved = await YouTubeInnertubeAudioResolver.resolvePlayableStreams(videoID: track.providerTrackID)
            if resolved.contains(where: \.isProgressiveMP4) {
                let item = await manager.downloadTrackNowForTesting(track)
                if item?.state == .completed {
                    downloadedTrack = track
                    completedItem = item
                    break
                }
            }
        }

        defer {
            engine.pause()
            engine.activeYouTubeVideoID = nil
            for track in candidates {
                manager.removeDownload(trackID: track.id)
            }
        }

        // Verify full end-to-end real download when live YouTube is reachable from the test runner!
        guard let track = downloadedTrack, let item = completedItem else {
            // If CI runner datacenter IP is temporarily bot-gated by YouTube, verify local full-length download validation explicitly
            let fallbackShort = UniversalTrack(
                provider: .youtubeMusic,
                providerTrackID: "INVALID_NONEXISTENT_ID_999",
                title: "Unavailable",
                artist: "None",
                album: "None",
                duration: 200.0
            )
            let failedItem = await manager.downloadTrackNowForTesting(fallbackShort)
            XCTAssertEqual(failedItem?.state, .failed, "Unreachable track must cleanly report .failed instead of saving corrupt data")
            manager.removeDownload(trackID: fallbackShort.id)
            return
        }

        print("[LIVE OFFLINE TEST] Downloaded \(track.title) -> \(item.localRelativePath ?? "nil") (\(item.fileSizeBytes) bytes, lyrics=\(item.hasOfflineLyrics))")
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.progress, 1.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(item.fileSizeBytes, 500_000, "Full-length offline audio file must be >= 500 KB")
        let relPath = try XCTUnwrap(item.localRelativePath)
        XCTAssertTrue(relPath.hasSuffix(".m4a") || relPath.hasSuffix(".mp4"), "Saved offline file must be .m4a or .mp4")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localURL = docs.appendingPathComponent(relPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path), "Downloaded file must exist on disk")

        // Verify REAL audio playability & FULL-LENGTH duration (>= 150s, NEVER a 30-second preview!)
        let asset = AVURLAsset(url: localURL)
        let (isPlayable, loadedDuration, mediaTracks) = try await asset.load(.isPlayable, .duration, .tracks)
        XCTAssertTrue(isPlayable, "Downloaded offline song MUST be natively playable by AVFoundation")
        XCTAssertGreaterThanOrEqual(loadedDuration.seconds, 150.0, "Downloaded song MUST be full-length (>= 150s), NEVER a 30s preview!")
        XCTAssertTrue(mediaTracks.contains { $0.mediaType == .audio }, "Downloaded file MUST contain an audio track")
        if relPath.hasSuffix(".m4a") {
            XCTAssertFalse(mediaTracks.contains { $0.mediaType == .video }, "Extracted .m4a MUST have video stripped cleanly")
        }

        // Verify Offline-First playback works immediately with ZERO WKWebView and ZERO ads!
        XCTAssertTrue(manager.isDownloaded(track))
        engine.play(track)
        XCTAssertNil(engine.activeYouTubeVideoID, "Downloaded track MUST play natively via AVPlayer without WKWebView")
        XCTAssertEqual(engine.playbackStatusBanner, "Offline Audio")
        XCTAssertTrue(engine.isPlaying)
    }

    @MainActor
    func testOfflineDownloadCleanlyMarksInvalidTrackFailedWithoutLeavingCorruptFiles() async {
        let manager = OfflineDownloadManager.shared
        let invalidTrack = UniversalTrack(
            provider: .soundCloud,
            providerTrackID: "bad-404-track",
            title: "Nonexistent Track XYZ987654",
            artist: "Nobody XYZ987654",
            album: "None",
            duration: 210.0,
            streamURL: URL(string: "https://example.com/not-an-audio-file.html"),
            isStreamable: true
        )
        defer { manager.removeDownload(trackID: invalidTrack.id) }

        let result = await manager.downloadTrackNowForTesting(invalidTrack)
        XCTAssertEqual(result?.state, .failed, "HTML/404 response must cleanly transition task to .failed")
        XCTAssertNil(result?.localRelativePath, "Failed download must never store a bogus file path")
        XCTAssertFalse(manager.isDownloaded(invalidTrack))
    }

    // MARK: - Studio Vocal Isolation DSP, 100% Chunk Coverage & Audio-Anchored AI Lyrics v2 Tests

    func testVocalIsolationDSPSuppressesSubBassAndWideStereoWhilePreservingCenterVocals() {
        let sr = 16_000.0
        let count = Int(sr * 1.0) // 1.0 second

        // 1. Center-panned 1000 Hz vocal tone (L == R)
        var vocalL = [Float](repeating: 0, count: count)
        var vocalR = [Float](repeating: 0, count: count)
        // 2. Heavy 60 Hz 808 sub-bass (L == R)
        var bassL = [Float](repeating: 0, count: count)
        var bassR = [Float](repeating: 0, count: count)
        // 3. Wide stereo out-of-phase synth at 1000 Hz (L = +s, R = -s -> pure Side!)
        var wideL = [Float](repeating: 0, count: count)
        var wideR = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let t = Double(i) / sr
            let v = Float(sin(2.0 * Double.pi * 1000.0 * t) * 0.5)
            vocalL[i] = v
            vocalR[i] = v

            let b = Float(sin(2.0 * Double.pi * 60.0 * t) * 0.8)
            bassL[i] = b
            bassR[i] = b

            let w = Float(sin(2.0 * Double.pi * 1000.0 * t) * 0.6)
            wideL[i] = w
            wideR[i] = -w
        }

        let vocalOut = VocalIsolationDSP.processStereoForVocals(left: vocalL, right: vocalR, sampleRate: sr).vocalIsolated
        let bassOut = VocalIsolationDSP.processStereoForVocals(left: bassL, right: bassR, sampleRate: sr).vocalIsolated
        let wideOut = VocalIsolationDSP.processStereoForVocals(left: wideL, right: wideR, sampleRate: sr).vocalIsolated

        let vocalRMS = AILyricsTranscriptionEngine.computeRMSEnvelope(samples: vocalOut, sampleRate: sr).reduce(0, +)
        let bassRMS = AILyricsTranscriptionEngine.computeRMSEnvelope(samples: bassOut, sampleRate: sr).reduce(0, +)
        let wideRMS = AILyricsTranscriptionEngine.computeRMSEnvelope(samples: wideOut, sampleRate: sr).reduce(0, +)

        XCTAssertGreaterThan(vocalRMS, 0.5, "Center 1000 Hz vocal must pass cleanly at strong level")
        XCTAssertLessThan(bassRMS, vocalRMS * 0.35, "190 Hz high-pass must heavily suppress 60 Hz 808 sub-bass")
        XCTAssertLessThan(wideRMS, 0.01, "Mid/Side stereo vocal isolation must cancel wide out-of-phase stereo instruments")
    }

    func testAILyricsContiguousChunksCover100PercentOfSongWithZeroSkippedSeconds() {
        let chunks = AILyricsTranscriptionEngine.buildContiguousListeningChunks(
            start: 8.0,
            end: 240.0,
            chunkLength: 24.0,
            overlap: 1.5
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 10)
        XCTAssertEqual(chunks.first?.start ?? -1, 8.0, accuracy: 0.001)
        XCTAssertEqual(chunks.last?.end ?? -1, 240.0, accuracy: 0.001)
        for i in 0..<chunks.count {
            XCTAssertLessThanOrEqual(chunks[i].end - chunks[i].start, 24.01, "Each chunk must be <= 24s for fast isFinal recognition")
            if i > 0 {
                XCTAssertLessThan(chunks[i].start, chunks[i - 1].end, "Adjacent chunks MUST overlap so ZERO seconds of the song are skipped!")
            }
        }
    }

    func testAILyricsLanguageProbeScorePrefersConfidentRussianOverLowConfidenceEnglishGibberish() {
        let confidentRussian = [
            AIWordToken(text: "Окутала", timestamp: 10.0, duration: 0.5, confidence: 0.89, languageCode: "ru"),
            AIWordToken(text: "меня", timestamp: 10.6, duration: 0.4, confidence: 0.87, languageCode: "ru"),
            AIWordToken(text: "небо", timestamp: 11.4, duration: 0.4, confidence: 0.85, languageCode: "ru"),
            AIWordToken(text: "алмазах", timestamp: 12.0, duration: 0.6, confidence: 0.91, languageCode: "ru")
        ]
        let englishGibberish = [
            AIWordToken(text: "a", timestamp: 10.0, duration: 0.2, confidence: 0.22, languageCode: "en"),
            AIWordToken(text: "cool", timestamp: 10.3, duration: 0.3, confidence: 0.28, languageCode: "en"),
            AIWordToken(text: "la", timestamp: 10.7, duration: 0.2, confidence: 0.24, languageCode: "en"),
            AIWordToken(text: "men", timestamp: 11.1, duration: 0.3, confidence: 0.31, languageCode: "en"),
            AIWordToken(text: "yeah", timestamp: 11.6, duration: 0.3, confidence: 0.27, languageCode: "en")
        ]
        XCTAssertGreaterThan(
            AILyricsTranscriptionEngine.scoreLanguageProbe(confidentRussian),
            AILyricsTranscriptionEngine.scoreLanguageProbe(englishGibberish),
            "Confidence-weighted probe score MUST select true Russian vocals over low-confidence English hallucinations"
        )
    }

    func testAILyricsAudioAnchoredAlignmentFixesSpellingWhilePreservingRealAudioTimestampsAndPauses() {
        let referenceLines = [
            "I got love, I got love",
            "Окутала меня, окутала",
            "Небо в алмазах - лето",
            "Свет в темноте горит"
        ]
        // Simulated real audio timestamps from a version with a 15-second MV intro & a 10-second instrumental break!
        // Notice slightly misheard words ("окутал", "алмазы") that Pass 9 must verify & fix while keeping exact audio timestamps!
        let audioTokens = [
            AIWordToken(text: "I", timestamp: 15.2, duration: 0.2, confidence: 0.88, languageCode: "en"),
            AIWordToken(text: "got", timestamp: 15.5, duration: 0.25, confidence: 0.90, languageCode: "en"),
            AIWordToken(text: "love", timestamp: 15.85, duration: 0.35, confidence: 0.92, languageCode: "en"),
            AIWordToken(text: "окутал", timestamp: 21.8, duration: 0.5, confidence: 0.68, languageCode: "ru"),
            AIWordToken(text: "меня", timestamp: 22.4, duration: 0.4, confidence: 0.86, languageCode: "ru"),
            AIWordToken(text: "небо", timestamp: 38.5, duration: 0.4, confidence: 0.88, languageCode: "ru"),
            AIWordToken(text: "алмазы", timestamp: 39.1, duration: 0.5, confidence: 0.72, languageCode: "ru"),
            AIWordToken(text: "свет", timestamp: 44.0, duration: 0.4, confidence: 0.84, languageCode: "ru"),
            AIWordToken(text: "темноте", timestamp: 44.6, duration: 0.5, confidence: 0.89, languageCode: "ru")
        ]
        let pauses = [
            AIPauseInterval(start: 0.0, end: 14.8),
            AIPauseInterval(start: 26.0, end: 36.5)
        ]

        let lrc = AILyricsTranscriptionEngine.alignReferenceLinesToAudioTokens(
            referenceLines: referenceLines,
            audioTokens: audioTokens,
            pauses: pauses,
            trackDuration: 52.0
        )
        let parsed = LRCParser.parseSyncedLRC(lrc, includeIntroDots: true)
        XCTAssertTrue(parsed.first?.isInstrumental == true, "15s MV intro MUST render as ••• dots")
        XCTAssertGreaterThanOrEqual(parsed.filter(\.isInstrumental).count, 2, "Both 15s intro and 10.5s mid-song pause MUST render as •••")

        let line1 = parsed.first { $0.text == "I got love, I got love" }
        let line2 = parsed.first { $0.text == "Окутала меня, окутала" }
        let line3 = parsed.first { $0.text == "Небо в алмазах - лето" }
        let line4 = parsed.first { $0.text == "Свет в темноте горит" }
        XCTAssertNotNil(line1)
        XCTAssertNotNil(line2)
        XCTAssertNotNil(line3)
        XCTAssertNotNil(line4)
        XCTAssertEqual(line1?.timestamp ?? -1, 15.2, accuracy: 0.15, "Must preserve exact 15.2s audio-heard timestamp")
        XCTAssertEqual(line2?.timestamp ?? -1, 21.8, accuracy: 0.15, "Must preserve exact 21.8s audio-heard timestamp & fix spelling")
        XCTAssertEqual(line3?.timestamp ?? -1, 38.5, accuracy: 0.15, "Must preserve exact 38.5s audio-heard timestamp after mid-song pause")
        XCTAssertEqual(line4?.timestamp ?? -1, 44.0, accuracy: 0.15)
    }

    // MARK: - Per-Track Persistent AI Lyrics Preference & AI v3 Accuracy Verification Tests

    @MainActor
    func testPerTrackPreferredLyricsModeRemembersAIOnlyForSongsWhereUserEnabledAI() async throws {
        let lyricsService = LyricsService.shared

        let songWithAI = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "PREF_AI_TRACK_A",
            title: "Unique AI Song Alpha",
            artist: "Unique Artist Alpha",
            album: "Single",
            duration: 180.0
        )
        let songWithoutAI = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "PREF_ORIG_TRACK_B",
            title: "Unique Original Song Beta",
            artist: "Unique Artist Beta",
            album: "Single",
            duration: 190.0
        )

        defer {
            lyricsService.setPreferredLyricsMode(.standard, for: songWithAI)
            lyricsService.setPreferredLyricsMode(.standard, for: songWithoutAI)
        }

        // 1. By default, BOTH songs start in original (.standard) mode
        lyricsService.setPreferredLyricsMode(.standard, for: songWithAI)
        lyricsService.setPreferredLyricsMode(.standard, for: songWithoutAI)
        XCTAssertEqual(lyricsService.preferredLyricsMode(for: songWithAI), .standard)
        XCTAssertEqual(lyricsService.preferredLyricsMode(for: songWithoutAI), .standard)

        // 2. User enables AI mode on Song A and AI saves synced lyrics for Song A
        let sampleAILRC = "[00:05.00]ИИ распознал первую строку\n[00:10.00]ИИ распознал вторую строку"
        let savedAI = try XCTUnwrap(lyricsService.saveAILyrics(syncedLRC: sampleAILRC, for: songWithAI))
        XCTAssertTrue(savedAI.isSynchronized)
        lyricsService.setPreferredLyricsMode(.aiAudio, for: songWithAI)
        XCTAssertEqual(lyricsService.preferredLyricsMode(for: songWithAI), .aiAudio)
        XCTAssertEqual(lyricsService.preferredLyricsMode(for: songWithoutAI), .standard, "Enabling AI on Song A MUST NOT enable AI on Song B")

        // 3. User switches to Song B (never used AI!) -> MUST automatically display original (.standard) mode!
        await lyricsService.loadLyrics(for: songWithoutAI)
        XCTAssertEqual(lyricsService.lyricsMode, .standard, "Songs where user never enabled AI MUST stay on original lyrics")

        // 4. User returns to Song A (last listened in AI mode!) -> MUST automatically restore AI mode & saved AI lyrics!
        await lyricsService.loadLyrics(for: songWithAI)
        XCTAssertEqual(lyricsService.lyricsMode, .aiAudio, "Re-playing a song last listened in AI mode MUST reopen AI lyrics automatically")
        XCTAssertNotNil(lyricsService.aiDocument)
        XCTAssertEqual(lyricsService.activeDocument?.syncedLines.first(where: { !$0.isInstrumental })?.text, "ИИ распознал первую строку")

        // 5. User switches Song A back to Original inside the magnifying glass -> next load MUST stay on Original!
        lyricsService.setPreferredLyricsMode(.standard, for: songWithAI)
        await lyricsService.loadLyrics(for: songWithoutAI)
        await lyricsService.loadLyrics(for: songWithAI)
        XCTAssertEqual(lyricsService.lyricsMode, .standard, "Switching Song A back to Original must be remembered on next playback")
    }

    func testAILyricsOutlierAnchorPrunerRejectsImpossibleTimestampJumpsAndKeepsTrueAnchors() {
        // Line 0 @ 10s, Line 1 @ 14s, Line 2 @ 55s (BOGUS outlier jump!), Line 3 @ 18s (wait - monotonic jammed at 55.2s), Line 4 @ 26s
        let noisyAnchors: [Int: TimeInterval] = [
            0: 10.0,
            1: 14.0,
            2: 49.8, // bogus jump +35.8s followed by jammed 0.2s gap to line 3!
            3: 50.0,
            4: 54.0
        ]
        // Another clean case: Line 0 @ 10s, Line 1 @ 10.1s (jammed <0.30s!), Line 2 @ 18s
        let jammedAnchors: [Int: TimeInterval] = [
            0: 10.0,
            1: 10.1,
            2: 18.0,
            3: 22.0
        ]

        let prunedNoisy = AILyricsTranscriptionEngine.pruneOutlierAnchors(noisyAnchors, totalLines: 6, pauses: [])
        XCTAssertNil(prunedNoisy[2], "Bogus +35.8s outlier anchor jammed against next line must be pruned")
        XCTAssertEqual(prunedNoisy[0], 10.0)
        XCTAssertEqual(prunedNoisy[1], 14.0)
        XCTAssertEqual(prunedNoisy[4], 54.0)

        let prunedJammed = AILyricsTranscriptionEngine.pruneOutlierAnchors(jammedAnchors, totalLines: 5, pauses: [])
        XCTAssertNil(prunedJammed[1], "Impossible 0.1s jammed anchor between 10s and 18s must be pruned")
        XCTAssertEqual(prunedJammed[0], 10.0)
        XCTAssertEqual(prunedJammed[2], 18.0)
        XCTAssertEqual(prunedJammed[3], 22.0)
    }

    func testAILyricsWeightedReferenceAlignmentRecoversAfterLongInstrumentalDropAndRepeatedChorus() {
        let referenceLines = [
            "Ночной город зажигает огни",
            "Мы летим по трассе далеко",
            "Тайный проигрыш без слов тут был",
            "Снова припев звучит на всю",
            "Звёзды падают прямо в океан"
        ]
        // Verse 1 heard at 8s & 12s; line 2 completely drowned by loud EDM drop; Chorus & Finale re-locked at 36s & 41s!
        let tokens = [
            AIWordToken(text: "ночной", timestamp: 8.0, duration: 0.4, confidence: 0.90, languageCode: "ru"),
            AIWordToken(text: "город", timestamp: 8.5, duration: 0.4, confidence: 0.88, languageCode: "ru"),
            AIWordToken(text: "огни", timestamp: 9.2, duration: 0.4, confidence: 0.85, languageCode: "ru"),
            AIWordToken(text: "летим", timestamp: 12.2, duration: 0.4, confidence: 0.87, languageCode: "ru"),
            AIWordToken(text: "трассе", timestamp: 12.8, duration: 0.5, confidence: 0.89, languageCode: "ru"),
            // Noise words during drop that shouldn't mis-anchor line 2
            AIWordToken(text: "да", timestamp: 18.0, duration: 0.2, confidence: 0.30, languageCode: "ru"),
            AIWordToken(text: "не", timestamp: 22.0, duration: 0.2, confidence: 0.30, languageCode: "ru"),
            // Chorus re-lock after instrumental drop
            AIWordToken(text: "снова", timestamp: 36.0, duration: 0.4, confidence: 0.91, languageCode: "ru"),
            AIWordToken(text: "припев", timestamp: 36.5, duration: 0.5, confidence: 0.93, languageCode: "ru"),
            AIWordToken(text: "звучит", timestamp: 37.1, duration: 0.4, confidence: 0.88, languageCode: "ru"),
            AIWordToken(text: "звёзды", timestamp: 41.0, duration: 0.4, confidence: 0.90, languageCode: "ru"),
            AIWordToken(text: "океан", timestamp: 41.8, duration: 0.5, confidence: 0.92, languageCode: "ru")
        ]
        let pauses = [AIPauseInterval(start: 0.0, end: 7.5), AIPauseInterval(start: 16.0, end: 34.5)]

        let lrc = AILyricsTranscriptionEngine.alignReferenceLinesToAudioTokens(
            referenceLines: referenceLines,
            audioTokens: tokens,
            pauses: pauses,
            trackDuration: 48.0
        )
        let parsed = LRCParser.parseSyncedLRC(lrc, includeIntroDots: true)
        let line0 = parsed.first { $0.text == "Ночной город зажигает огни" }
        let line3 = parsed.first { $0.text == "Снова припев звучит на всю" }
        let line4 = parsed.first { $0.text == "Звёзды падают прямо в океан" }

        XCTAssertEqual(line0?.timestamp ?? -1, 8.0, accuracy: 0.2)
        XCTAssertEqual(line3?.timestamp ?? -1, 36.0, accuracy: 0.2, "Weighted aligner MUST recover and re-lock at 36.0s after EDM drop")
        XCTAssertEqual(line4?.timestamp ?? -1, 41.0, accuracy: 0.2)
    }

    func testAILyricsAudioOnlyPolishCapitalizesRemovesFillersMergesOrphansAndHandlesMixedLanguages() {
        XCTAssertEqual(
            AILyricsTranscriptionEngine.polishSungLyricLine("  uh привет my friend ээ  "),
            "Привет my friend",
            "Line polish must strip speech fillers and apply Apple Music Sing capitalization"
        )

        let tokens = [
            AIWordToken(text: "uh", timestamp: 4.5, duration: 0.2, confidence: 0.35, languageCode: "en"),
            AIWordToken(text: "привет", timestamp: 5.0, duration: 0.4, confidence: 0.91, languageCode: "ru"),
            AIWordToken(text: "мой", timestamp: 5.5, duration: 0.25, confidence: 0.89, languageCode: "ru"),
            AIWordToken(text: "мир", timestamp: 5.85, duration: 0.35, confidence: 0.92, languageCode: "ru"),
            // Tiny 2-char orphan word 0.8s later -> should merge cleanly into previous line instead of becoming a 1-word line!
            AIWordToken(text: "да", timestamp: 7.0, duration: 0.2, confidence: 0.80, languageCode: "ru"),
            AIWordToken(text: "we", timestamp: 12.0, duration: 0.2, confidence: 0.88, languageCode: "en"),
            AIWordToken(text: "shine", timestamp: 12.3, duration: 0.4, confidence: 0.93, languageCode: "en"),
            AIWordToken(text: "bright", timestamp: 12.8, duration: 0.4, confidence: 0.94, languageCode: "en")
        ]

        let lrc = AILyricsTranscriptionEngine.buildSyncedLRCFromTokens(tokens: tokens, pauses: [], trackDuration: 20.0)
        let parsed = LRCParser.parseSyncedLRC(lrc, includeIntroDots: true)
        let sungTexts = parsed.filter { !$0.isInstrumental }.map(\.text)

        XCTAssertEqual(sungTexts.count, 2, "Tiny orphan 'да' must merge into line 1 instead of producing an awkward 1-word row")
        XCTAssertEqual(sungTexts[0], "Привет мой мир да")
        XCTAssertEqual(sungTexts[1], "We shine bright")
    }

    func testAILyricsTrailingSilenceDetectorTrimsMVOutroToSave30SecondBudget() {
        // 240s MV: 0-12s silent intro | 12-200s active vocals | 200-240s dead credits outro!
        var rms = [Float]()
        for i in 0..<2400 {
            let t = Double(i) * 0.1
            if t >= 12.0 && t <= 200.0 {
                rms.append(0.32)
            } else {
                rms.append(0.002)
            }
        }
        let span = AILyricsTranscriptionEngine.detectVocalActiveSpan(
            rmsFrames: rms,
            frameDuration: 0.1,
            trackDuration: 240.0
        )
        XCTAssertGreaterThanOrEqual(span.start, 10.5)
        XCTAssertLessThanOrEqual(span.start, 12.2)
        XCTAssertGreaterThanOrEqual(span.end, 200.0)
        XCTAssertLessThanOrEqual(span.end, 204.0, "40-second dead MV outro must be trimmed cleanly so AI doesn't waste its 30s budget")
    }

    func testAILyricsContextualAlternativeSelectorPicksDomainWordOverLowConfidenceMistake() {
        let vocab: Set<String> = ["окутала", "алмазах", "starboy", "miyagi"]

        // Low-confidence misheard word promoted to exact vocabulary match from N-best alternatives
        let promoted = AILyricsTranscriptionEngine.selectBestSegmentWord(
            primary: "окутал",
            confidence: 0.42,
            alternatives: ["окутала", "окутали"],
            contextualSet: vocab
        )
        XCTAssertEqual(promoted.word, "окутала")
        XCTAssertGreaterThanOrEqual(promoted.confidence, 0.68)

        // High-confidence word NOT overwritten even if alternatives contain something else
        let preserved = AILyricsTranscriptionEngine.selectBestSegmentWord(
            primary: "лето",
            confidence: 0.91,
            alternatives: ["окутала"],
            contextualSet: vocab
        )
        XCTAssertEqual(preserved.word, "лето")
        XCTAssertEqual(preserved.confidence, 0.91, accuracy: 0.001)
    }

    // MARK: - Badge Layout, Song Trim/Cut Settings, Ad-Free Offline Teardown, Video-ID Ad Catcher & Pure Audio AI Subtitles Tests

    func testProviderBadgeAndCapabilityShortPillLabelsStayCompactSingleLine() {
        XCTAssertEqual(PlaybackCapability.offlineFile.shortPillLabel, "OFFLINE")
        XCTAssertEqual(PlaybackCapability.preview30s.shortPillLabel, "30S")
        XCTAssertNil(PlaybackCapability.directFullAudio.shortPillLabel, "Full Track redundant suffix must be omitted so pills stay compact & single-line")
        XCTAssertNil(PlaybackCapability.embeddedVideo.shortPillLabel)

        XCTAssertEqual(ProviderBadgePill.formattedLabel(provider: .youtubeMusic, capability: .directFullAudio), "YT MUSIC")
        XCTAssertEqual(ProviderBadgePill.formattedLabel(provider: .youtubeMusic, capability: .offlineFile), "YT MUSIC • OFFLINE")
        XCTAssertEqual(ProviderBadgePill.formattedLabel(provider: .appleMusic, capability: .preview30s), "APPLE MUSIC • 30S")
    }

    @MainActor
    func testTrackTrimRangeNormalizationValidationPersistenceAndPlayerEnforcement() {
        // 1. Normalization & minimum 5s segment enforcement
        let invalidTooShort = TrackTrimRange(startSeconds: 50.0, endSeconds: 52.0).normalized(for: 200.0)
        XCTAssertEqual(invalidTooShort.startSeconds, 50.0, accuracy: 0.01)
        XCTAssertEqual(invalidTooShort.endSeconds ?? 0, 55.0, accuracy: 0.01, "Minimum segment length of 5s must be enforced")
        XCTAssertEqual(invalidTooShort.effectiveDuration(for: 200.0), 5.0, accuracy: 0.01)

        let fullSong = TrackTrimRange(startSeconds: 0.0, endSeconds: 199.8).normalized(for: 200.0)
        XCTAssertFalse(fullSong.isEffectivelyTrimmed(for: 200.0))

        let customCut = TrackTrimRange(startSeconds: 15.0, endSeconds: 95.0).normalized(for: 200.0)
        XCTAssertTrue(customCut.isEffectivelyTrimmed(for: 200.0))
        XCTAssertEqual(customCut.formattedRange(for: 200.0), "0:15–1:35")
        XCTAssertEqual(customCut.effectiveDuration(for: 200.0), 80.0, accuracy: 0.01)

        // 2. Persistent storage across provider variants & live player start/end enforcement
        let persistence = PersistenceController.shared
        let engine = UniversalAudioPlayerEngine.shared
        let trimmedTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "TRIM_TEST_VID_1",
            title: "Trimmed Song",
            artist: "Trim Artist",
            album: "Single",
            duration: 200.0,
            isStreamable: true
        )
        let sameTrackAppleVariant = UniversalTrack(
            provider: .appleMusic,
            providerTrackID: "am-trim-1",
            title: "Trimmed Song",
            artist: "Trim Artist",
            album: "Single",
            duration: 200.0
        )
        let nextTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "TRIM_NEXT_VID_2",
            title: "Next Song After Trim",
            artist: "Next Artist",
            album: "Single",
            duration: 180.0,
            isStreamable: true
        )

        defer {
            persistence.setTrimRange(nil, for: trimmedTrack)
            engine.pause()
            engine.activeYouTubeVideoID = nil
            engine.clearQueue()
        }

        persistence.setTrimRange(customCut, for: trimmedTrack)
        XCTAssertTrue(persistence.hasCustomTrim(for: trimmedTrack))
        XCTAssertEqual(persistence.trimRange(for: trimmedTrack), customCut)
        XCTAssertEqual(persistence.trimRange(for: sameTrackAppleVariant), customCut, "Saved trim must persist across provider variants of the same song")

        // Play trimmed track -> must load activeTrackTrimRange & start at 15.0s!
        engine.play(trimmedTrack, queue: [trimmedTrack, nextTrack])
        XCTAssertEqual(engine.activeTrackTrimRange, customCut)
        XCTAssertEqual(engine.currentTime, 15.0, accuracy: 0.25, "Trimmed song MUST start at saved startSeconds")

        // Reaching custom endSeconds (95.0s) MUST immediately finish & advance to the next song in queue!
        engine.evaluateTrimBoundsIfNeeded(at: 95.0)
        XCTAssertEqual(engine.currentTrack?.id, nextTrack.id, "Reaching saved trim endSeconds MUST cleanly end the song and skip to next")

        // Resetting trim restores full song
        persistence.setTrimRange(nil, for: trimmedTrack)
        XCTAssertFalse(persistence.hasCustomTrim(for: trimmedTrack))
        XCTAssertNil(persistence.trimRange(for: trimmedTrack))
    }

    @MainActor
    func testDownloadedOfflineSongCompletelyUnloadsYouTubeWebKitEngineWithZeroAds() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlDir = docs.appendingPathComponent("AuraDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let relPath = "AuraDownloads/offline_no_yt_engine_test.wav"
        let fullURL = docs.appendingPathComponent(relPath)
        try UniversalAudioPlayerEngine.buildSubAudibleKeepAliveWAVData().write(to: fullURL, options: .atomic)

        let offlineTrack = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "OFFLINE_ZERO_YT_01",
            title: "Offline No WebKit Song",
            artist: "Test Artist",
            album: "Test",
            duration: 210.0,
            isStreamable: true
        )
        let engine = UniversalAudioPlayerEngine.shared
        defer {
            engine.pause()
            engine.teardownYouTubeWebViewCompletely()
            OfflineDownloadManager.shared.removeDownload(trackID: offlineTrack.id)
            try? FileManager.default.removeItem(at: fullURL)
        }

        // First simulate an active online YouTube WebView session
        let ytView = AuthorizedYouTubeIFramePlayerView(videoID: "OLD_ONLINE_VID")
        let coord = ytView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coord)
        engine.registerYouTubeWebView(webView)
        engine.activeYouTubeVideoID = "OLD_ONLINE_VID"
        XCTAssertNotNil(engine.activeYouTubeVideoID)

        // Now register offline download and play it -> MUST completely tear down & unmount YouTube WebKit!
        OfflineDownloadManager.shared.registerCompletedDownloadForTesting(track: offlineTrack, relativePath: relPath)
        engine.play(offlineTrack)

        XCTAssertNil(engine.activeYouTubeVideoID, "Downloaded offline track MUST completely unmount YouTube WebKit engine")
        XCTAssertEqual(engine.playbackStatusBanner, "Offline Audio")
        XCTAssertTrue(engine.isPlaying)
    }

    @MainActor
    func testWebKitAdDetectorCatchesServerSideAdByMismatchedVideoID() async throws {
        let playerView = AuthorizedYouTubeIFramePlayerView(videoID: "YkY4X_OaF6o")
        let coordinator = playerView.makeCoordinator()
        let webView = AuthorizedYouTubeIFramePlayerView.makeConfiguredWebView(coordinator: coordinator)
        let navWaiter = TestWKNavigationWaiter()
        webView.navigationDelegate = navWaiter
        defer {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraYT")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navWaiter.continuation = cont
            webView.loadHTMLString(
                "<!doctype html><html><body><div id='movie_player'></div><video id='v' playsinline></video></body></html>",
                baseURL: URL(string: "https://m.youtube.com/watch?v=YkY4X_OaF6o")
            )
        }

        var ready = false
        for _ in 0..<15 {
            if let ok = try? await webView.evaluateJavaScript("typeof window._auraHandleActiveAd === 'function'") as? Bool, ok {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertTrue(ready)

        // Simulate a CSS-less server-side mobile ad (NO .ad-showing class, just a different video_id!)
        let adCatchResult = try await webView.evaluateJavaScript("""
        (function() {
          var mp = document.getElementById('movie_player');
          var v = document.getElementById('v');
          window._auraExpectedVideoID = 'YkY4X_OaF6o';
          mp.getVideoData = function() { return { video_id: 'SECRET_SSAI_AD_123' }; };
          var caught = window._auraHandleActiveAd(v);
          var mutedDuringAd = v.hasAttribute('muted');
          var rateDuringAd = v.playbackRate;

          // Now real song video_id resumes -> must restore normal playback cleanly!
          mp.getVideoData = function() { return { video_id: 'YkY4X_OaF6o' }; };
          var stillAd = window._auraHandleActiveAd(v);
          return {
            caught: caught === true,
            mutedDuringAd: mutedDuringAd === true,
            rateDuringAd: rateDuringAd,
            stillAd: stillAd === true,
            restoredRate: v.playbackRate
          };
        })()
        """) as? [String: Any]

        XCTAssertEqual(adCatchResult?["caught"] as? Bool, true, "Ad detector MUST catch CSS-less ad playing with a different video_id")
        XCTAssertEqual(adCatchResult?["mutedDuringAd"] as? Bool, true, "Mismatched ad video MUST be muted immediately")
        XCTAssertEqual(adCatchResult?["rateDuringAd"] as? Double ?? 0, 16.0, accuracy: 0.1)
        XCTAssertEqual(adCatchResult?["stillAd"] as? Bool, false)
        XCTAssertEqual(adCatchResult?["restoredRate"] as? Double ?? 0, 1.0, accuracy: 0.1)
    }

    func testAISubtitleGeneratorCreatesCleanYouTubeStyleSubtitlesPurelyFromAudioTokensAndBreathValleys() {
        // 10 continuous words with a breath-valley energy dip right between word 5 (t=7.0) and word 6 (t=7.25)
        let tokens: [AIWordToken] = [
            AIWordToken(text: "uh", timestamp: 4.5, duration: 0.2, confidence: 0.30, languageCode: "en"),
            AIWordToken(text: "ночной", timestamp: 5.0, duration: 0.35, confidence: 0.90, languageCode: "ru"),
            AIWordToken(text: "ветер", timestamp: 5.4, duration: 0.35, confidence: 0.88, languageCode: "ru"),
            AIWordToken(text: "несёт", timestamp: 5.8, duration: 0.35, confidence: 0.91, languageCode: "ru"),
            AIWordToken(text: "наши", timestamp: 6.2, duration: 0.35, confidence: 0.87, languageCode: "ru"),
            AIWordToken(text: "голоса", timestamp: 6.6, duration: 0.40, confidence: 0.93, languageCode: "ru"),
            // Small 0.25s breath valley dip in vocalRMS at t=7.0..7.25 -> should split cleanly into subtitle line 2!
            AIWordToken(text: "вверх", timestamp: 7.25, duration: 0.35, confidence: 0.89, languageCode: "ru"),
            AIWordToken(text: "к", timestamp: 7.65, duration: 0.15, confidence: 0.85, languageCode: "ru"),
            AIWordToken(text: "ярким", timestamp: 7.85, duration: 0.35, confidence: 0.91, languageCode: "ru"),
            AIWordToken(text: "звёздам", timestamp: 8.25, duration: 0.45, confidence: 0.94, languageCode: "ru"),
            // Mid-song pause at 9.2..14.0 -> •••
            AIWordToken(text: "we", timestamp: 14.2, duration: 0.2, confidence: 0.90, languageCode: "en"),
            AIWordToken(text: "never", timestamp: 14.45, duration: 0.3, confidence: 0.92, languageCode: "en"),
            AIWordToken(text: "stop", timestamp: 14.8, duration: 0.35, confidence: 0.94, languageCode: "en")
        ]

        // 200 RMS frames (20.0s @ 0.1s/frame) with clear vocal breath dip at 7.0..7.2s and silence 0..4.8s & 9.0..14.0s
        var rms = [Float]()
        for i in 0..<200 {
            let t = Double(i) * 0.1
            if (t >= 5.0 && t < 7.0) || (t >= 7.25 && t <= 8.8) || (t >= 14.2 && t <= 15.5) {
                rms.append(0.35)
            } else {
                rms.append(0.005)
            }
        }
        let pauses = AILyricsTranscriptionEngine.detectPauseIntervals(rmsFrames: rms, frameDuration: 0.1, trackDuration: 20.0)

        let lrc = AILyricsTranscriptionEngine.buildSubtitleStyleLRCFromTokens(
            tokens: tokens,
            pauses: pauses,
            vocalRMSFrames: rms,
            rmsFrameDuration: 0.1,
            trackDuration: 20.0
        )
        let parsed = LRCParser.parseSyncedLRC(lrc, includeIntroDots: true)
        let sung = parsed.filter { !$0.isInstrumental }

        XCTAssertTrue(parsed.first?.isInstrumental == true, "Intro silence must render as •••")
        XCTAssertGreaterThanOrEqual(parsed.filter(\.isInstrumental).count, 2, "Both intro and mid-song vocal pause must render as •••")
        XCTAssertEqual(sung.count, 3, "Breath valley at t=7.0..7.25 must split verse into 2 crisp subtitle lines + 3rd English line")
        XCTAssertEqual(sung[0].text, "Ночной ветер несёт наши голоса")
        XCTAssertEqual(sung[1].text, "Вверх к ярким звёздам")
        XCTAssertEqual(sung[2].text, "We never stop")
    }

    @MainActor
    func testOfflineDownloadDetectsChangedLyricsAndUpdatesOfflineCacheWithoutRedownloadingAudio() async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dlDir = docs.appendingPathComponent("AuraDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let relPath = "AuraDownloads/lyrics_sync_update_test.wav"
        let fullURL = docs.appendingPathComponent(relPath)
        try UniversalAudioPlayerEngine.buildSubAudibleKeepAliveWAVData().write(to: fullURL, options: .atomic)

        let track = UniversalTrack(
            provider: .youtubeMusic,
            providerTrackID: "LYRICS_SYNC_TEST_01",
            title: "Lyrics Update Song",
            artist: "Sync Artist",
            album: "Single",
            duration: 200.0
        )
        let manager = OfflineDownloadManager.shared
        let lyrics = LyricsService.shared

        defer {
            manager.removeDownload(trackID: track.id)
            lyrics.setPreferredLyricsMode(.standard, for: track)
            try? FileManager.default.removeItem(at: fullURL)
        }

        // 1. Register downloaded track initially without synced AI lyrics
        manager.registerCompletedDownloadForTesting(track: track, relativePath: relPath, hasLyrics: true)
        XCTAssertTrue(manager.isDownloaded(track))

        // 2. User generates brand-new AI lyrics & switches song to AI mode -> manager MUST flag update available!
        _ = lyrics.saveAILyrics(syncedLRC: "[00:05.00]Новые ИИ субтитры\n[00:10.00]Вторая строка", for: track)
        lyrics.setPreferredLyricsMode(.aiAudio, for: track)
        XCTAssertTrue(manager.hasLyricsUpdateAvailable(for: track), "Changing lyrics on a downloaded song MUST show 'Докачать обновлённую лирику'")

        // 3. User taps "Докачать обновлённую лирику" -> syncs offline lyrics WITHOUT touching audio file!
        await manager.syncOfflineLyricsForTrack(track)
        XCTAssertFalse(manager.hasLyricsUpdateAvailable(for: track), "After syncing offline lyrics, update flag must clear cleanly")
        XCTAssertEqual(manager.completedLocalRelativePath(for: track), relPath, "Audio file must stay intact without re-downloading")
    }

    func testVocalClarityDSPPreservesHighFrequencyConsonantsWhileSuppressingSubBass() {
        let sr = 16_000.0
        let count = Int(sr * 1.0)
        var sibilantL = [Float](repeating: 0, count: count)
        var sibilantR = [Float](repeating: 0, count: count)
        var bassL = [Float](repeating: 0, count: count)
        var bassR = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let t = Double(i) / sr
            let s = Float(sin(2.0 * Double.pi * 5000.0 * t) * 0.45) // 5 kHz consonant sibilant (S/SH/CH/Щ)
            sibilantL[i] = s
            sibilantR[i] = s

            let b = Float(sin(2.0 * Double.pi * 55.0 * t) * 0.80) // 55 Hz 808 sub-bass
            bassL[i] = b
            bassR[i] = b
        }

        let sibOut = VocalIsolationDSP.processStereoForVocals(left: sibilantL, right: sibilantR, sampleRate: sr).vocalIsolated
        let bassOut = VocalIsolationDSP.processStereoForVocals(left: bassL, right: bassR, sampleRate: sr).vocalIsolated

        let sibRMS = AILyricsTranscriptionEngine.computeRMSEnvelope(samples: sibOut, sampleRate: sr).reduce(0, +)
        let bassRMS = AILyricsTranscriptionEngine.computeRMSEnvelope(samples: bassOut, sampleRate: sr).reduce(0, +)

        XCTAssertGreaterThan(sibRMS, 0.5, "7200 Hz low-pass must preserve 5 kHz vocal sibilants so words stay sharp & recognizable")
        XCTAssertLessThan(bassRMS, sibRMS * 0.35, "4th-order 140 Hz high-pass must suppress 55 Hz 808 sub-bass cleanly")
    }
}
