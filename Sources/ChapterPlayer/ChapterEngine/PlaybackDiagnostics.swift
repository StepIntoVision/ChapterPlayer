//
//  PlaybackDiagnostics.swift
//  ChapterPlayer
//
//  HOW LOUD THE HEADSET IS ABOUT TIMING (OD-63).
//
//  The owner's rule: notes only when something is wrong. A scheduled action
//  that fires on time and a cut that lands are routine, so they log at
//  `.debug` and `.info`, which the system does not keep. An action that fires
//  clearly late logs at `.error`, which it does keep. Lateness itself is
//  measured by signpost intervals that stay on in Release, so a tester
//  build can be profiled in Instruments without a Debug build.
//
//  Signposts, subsystem `Bundle.main.bundleIdentifier`, category
//  `PlaybackTiming`:
//
//    "Action Scheduled to Fired"  from the moment the engine arms its wake
//                                 for a scheduled action to the moment it
//                                 fires; the end message carries the
//                                 lateness in milliseconds.
//    "Play to On Screen"          from a Screen's play to the reveal of its
//                                 first frame; the end message says how the
//                                 cut landed.
//

import Foundation
import OSLog

public enum PlaybackDiagnostics {

    /// An action this late is clearly late: past it, the owner gets a saved
    /// note.
    public static let lateThresholdMilliseconds: Double = 100

    /// The level a fired scheduled action logs at.
    ///
    /// A seek's catch-up fires every action it skipped over late ON PURPOSE,
    /// so that lateness is not a fault and stays at `.debug`.
    public static func timingLevel(lateMilliseconds: Double, catchingUp: Bool) -> OSLogType {
        guard !catchingUp else { return .debug }
        return lateMilliseconds > lateThresholdMilliseconds ? .error : .debug
    }

    /// The signposter both intervals use. Not behind `#if DEBUG`: OD-63 asks
    /// for lateness to be measurable in Release, and a signpost costs next to
    /// nothing while Instruments is not recording.
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
        category: "PlaybackTiming"
    )
}
