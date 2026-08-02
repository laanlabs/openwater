import OpenWaterCore
import XCTest
@testable import openWater

/// The block-maximum index behind the trim preview.
///
/// It exists purely to keep a dragging thumb responsive, which means the only
/// thing that matters about it is that it is *exactly* right — a fast maximum
/// that is occasionally wrong would show a rider a peak speed their saved
/// session then disagrees with, and they would have no way to tell which one
/// lied. The block arithmetic around partial head and tail blocks is the sort
/// that is wrong by one and looks fine, so it is checked against brute force
/// over every interesting range shape.
final class TrimPreviewIndexTests: XCTestCase {

    /// A deterministic pseudo-random speed profile, so a failure is repeatable.
    private func speeds(count: Int) -> [Double] {
        var value: UInt64 = 0x5DEECE66D
        return (0..<count).map { _ in
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Double((value >> 33) % 3000) / 100
        }
    }

    private func track(count: Int) -> Track {
        let speeds = speeds(count: count)
        return Track(
            points: (0..<count).map { i in
                TrackPoint(
                    timestamp: Date(timeIntervalSince1970: Double(i)),
                    latitude: 45 + Double(i) * 1e-5,
                    longitude: -120,
                    speed: speeds[i],
                    horizontalAccuracy: 5
                )
            },
            elapsed: (0..<count).map(Double.init),
            cumulativeDistance: (0..<count).map { Double($0) * 10 },
            speed: speeds,
            course: Array(repeating: 90, count: count),
            speedSource: .doppler,
            quality: .unknown
        )
    }

    func testMatchesBruteForceOverEveryRangeShape() {
        // 501 samples: not a multiple of the 64-sample block, so the final
        // block is partial and every off-by-one has somewhere to hide.
        let track = track(count: 501)
        let index = TrimPreview.Index(track: track)

        var checked = 0
        for lower in stride(from: 0, to: track.count, by: 7) {
            for length in [0, 1, 2, 63, 64, 65, 127, 128, 191, 300] {
                let upper = lower + length
                guard upper < track.count else { continue }
                let expected = track.speed[lower...upper].max() ?? 0
                let actual = index.maximum(in: lower...upper, speeds: track.speed)
                XCTAssertEqual(actual, expected, accuracy: 1e-9,
                               "range \(lower)...\(upper)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 300, "the sweep should actually cover something")
    }

    func testWholeTrack() {
        let track = track(count: 4096)
        let index = TrimPreview.Index(track: track)
        XCTAssertEqual(
            index.maximum(in: 0...(track.count - 1), speeds: track.speed),
            track.speed.max() ?? 0,
            accuracy: 1e-9
        )
    }

    func testSingleSample() {
        let track = track(count: 200)
        let index = TrimPreview.Index(track: track)
        for i in [0, 63, 64, 65, 199] {
            XCTAssertEqual(index.maximum(in: i...i, speeds: track.speed),
                           track.speed[i], accuracy: 1e-9, "at \(i)")
        }
    }

    func testTrackShorterThanOneBlock() {
        let track = track(count: 10)
        let index = TrimPreview.Index(track: track)
        XCTAssertEqual(index.maximum(in: 2...7, speeds: track.speed),
                       track.speed[2...7].max() ?? 0, accuracy: 1e-9)
    }

    /// The preview reads the same numbers whether or not the index is there.
    func testPreviewAgreesWithTheUnindexedPath() {
        let track = track(count: 1500)
        let index = TrimPreview.Index(track: track)

        for range in [100.0...800.0, 0.0...1499.0, 700.0...760.0] {
            for isRemoval in [false, true] {
                let fast = TrimPreview(track: track, index: index, range: range, isRemoval: isRemoval)
                let slow = TrimPreview(track: track, index: nil, range: range, isRemoval: isRemoval)
                XCTAssertEqual(fast.maxSpeed, slow.maxSpeed, accuracy: 1e-9)
                XCTAssertEqual(fast.distance, slow.distance, accuracy: 1e-9)
                XCTAssertEqual(fast.averageSpeed, slow.averageSpeed, accuracy: 1e-9)
            }
        }
    }
}
