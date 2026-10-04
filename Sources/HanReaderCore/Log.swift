// HanReader — MIT licensed. See LICENSE.

import Foundation

/// How serious a log message is.
public enum LogLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Detail useful while working on something, off by default.
    case debug
    /// Something worth knowing that is not a problem.
    case info
    /// Something went wrong and was handled.
    case error

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LogMessage: Sendable, Hashable {
    public let level: LogLevel
    /// A short subsystem name, so output can be filtered: `dictionary`,
    /// `import`, `playback`.
    public let category: String
    public let text: String

    public init(level: LogLevel, category: String, text: String) {
        self.level = level
        self.category = category
        self.text = text
    }
}

/// Somewhere log messages go.
public protocol LogSink: Sendable {
    func write(_ message: LogMessage)
}

/// The default sink: one line per message on standard error.
///
/// Standard error rather than `os.Logger`, because this module imports only
/// Foundation — a CI job compiles it on Linux to keep that true. An app that
/// wants unified logging installs a sink from `HanReaderPlatform`, which is
/// exactly what the seam is for.
public struct StandardErrorLogSink: LogSink {
    public let minimumLevel: LogLevel

    public init(minimumLevel: LogLevel = .info) {
        self.minimumLevel = minimumLevel
    }

    public func write(_ message: LogMessage) {
        guard message.level >= minimumLevel else { return }
        let line = "[\(message.category)] \(message.text)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Where the application's diagnostics go.
///
/// This exists because SwiftLint forbids `print` across every module and tells
/// the author to use "the logger in HanReaderCore" — and for a while there was
/// no such thing, which made the rule a sign pointing at an empty room. The
/// predecessor prototype's error handling was seven `print` calls, so the rule
/// is worth keeping; it just needed somewhere to send people.
///
/// Deliberately tiny. It is a seam, not a logging framework: no formatting, no
/// subsystems, no privacy annotations. Everything beyond "write this line
/// somewhere a developer can find it" belongs to whatever sink the app
/// installs.
public enum Log {
    /// Replaces the sink. Call once, early.
    public static func install(_ sink: some LogSink) {
        box.replace(with: sink)
    }

    public static func debug(_ category: String, _ text: @autoclosure () -> String) {
        write(.debug, category, text)
    }

    public static func info(_ category: String, _ text: @autoclosure () -> String) {
        write(.info, category, text)
    }

    public static func error(_ category: String, _ text: @autoclosure () -> String) {
        write(.error, category, text)
    }

    /// The message is built lazily, so a log call on a hot path costs a
    /// function call rather than a string interpolation when nothing is
    /// listening.
    private static func write(
        _ level: LogLevel,
        _ category: String,
        _ text: () -> String,
    ) {
        box.current.write(LogMessage(level: level, category: category, text: text()))
    }
}

/// The one sink, at file scope.
///
/// A file-scope constant of a `Sendable` type needs no isolation annotation
/// at all, because `HanReaderCore` has no default isolation — which is the
/// same property that lets it compile on Linux. As a `static` member it
/// would need `nonisolated(unsafe)` for no benefit.
private let box = SinkBox()

/// Holds the current sink behind a lock.
///
/// `NSLock` rather than `Mutex`: `Synchronization` needs macOS 15, and this
/// package supports macOS 14. Unchecked `Sendable` is the point of the type —
/// the lock is what makes the promise true, and keeping it to one small class
/// is what keeps that promise checkable by reading it.
private final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: any LogSink = StandardErrorLogSink()

    var current: any LogSink {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }

    func replace(with sink: some LogSink) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }
}
