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
        // Only the controller that currently owns the lock screen may clear
        // it. Another window may have claimed it since, and wiping its
        // Now Playing item on the way out would be this bug in reverse.
        guard Self.commandTarget === self else { return }
        Self.commandTarget = nil
        info.nowPlayingInfo = nil
    }

    // MARK: - Pushing state out

    private func update() {
        guard Self.commandTarget === self else { return }
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

    /// The controller remote commands act on.
    ///
    /// `MPRemoteCommandCenter` is process-wide, so registering handlers per
    /// window meant a lock-screen play reaching *every* open window's
    /// transport at once. There is only one lock screen and only one Now
    /// Playing item, so there is only one controller it can sensibly mean:
    /// the one that most recently claimed it. Weak, so a closed window's
    /// controller does not keep itself alive as the target of commands it
    /// can no longer serve.
    private weak static var commandTarget: NowPlayingController?

    private func subscribe() {
        Self.commandTarget = self
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
        handlers[changePosition] = changePosition.addTarget { event in
            guard let model = Self.commandTarget?.model,
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
        // Routed through the shared target rather than through `self`, so a
        // command reaches the window that owns the lock screen rather than
        // every window that ever opened a narrated text.
        handlers[command] = command.addTarget { _ in
            guard let model = Self.commandTarget?.model else {
                return .noActionableNowPlayingItem
            }
            action(model)
            return .success
        }
    }

    /// Matches the in-app transport, because a reader who learns that the
    /// button moves ten seconds should not find a different number on the
    /// lock screen.
    public static let skipInterval = 10.0
}
