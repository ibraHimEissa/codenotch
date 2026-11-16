import XCTest
@testable import Codenotch

final class DiffStatsTests: XCTestCase {
    func testNumstatCountsFilesAndLines() {
        let numstat = "12\t3\tSources/A.swift\n0\t7\tSources/B.swift\n-\t-\tAssets/icon.png\n"
        XCTAssertEqual(DiffStats.parse(numstat: numstat),
                       DiffStats(files: 3, added: 12, removed: 10))
    }

    func testEmptyNumstatIsEmpty() {
        XCTAssertTrue(DiffStats.parse(numstat: "").isEmpty)
    }

    func testAPathWithATabIsStillOneFile() {
        let stats = DiffStats.parse(numstat: "1\t1\tweird\tname.txt\n")
        XCTAssertEqual(stats, DiffStats(files: 1, added: 1, removed: 1))
    }

    func testReadingOutsideARepositoryIsNil() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffstats-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(DiffStatsReader.read(in: folder.path))
    }
}
