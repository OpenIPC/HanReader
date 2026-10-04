// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// Namespace for the `HanReaderPlatform` module.
///
/// The AppKit/UIKit shim, and deliberately the smallest module in the package.
/// A fat platform shim is a design smell meaning the UI layer has leaked, so
/// two things that look like they belong here explicitly do not: file import,
/// because SwiftUI's `.fileImporter` behaves identically on both platforms and
/// handles security-scoped URLs itself; and menu commands, because `.commands`
/// compiles on iOS too and `FocusedValue` gives correct per-window behaviour
/// that a `NotificationCenter` broadcast cannot.
///
/// - Note: This is scaffolding. The shims arrive alongside the UI in M5.
public enum HanReaderPlatform {
    /// Proves at compile time that this module links `HanReaderCore`.
    public static let coreVersion = HanReaderCore.version
}
