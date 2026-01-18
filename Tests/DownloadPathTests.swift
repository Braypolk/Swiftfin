//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

@testable import Swiftfin
import XCTest

final class DownloadPathTests: XCTestCase {

    // MARK: - Sanitization Tests

    func testSanitizationRemovesIllegalChars() {
        let input = "File: Name/With\\Backslash"
        let expected = "File- Name-With-Backslash"
        XCTAssertEqual(input.sanitizedForFilename, expected)
    }

    func testSanitizationCollapsesSpacesAndDashes() {
        let input = "My  Movie -  Test"
        let expected = "My Movie - Test"
        XCTAssertEqual(input.sanitizedForFilename, expected)

        let inputDashes = "My--Movie---Test"
        let expectedDashes = "My-Movie-Test"
        XCTAssertEqual(inputDashes.sanitizedForFilename, expectedDashes)
    }

    func testSanitizationTrimsWhitespace() {
        let input = "  My Movie  "
        let expected = "My Movie"
        XCTAssertEqual(input.sanitizedForFilename, expected)
    }

    func testSanitizationOfSpecialChars() {
        let input = "What If...?"
        let expected = "What If..."
        XCTAssertEqual(input.sanitizedForFilename, expected)
    }

    // MARK: - URL Path Tests

    func testMoviePathWithYear() {
        let url = URL.movieDownloadFolder(name: "The Matrix", year: 1999)
        // Downloads/movies/The Matrix (1999)
        XCTAssertEqual(url.lastPathComponent, "The Matrix (1999)")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "movies")
    }

    func testMoviePathWithoutYear() {
        let url = URL.movieDownloadFolder(name: "Unknown Movie", year: nil)
        XCTAssertEqual(url.lastPathComponent, "Unknown Movie")
    }

    func testSeriesPath() {
        let url = URL.seriesDownloadFolder(seriesName: "Breaking Bad")
        // Downloads/series/Breaking Bad
        XCTAssertEqual(url.lastPathComponent, "Breaking Bad")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "series")
    }

    func testSeasonPath() {
        let url = URL.seasonDownloadFolder(seriesName: "Breaking Bad", seasonName: "Season 1")
        // Downloads/series/Breaking Bad/seasons/Season 1
        XCTAssertEqual(url.lastPathComponent, "Season 1")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "seasons")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Breaking Bad")
    }

    func testEpisodePath() {
        let url = URL.episodeDownloadFolder(
            seriesName: "Breaking Bad",
            seasonName: "Season 1",
            episodeName: "S01E01 - Pilot"
        )
        // Downloads/series/Breaking Bad/seasons/Season 1/episodes/S01E01 - Pilot
        XCTAssertEqual(url.lastPathComponent, "S01E01 - Pilot")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "episodes")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Season 1")
    }

    // MARK: - Legacy Path Tests (Backwards Compatibility)

    func testLegacyMoviePath() {
        let url = URL.movieDownloadFolder(itemID: "abc-123")
        XCTAssertEqual(url.lastPathComponent, "abc-123")
    }

    func testLegacySeriesPath() {
        let url = URL.seriesDownloadFolder(seriesID: "series-123")
        XCTAssertEqual(url.lastPathComponent, "series-123")
    }
}
