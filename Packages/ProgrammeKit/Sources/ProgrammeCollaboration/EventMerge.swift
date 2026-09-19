import Foundation
import ProgrammeCore

/// Deterministic merge policy for two versions of the same event.
///
/// Independent EventIDs union at the set level (handled by the applier);
/// this type decides one same-ID pair. Rules, in order:
///
/// 1. Higher explicit revision supersedes a lower one.
/// 2. Identical revisions with identical content are idempotent.
/// 3. Identical revisions with different content are a real conflict: the
///    applier must surface Needs Review, never silently rewrite history.
///
/// Wall-clock time never decides. Calculated scores and statistics are never
/// merged — after reconciliation the applier re-derives everything through
/// StatEngine from event truth.
public enum EventMerge: Hashable, Sendable {
    /// Remote supersedes local; apply the remote event.
    case takeRemote(MatchEvent)
    /// Local stands; nothing to apply.
    case keepLocal
    /// Same revision, contradictory content. Surface for human review with
    /// both versions preserved. Never auto-resolve.
    case conflict(local: MatchEvent, remote: MatchEvent)

    public static func reconcile(local: MatchEvent, remote: MatchEvent) -> EventMerge {
        precondition(local.id == remote.id, "EventMerge reconciles one same-ID pair")
        if remote.revision > local.revision { return .takeRemote(remote) }
        if local.revision > remote.revision { return .keepLocal }
        if local == remote { return .keepLocal }
        return .conflict(local: local, remote: remote)
    }
}
