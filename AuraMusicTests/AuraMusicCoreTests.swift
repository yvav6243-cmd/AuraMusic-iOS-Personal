import XCTest
@testable import AuraMusic

final class AuraMusicCoreTests: XCTestCase {
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
}
