import Foundation

/// What Helm on the Mac has open right now, read from the server's background policy
/// (`subscribeBackgroundPolicy`): each desktop window reports the thread it shows, whether it is
/// focused, and the Mac reports whether someone is at it.
struct DesktopPresence: Equatable {
    var threadId: String
    var focused: Bool
    /// Someone used the Mac within the last minute or so, as far as the snapshot can tell.
    var macInUse: Bool
    /// Locked or asleep: nobody is at it, whatever the window says.
    var macAway: Bool

    /// The window to follow: a visible desktop window with a thread open, the focused one first,
    /// then the one that reported last. Nil when no window shows a thread.
    static func from(snapshot: JSON, now: Date = Date()) -> DesktopPresence? {
        struct Candidate { var threadId: String; var focused: Bool; var interacted: Bool; var updatedAt: Date }
        let candidates: [Candidate] = (snapshot["leases"]?.array ?? []).compactMap { lease in
            guard lease["clientKind"]?.string == "desktop-renderer",
                  lease["visible"]?.bool == true,
                  ISODate.parse(lease["expiresAt"]?.string).map({ $0 > now }) ?? false,
                  let threadId = (lease["scopes"]?.array ?? []).first(where: { $0["type"]?.string == "thread" })?["threadId"]?.string
            else { return nil }
            return Candidate(
                threadId: threadId,
                focused: lease["focused"]?.bool ?? false,
                interacted: lease["recentlyInteracted"]?.bool ?? false,
                updatedAt: ISODate.parse(lease["updatedAt"]?.string) ?? .distantPast
            )
        }
        guard let pick = candidates.max(by: { ($0.focused ? 1 : 0, $0.updatedAt) < ($1.focused ? 1 : 0, $1.updatedAt) })
        else { return nil }

        // The Mac's own idle and lock state when the desktop app reports it; otherwise the window's.
        let power = snapshot["hostPower"]
        let known = power?["stale"]?.bool == false
        let away = known && (power?["locked"]?.string == "true" || power?["suspended"]?.bool == true)
        let inUse = known && power?["idle"]?.string != "unknown"
            ? power?["idle"]?.string == "false"
            : pick.interacted
        return DesktopPresence(threadId: pick.threadId, focused: pick.focused, macInUse: inUse && !away, macAway: away)
    }
}
