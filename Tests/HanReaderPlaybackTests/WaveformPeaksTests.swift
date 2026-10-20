// HanReader — MIT licensed. See LICENSE.

import AVFoundation
import Foundation
import Testing
@testable import HanReaderPlayback

/// The shape of a recording, and the arithmetic that draws a span of it.
///
/// The reading half is exercised against a file written here rather than a
/// committed fixture: an audio fixture would be a binary in the repository
/// for something a few lines of `AVAudioFile` can produce exactly, with the
/// signal known in advance so the assertions can be about values rather than
/// about "it returned something".
@Suite("Waveform peaks")
struct WaveformPeaksTests {
    // MARK: - Reading a file

    /// Writes a mono 44.1 kHz file whose amplitude is `level(second)`.
    private func write(seconds: Int, level: (Int) -> Float) throws -> URL {
        let rate = 44100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for second in 0 ..< seconds {
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(rate),
            ))
            buffer.frameLength = AVAudioFrameCount(rate)
            let amplitude = level(second)
            let channel = try #require(buffer.floatChannelData)
            for frame in 0 ..< Int(rate) {
                // A sine rather than a constant, so the peak per bucket is a
                // real maximum over a varying signal rather than the one
                // value every sample happens to hold.
                let phase = Double(frame) / rate * 440 * 2 * .pi
                channel[0][frame] = amplitude * Float(sin(phase))
            }
            try file.write(from: buffer)
        }
        return url
    }

    @Test("A recording's loud and quiet seconds come back as loud and quiet buckets")
    func readsTheShape() async throws {
        // Loud, silent, half — so the test can tell order, silence and
        // relative level apart.
        let url = try write(seconds: 3) { second in
            switch second {
            case 0: 0.8
            case 1: 0
            default: 0.4
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let peaks = try await WaveformReader.peaks(of: url, buckets: 30)
        #expect(peaks.values.count == 30)
        #expect(abs(peaks.duration - 3) < 0.1)

        // Normalised, so the loudest second reaches one.
        #expect(peaks.value(at: 0.5) > 0.9)
        #expect(peaks.value(at: 1.5) < 0.05)
        // Half the amplitude of the first second, give or take the bucket
        // edges.
        let quiet = peaks.value(at: 2.5)
        #expect(quiet > 0.4 && quiet < 0.6)
    }

    @Test("A file that is not audio comes back empty rather than throwing")
    func notAudio() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Either answer is acceptable — what must not happen is a crash or a
        // hang. An unreadable narration is a file the reader chose, and the
        // screen above shows the failure.
        let peaks = try? await WaveformReader.peaks(of: url, buckets: 10)
        #expect(peaks?.isEmpty ?? true)
    }

    // MARK: - Normalising

    /// A quiet recording is otherwise a flat line, which tells the reader
    /// nothing about where the words are.
    @Test("The loudest point becomes one")
    func normalising() {
        #expect(WaveformReader.normalised([0.1, 0.2, 0.05]) == [0.5, 1.0, 0.25])
    }

    @Test("Silence stays silent rather than dividing by zero")
    func normalisingSilence() {
        #expect(WaveformReader.normalised([0, 0, 0]) == [0, 0, 0])
        #expect(WaveformReader.normalised([]).isEmpty)
    }

    // MARK: - Drawing a span

    private let ramp = WaveformPeaks(
        values: [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25],
        duration: 8,
    )

    @Test("A span is resampled to the width it will be drawn at")
    func resampling() {
        #expect(ramp.resampled(over: 0 ..< 8, count: 4) == [0.25, 0.75, 1, 0.5])
    }

    /// Maximum rather than mean across an output bucket, so a short loud
    /// moment stays visible when the strip is zoomed out — which is exactly
    /// the moment a reader is looking for when they place a boundary.
    @Test("Zooming out keeps a peak rather than averaging it away")
    func resamplingKeepsPeaks() {
        let spike = WaveformPeaks(values: [0, 0, 1, 0, 0, 0, 0, 0], duration: 8)
        #expect(spike.resampled(over: 0 ..< 8, count: 2) == [1, 0])
    }

    @Test("A span narrower than the recording draws only that span")
    func resamplingASpan() {
        #expect(ramp.resampled(over: 4 ..< 8, count: 2) == [1, 0.5])
    }

    /// A span wholly outside the recording used to build a range whose
    /// lower bound was above its upper one, and `Range` traps on that. The
    /// editor asks for exactly this the moment a phrase's times outlive the
    /// recording they were measured against — a narration replaced by a
    /// shorter file.
    @Test("A span outside the recording draws nothing rather than trapping")
    func spanOutsideTheRecording() {
        #expect(ramp.resampled(over: 20 ..< 24, count: 2) == [0, 0])
        #expect(ramp.resampled(over: -9 ..< -1, count: 2) == [0, 0])
        // Straddling the end: the part that exists is drawn, the rest is not.
        let straddling = ramp.resampled(over: 6 ..< 14, count: 2)
        #expect(straddling[0] > 0)
        #expect(straddling[1] == 0)

        // A recording that opens loudly, so "nothing" cannot be mistaken for
        // "the first bucket" — which is what a bucket outside the recording
        // would read if it fell back to the start of the array.
        let loudOpening = WaveformPeaks(values: [1, 0.5, 0.25], duration: 3)
        #expect(loudOpening.resampled(over: 10 ..< 12, count: 2) == [0, 0])
    }

    /// Zoomed in far enough that an output bucket is narrower than an input
    /// one, every bucket still reads the sample under it rather than coming
    /// back empty.
    @Test("Zooming past the stored resolution still draws the signal")
    func resamplingBelowTheStoredResolution() {
        let zoomed = ramp.resampled(over: 4 ..< 4.4, count: 8)
        #expect(zoomed.allSatisfy { $0 == 1 })
    }

    @Test("A span of no width, or no buckets, draws nothing")
    func degenerateSpans() {
        #expect(ramp.resampled(over: 4 ..< 4, count: 3) == [0, 0, 0])
        #expect(ramp.resampled(over: 0 ..< 8, count: 0).isEmpty)
        #expect(WaveformPeaks.empty.resampled(over: 0 ..< 8, count: 2) == [0, 0])
    }

    @Test("A time outside the recording has no value")
    func outsideTheRecording() {
        #expect(ramp.value(at: -1) == 0)
        #expect(ramp.value(at: 8) == 0)
        #expect(ramp.value(at: 100) == 0)
        #expect(WaveformPeaks.empty.value(at: 0) == 0)
    }

    @Test("A time inside the recording reads its own bucket")
    func insideTheRecording() {
        // Eight buckets over eight seconds, so one each.
        #expect(ramp.value(at: 0.5) == 0)
        #expect(ramp.value(at: 4.5) == 1)
        #expect(ramp.value(at: 7.9) == 0.25)
    }
}
