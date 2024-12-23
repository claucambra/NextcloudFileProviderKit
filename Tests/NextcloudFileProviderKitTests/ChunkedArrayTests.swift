//
//  ChunkedArrayTests.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-23.
//

@testable import NextcloudFileProviderKit
import XCTest

final class ChunkedArrayTests: XCTestCase {
    // MARK: - chunked(into:)
    func testChunkedEmptyArray() {
        let emptyArray: [Int] = []
        XCTAssertEqual(emptyArray.chunked(into: 3), [])
    }

    func testChunkedSingleElement() {
        let array = [1]
        XCTAssertEqual(array.chunked(into: 3), [[1]])
    }

    func testChunkedExactDivision() {
        let array = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(array.chunked(into: 2), [[1, 2], [3, 4], [5, 6]])
    }

    func testChunkedPartialDivision() {
        let array = [1, 2, 3, 4, 5]
        XCTAssertEqual(array.chunked(into: 2), [[1, 2], [3, 4], [5]])
    }

    func testChunkedInvalidSize() {
        let array = [1, 2, 3]
        XCTAssertEqual(array.chunked(into: 0), [])
        XCTAssertEqual(array.chunked(into: -1), [])
    }

    // MARK: - chunkedMap(into:transform:)
    func testChunkedMap() {
        let array = [1, 2, 3, 4]
        let transformed = array.chunkedMap(into: 2) { $0 * 2 }
        XCTAssertEqual(transformed, [[2, 4], [6, 8]])
    }

    func testChunkedMapEmptyArray() {
        let emptyArray: [Int] = []
        XCTAssertEqual(emptyArray.chunkedMap(into: 2) { $0 * 2 }, [])
    }

    func testChunkedMapInvalidSize() {
        let array = [1, 2, 3]
        XCTAssertEqual(array.chunkedMap(into: 0) { $0 * 2 }, [])
    }

    // MARK: - concurrentChunkedForEach(into:operation:)
    func testConcurrentChunkedForEach() async {
        let array = [1, 2, 3, 4]
        var results = [Int]()
        let resultsQueue =
            DispatchQueue(label: "com.claucambra.NextcloudFileProviderKitTests.resultsQueue")

        await array.concurrentChunkedForEach(into: 2) { element in
            try? await Task.sleep(nanoseconds: 100_000_000) // Simulate work (100ms)
            resultsQueue.sync { results.append(element * 2) }
        }
        let sortedResults = results.sorted()
        let expectedResults = [2, 4, 6, 8]
        XCTAssertEqual(sortedResults, expectedResults)
    }

    func testConcurrentChunkedForEachEmptyArray() async {
        let emptyArray: [Int] = []
        var results = [Int]()
        await emptyArray.concurrentChunkedForEach(into: 2) { element in
            results.append(element)
        }
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - concurrentChunkedCompactMap(into:transform:)
    func testConcurrentChunkedCompactMap() async {
        let array = [1, 2, 3, 4, 5, 6]
        let results = await array.concurrentChunkedCompactMap(into: 2) { $0 % 2 == 0 ? $0 : nil }
        XCTAssertEqual(results.sorted(), [2, 4, 6])
    }

    func testConcurrentChunkedCompactMapEmptyArray() async {
        let emptyArray: [Int] = []
        let results = await emptyArray.concurrentChunkedCompactMap(into: 2) { $0 }
        XCTAssertTrue(results.isEmpty)
    }

    func testConcurrentChunkedCompactMapInvalidSize() async {
        let array = [1, 2, 3]
        let results = await array.concurrentChunkedCompactMap(into: 0) { $0 }
        XCTAssertTrue(results.isEmpty)
    }
}
