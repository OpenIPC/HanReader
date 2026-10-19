// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import MediaPlayer

/// Puts the current track on the lock screen, in Control Centre, and on the
/// Mac's Now Playing control, and accepts the commands they send back.
///
/// `MediaPlayer` exists on macOS as well as iOS, so this is shared with no
/// platform branch — which is worth saying because the instinct is to put it
/// behind one.
///
/// ### Updated on transitions only
///
/// Now-playing info is pushed when something a remote control would care
/// about changes — a new track, play, pause, a seek, a speed change — and
/// never on the playback tick. The system extrapolates the playhead from
/// `elapsedPlaybackTime` plus `playbackRate` and the time it received them,
/// so a correct implementation tells it *less* often, not more. Pushing on
/// every tick is both wasted main-actor work and a worse lock screen, since
/// each update restarts the extrapolation.
@MainActor
public final class NowPlayingController {
    private let info: MPNowPlayingInfoCenter
    private let commands: MPRemoteCommandCenter
    /// Weak: the controller is owned alongside the model it drives, and a
    /// strong reference here would make them keep each other alive.
    private weak var model: PlaybackModel?
    private var title: String?
    private var handlers: [MPRemoteCommand: Any] = [:]

    /// Unsubscription, captured for `deinit` — which is nonisolated and so
    /// cannot reach the main-actor dictionary above. Rebuilt when the
    /// handlers are. Same bargain as `AVPlayerAudioEngine.teardown`: nothing
    /// else holds this object by the time it runs.
    private nonisolated(unsafe) var teardown: (() -> Void)?

    /// No injection point, deliberately. `MPNowPlayingInfoCenter` and
    /// `MPRemoteCommandCenter` are process-wide singletons that cannot be
    /// substituted meaningfully, and exposing them would put MediaPlayer
    /// types in this module's public API for no testing benefit. What is
    /// worth testing here — that state is pushed on transitions and not on
    /// ticks — is a property of `PlaybackModel.onStateChange`, and is tested
    /// there.
    public init() {
        info = .default()
        commands = .shared()
    }

    deinit {
        teardown?()
    }

    /// Starts reflecting a model, and accepting commands on its behalf.
    public func attach(to model: PlaybackModel, title: String?) {
        self.model = model
        self.title = title
        subscribe()
        model.onStateChange = { [weak self] in self?.update() }
        update()
    }

    /// Clears the lock screen when the reader closes the text.
    public func detach() {
        model?.onStateChange = nil
        model = nil
        title = nil
        info.nowPlayingInfo = nil
    }

    // MARK: - Pushing state out

    private func update() {
        guard let model, model.state == .ready else {
            info.nowPlayingInfo = nil
            return
        }
        var now: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "Audio",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.playhead,
            // Zero while paused, and the *actual* speed while playing. A
            // lock screen told `1.0` for a track playing at 1.5× drifts
            // visibly, because it is extrapolating from what we said.
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? model.rate.rawValue : 0,
        ]
        if model.duration > 0 {
            now[MPMediaItemPropertyPlaybackDuration] = model.duration
        }
        info.nowPlayingInfo = now
    }

    // MARK: - Taking commands in

    private func subscribe() {
        guard handlers.isEmpty else { return }
        add(commands.playCommand) { $0.play() }
        add(commands.pauseCommand) { $0.pause() }
        add(commands.togglePlayPauseCommand) { $0.toggle() }
        add(commands.skipForwardCommand) { $0.skip(by: Self.skipInterval) }
        add(commands.skipBackwardCommand) { $0.skip(by: -Self.skipInterval) }

        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]

        // Dragging the lock screen scrubber. One seek, at the end of the
        // drag, for the same reason the in-app scrubber commits once.
        let changePosition = commands.changePlaybackPositionCommand
        changePosition.isEnabled = true
        handlers[changePosition] = changePosition.addTarget { [weak self] event in
            guard let model = self?.model,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            model.seek(to: event.positionTime)
            return .success
        }

        let registered = handlers
        teardown = {
            for (command, handler) in registered {
                command.removeTarget(handler)
            }
        }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping (PlaybackModel) -> Void) {
        command.isEnabled = true
        handlers[command] = command.addTarget { [weak self] _ in
            guard let model = self?.model else { return .noActionableNowPlayingItem }
            action(model)
            return .success
        }
    }

    /// Matches the in-app transport, because a reader who learns that the
    /// button moves ten seconds should not find a different number on the
    /// lock screen.
    public static let skipInterval = 10.0
}
