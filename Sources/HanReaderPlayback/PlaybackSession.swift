// HanReader — MIT licensed. See LICENSE.

import AVFoundation
import Foundation
import HanReaderCore

/// Something that happened to the audio route or to the system's idea of who
/// owns the speaker.
public enum PlaybackInterruption: Sendable, Equatable {
    /// A call, an alarm, another app taking over.
    case began
    /// The interruption ended and the system says it is our turn again.
    case ended
    /// The device that was playing went away — headphones unplugged, a
    /// Bluetooth speaker walked out of range.
    case outputGone
}

/// The system's audio session, where there is one.
///
/// This is the one genuine divergence in the media stack: iOS requires a
/// category, an activation, and two notification subscriptions before a
/// sound can be made politely, while macOS requires none of it. Behind a
/// protocol so the model above it has no platform branch at all, and so a
/// test can deliver an interruption without a phone call.
public protocol PlaybackSession: AnyObject {
    /// Called on the first `play()`, never at launch.
    func activate() throws
    func deactivate()
    var onInterruption: ((PlaybackInterruption) -> Void)? { get set }
}

/// The real one. Everything inside the `#if` is iOS-only by necessity rather
/// than by preference — `AVAudioSession` does not exist on macOS, where the
/// system mixes applications without being asked.
public final class SystemPlaybackSession: PlaybackSession {
    public var onInterruption: ((PlaybackInterruption) -> Void)?

    #if os(iOS)
        private var observers: [any NSObjectProtocol] = []

        /// How many transports are using the shared session.
        ///
        /// `AVAudioSession` is one per process, so the obvious implementation
        /// — deactivate when I am done — stops the *other* window's narration
        /// on an iPad with two texts open. Counted instead, and released only
        /// by the last one out.
        private static var users = 0

        /// Unsubscription, captured so `deinit` can run it.
        ///
        /// `deinit` is nonisolated and this class is not, so it cannot reach
        /// the array above — the same bargain as `AVPlayerAudioEngine`'s. It
        /// is needed only on iOS, which is why the macOS build compiled
        /// happily and CI was the first to say otherwise.
        private nonisolated(unsafe) var teardown: (() -> Void)?
    #endif

    /// Whether this session holds an activation of its own, so a repeated
    /// activate or a deactivate without one cannot unbalance the count.
    private var isActive = false

    public init() {}

    deinit {
        #if os(iOS)
            teardown?()
        #endif
    }

    public func activate() throws {
        guard !isActive else { return }
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // `.spokenAudio` rather than plain `.playback`: it tells the system
            // this is speech, so a navigation prompt ducks it rather than talking
            // over it, and the "pause spoken audio" accessory controls apply.
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            Self.users += 1
            subscribe()
        #endif
        isActive = true
    }

    public func deactivate() {
        guard isActive else { return }
        isActive = false
        #if os(iOS)
            Self.users -= 1
            // Only the last transport out puts the session down. Deactivating
            // it while another window is still playing through it stops that
            // window's narration, which is this fix in reverse.
            guard Self.users <= 0 else { return }
            Self.users = 0
            // Notifying others is what lets the music the reader interrupted
            // start itself again. Failing here is not worth surfacing: the
            // session is already idle and the reader has nothing to do about it.
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation,
            )
        #endif
    }

    #if os(iOS)
        private func subscribe() {
            guard observers.isEmpty else { return }
            let centre = NotificationCenter.default
            observers.append(centre.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main,
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    self?.send(.began)
                case .ended:
                    // Only when the system says so. Resuming after an
                    // interruption we were not invited back from is how an app
                    // ends up talking over a phone call.
                    let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if AVAudioSession.InterruptionOptions(rawValue: options)
                        .contains(.shouldResume)
                    {
                        self?.send(.ended)
                    }
                @unknown default:
                    break
                }
            })
            observers.append(centre.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main,
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      reason == .oldDeviceUnavailable
                else { return }
                self?.send(.outputGone)
            })

            let registered = observers
            teardown = {
                for observer in registered {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        private func send(_ interruption: PlaybackInterruption) {
            Task { @MainActor [weak self] in
                self?.onInterruption?(interruption)
            }
        }
    #endif
}
