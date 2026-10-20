// HanReader — MIT licensed. See LICENSE.

import AVFoundation
public import Foundation

/// The shape of a recording, at the resolution a strip can draw.
///
/// One peak per bucket of equal duration. Not samples: a two-minute file at
/// 44.1 kHz is five million of them and a strip is a few hundred points
/// wide, so the only honest thing to keep is the loudest value in each
/// bucket — which is what makes a syllable visible as a bump and a pause as
/// a flat.
public nonisolated struct WaveformPeaks: Sendable, Hashable {
    /// Zero to one, one per bucket, in time order.
    public let values: [Float]
    /// Seconds the whole run covers, so a bucket's time can be worked out
    /// without knowing how many there are.
    public let duration: Double

    public init(values: [Float], duration: Double) {
        self.values = values
        self.duration = duration
    }

    public static let empty = Self(values: [], duration: 0)

    /// A scaled time as an index into `values`.
    ///
    /// Clamped at both ends, because a span can sit wholly outside the
    /// recording: the editor asks for exactly that the moment a phrase's
    /// times outlive the file they were measured against, as when a
    /// narration is replaced by a shorter one.
    private static func index(_ value: Double, upTo count: Int) -> Int {
        guard value > 0 else { return 0 }
        guard value < Double(count) else { return count }
        return Int(value)
    }

    public var isEmpty: Bool {
        values.isEmpty || duration <= 0
    }

    /// The loudest sample in the bucket covering `time`, or zero outside the
    /// recording.
    ///
    /// The guard is what keeps the index in range: a time below `duration`
    /// cannot scale to a bucket at or past the end. There is deliberately no
    /// second clamp behind it — a clamp that can never fire reads as though
    /// the bound were in doubt, and the next person to touch this would have
    /// to work out which of the two was load-bearing.
    public func value(at time: Double) -> Float {
        guard !isEmpty, time >= 0, time < duration else { return 0 }
        return values[Int(time / duration * Double(values.count))]
    }

    /// The peaks covering a span, resampled to `count` buckets.
    ///
    /// Resampled rather than sliced because a strip has a fixed width and
    /// the span it shows changes with the phrase: taking the maximum across
    /// each output bucket keeps a short transient visible when zoomed out,
    /// which averaging would smooth away into a flat line.
    public func resampled(over span: Range<Double>, count: Int) -> [Float] {
        guard !isEmpty, count > 0 else {
            return Array(repeating: 0, count: max(0, count))
        }
        let width = (span.upperBound - span.lowerBound) / Double(count)
        return (0 ..< count).map { bucket in
            let from = span.lowerBound + Double(bucket) * width
            let scale = Double(values.count) / duration
            // Both ends clamped into the array, and the upper end clamped
            // against the lower one as well. A span that starts past the end
            // of the recording would otherwise produce a lower bound above
            // its upper bound, and `Range` traps on that rather than coming
            // back empty.
            // Floor and ceiling, not truncation at both ends: an output
            // bucket narrower than a stored one would otherwise land on the
            // same index twice and draw nothing where there is signal.
            //
            // The ceiling can never fall below the floor — the span has
            // width and both are clamped the same way — so the range cannot
            // invert. It can be empty, which is what a span outside the
            // recording comes to, and that is the case the guard is for.
            let lower = Self.index((from * scale).rounded(.down), upTo: values.count)
            let upper = Self.index(((from + width) * scale).rounded(.up), upTo: values.count)
            let range = lower ..< upper
            guard !range.isEmpty else { return 0 }
            return values[range].max() ?? 0
        }
    }
}

/// Reads a recording's shape, once, so it can be drawn.
///
/// Separate from `AudioEngine`: the transport plays a file and this measures
/// one, and the only screen that draws a waveform is the boundary editor.
/// Nothing else in the app has ever needed the samples.
public enum WaveformReader {
    /// How many buckets a whole file is reduced to.
    ///
    /// Fixed rather than derived from the view's width, because the strip
    /// zooms: it shows a few seconds around one phrase, and a file-wide
    /// resolution matched to the window would be far too coarse once
    /// zoomed in. 12,000 over a two-minute file is about a hundred a
    /// second — fine enough to see a syllable, and a 48 KB array.
    public static let bucketCount = 12000

    /// Measures `url` and returns one peak per bucket.
    ///
    /// Runs off the main actor and checks for cancellation between blocks,
    /// because a reader who moves to another text while this is running
    /// should not be waiting on it.
    public static func peaks(
        of url: URL,
        buckets: Int = bucketCount,
    ) async throws
        -> WaveformPeaks
    {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return .empty
        }
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        guard duration.isFinite, duration > 0, buckets > 0 else { return .empty }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return .empty }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        defer { reader.cancelReading() }

        let values = try fill(buckets, from: output, over: duration)
        if reader.status == .failed {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        return WaveformPeaks(values: normalised(values), duration: duration)
    }

    /// Mono float, so one sample is one number and there is no channel
    /// interleaving to unpick. The strip draws one line, so mixing the
    /// channels down is what it wants anyway.
    private static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
    }

    /// Reads every sample, keeping the loudest in each bucket.
    private static func fill(
        _ buckets: Int,
        from output: AVAssetReaderTrackOutput,
        over duration: Double,
    ) throws
        -> [Float]
    {
        var values = [Float](repeating: 0, count: buckets)
        var samplesSeen = 0
        // Worked out from the first buffer's sample rate rather than
        // assumed: an mp3 at 24 kHz and an m4a at 44.1 kHz would otherwise
        // fill the array at different speeds and one of them would end
        // half empty.
        var expectedSamples = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if expectedSamples == 0 {
                guard let rate = sampleRate(of: buffer), rate > 0 else { continue }
                expectedSamples = rate * duration
            }
            for sample in samples(of: buffer) {
                // The bucket is a *fraction* of the file rather than a
                // fixed number of samples. Integer division would make each
                // bucket cover slightly less audio than `resampled` assumes
                // — `duration / values.count` — and the error accumulates,
                // so the far end of a long recording would be drawn out of
                // step with what plays there.
                let bucket = Int(Double(samplesSeen) / expectedSamples * Double(buckets))
                samplesSeen += 1
                guard bucket < buckets else { break }
                values[bucket] = max(values[bucket], abs(sample))
            }
        }
        return values
    }

    private static func sampleRate(of buffer: CMSampleBuffer) -> Double? {
        CMSampleBufferGetFormatDescription(buffer)
            .flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
            }
    }

    private static func samples(of buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        guard CMBlockBufferCopyDataBytes(
            block,
            atOffset: 0,
            dataLength: length,
            destination: &data,
        ) == kCMBlockBufferNoErr else { return [] }
        return data
    }

    /// Scales the loudest point to one.
    ///
    /// A quiet recording is otherwise a flat line in the strip, which tells
    /// the reader nothing about where the words are — and where the words
    /// are is the only reason the strip is drawn. Absolute level is not the
    /// question here; relative shape is.
    static func normalised(_ values: [Float]) -> [Float] {
        guard let loudest = values.max(), loudest > 0 else { return values }
        return values.map { $0 / loudest }
    }
}
