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
}
