import Foundation

/// The user's arrangement of pinned and active threads: base-26 order keys compared as plain
/// strings, a port of client-runtime's `threadSort.ts`. A move writes one key to the moved
/// thread on its own server, so every client of that server converges on the same order.
enum OrderKeys {
    private static let digits = Array("abcdefghijklmnopqrstuvwxyz".utf8)

    /// Keys are non-empty, `a`–`z`, and never end in `a` (nothing could sort right before them).
    static func isValid(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return !bytes.isEmpty && bytes.allSatisfy(digits.contains) && bytes.last != digits[0]
    }

    /// A key strictly between two neighbours; nil bounds are the open ends. Nil when the keys are
    /// corrupt or out of order, so the caller rewrites the section instead (`pinOrderKeyBetween`).
    static func between(_ before: String?, _ after: String?) -> String? {
        let a = Array((before ?? "").utf8), b = Array((after ?? "").utf8)
        if !a.isEmpty, !isValid(before!) { return nil }
        if !b.isEmpty, !isValid(after!) { return nil }
        if !b.isEmpty, !a.lexicographicallyPrecedes(b) { return nil }
        return String(decoding: midpoint(a[...], b[...]), as: UTF8.self)
    }

    /// Midpoint of two digit strings read as fractions in (0, 1); empty is the open bound.
    private static func midpoint(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> [UInt8] {
        if !b.isEmpty {
            // Recurse past the longest common prefix ("a" pads the shorter side).
            var n = 0
            while n < b.count, (n < a.count ? a[a.startIndex + n] : digits[0]) == b[b.startIndex + n] { n += 1 }
            if n > 0 {
                return Array(b.prefix(n)) + midpoint(a.dropFirst(min(n, a.count)), b.dropFirst(n))
            }
        }
        let digitA = a.first.map { digits.firstIndex(of: $0)! } ?? 0
        let digitB = b.first.map { digits.firstIndex(of: $0)! } ?? digits.count
        if digitB - digitA > 1 {
            // JS Math.round: halves round up.
            return [digits[(digitA + digitB + 1) / 2]]
        }
        if b.count > 1 { return [b.first!] }
        return [digits[digitA]] + midpoint(a.dropFirst(), [])
    }

    /// Evenly spaced keys for materializing a whole section (`generateSpreadPinOrderKeys`).
    static func spread(count: Int) -> [String] {
        let base = digits.count
        var width = 2
        var space = base * base
        while space <= (count + 1) * 2 {
            width += 1
            space *= base
        }
        let step = Double(space) / Double(count + 1)
        return (0..<count).map { index in
            var value = Int((step * Double(index + 1)).rounded(.toNearestOrAwayFromZero))
            // Skip values whose low digit is the minimum (a trailing "a").
            if value % base == 0 { value += 1 }
            var key: [UInt8] = []
            for _ in 0..<width {
                key.insert(digits[value % base], at: 0)
                value /= base
            }
            return String(decoding: key, as: UTF8.self)
        }
    }

    /// Writes that realize `ordered` (the section after the move). One write to the moved thread
    /// when its neighbours are keyed or absent; otherwise the visible section gets fresh spread
    /// keys, writing only those that change. `keys` also holds keys of rows hidden from
    /// `ordered`, which are never reused (`planPinnedReorder`).
    static func plan<ID: Hashable>(ordered: [ID], keys: [ID: String], moved: ID) -> [(id: ID, key: String)] {
        guard let index = ordered.firstIndex(of: moved) else { return [] }
        let visible = Set(ordered)
        let reserved = Set(keys.filter { !visible.contains($0.key) }.map(\.value))
        let beforeId = index > 0 ? ordered[index - 1] : nil
        let afterId = index < ordered.count - 1 ? ordered[index + 1] : nil
        let beforeKey = beforeId.flatMap { keys[$0] }
        let afterKey = afterId.flatMap { keys[$0] }
        if (beforeId == nil || beforeKey != nil) && (afterId == nil || afterKey != nil) {
            var key = between(beforeKey, afterKey)
            while let candidate = key, reserved.contains(candidate) { key = between(candidate, afterKey) }
            if let key { return [(moved, key)] }
        }
        let fresh = spread(count: ordered.count + reserved.count).filter { !reserved.contains($0) }.prefix(ordered.count)
        return zip(ordered, fresh).compactMap { id, key in keys[id] == key ? nil : (id, key) }
    }

    enum Direction { case up, down }

    /// Move up / Move down: swap with the displayed neighbour, then plan. Nil off either end.
    static func planMove<ID: Hashable>(ordered: [ID], keys: [ID: String], moved: ID, _ direction: Direction) -> [(id: ID, key: String)]? {
        guard let from = ordered.firstIndex(of: moved) else { return nil }
        let to = direction == .up ? from - 1 : from + 1
        guard ordered.indices.contains(to) else { return nil }
        var next = ordered
        next.swapAt(from, to)
        let writes = plan(ordered: next, keys: keys, moved: moved)
        return writes.isEmpty ? nil : writes
    }
}

extension ThreadSummary {
    /// Where a keyless active thread sits: new and reopened threads lead the list.
    var activeAnchor: Date { max(createdAt ?? .distantPast, unsettledAt ?? .distantPast) }
}

extension [ThreadListEntry] {
    /// Pinned block: arranged threads by key, then keyless ones newest-created first.
    func sortedPinned() -> [ThreadListEntry] {
        sorted { a, b in
            switch (a.thread.pinOrderKey, b.thread.pinOrderKey) {
            case let (ka?, kb?) where ka != kb: return ka < kb
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let (da, db) = (a.thread.createdAt ?? .distantPast, b.thread.createdAt ?? .distantPast)
                if da != db { return da > db }
                return a.identityPrecedes(b)
            default: return a.identityPrecedes(b)
            }
        }
    }

    /// Active list: keyless (new or reopened) threads first, newest anchor first, then the
    /// arranged ones by key. Activity moves neither group.
    func sortedActive() -> [ThreadListEntry] {
        sorted { a, b in
            switch (a.thread.activeOrderKey, b.thread.activeOrderKey) {
            case let (ka?, kb?) where ka != kb: return ka < kb
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil):
                let (da, db) = (a.thread.activeAnchor, b.thread.activeAnchor)
                if da != db { return da > db }
                return a.identityPrecedes(b)
            default: return a.identityPrecedes(b)
            }
        }
    }
}

extension ThreadListEntry {
    /// Thread ids are only unique per environment; both break ties so every client agrees.
    fileprivate func identityPrecedes(_ other: ThreadListEntry) -> Bool {
        (ref.threadId, ref.environmentId) < (other.ref.threadId, other.ref.environmentId)
    }
}

/// Where a queued message lands for Move up / Move down: `queued-run.reorder` inserts the run
/// right before `beforeRunId`, or at the end when it is nil.
enum QueueOrder {
    /// `.some(nil)` means "to the end"; nil means the move falls off the list.
    static func beforeRunId(_ ids: [String], moving id: String, _ direction: OrderKeys.Direction) -> String?? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        switch direction {
        case .up:
            return index > 0 ? .some(ids[index - 1]) : nil
        case .down:
            guard index < ids.count - 1 else { return nil }
            return .some(index + 2 < ids.count ? ids[index + 2] : nil)
        }
    }

    /// A queue row's place before the drag started.
    struct RowFrame: Equatable {
        var id: String
        var minY: Double
        var height: Double
    }

    /// Where a dragged row would land: before the first other row whose centre is below the
    /// dragged row's centre, `.some(nil)` past the last one; nil for a row that isn't listed
    /// (`threadQueueControlPresentation.ts`).
    static func dragBeforeRunId(_ rows: [RowFrame], moving id: String, translation: Double) -> String?? {
        guard let source = rows.first(where: { $0.id == id }) else { return nil }
        let center = source.minY + source.height / 2 + translation
        return .some(rows.first { $0.id != id && center < $0.minY + $0.height / 2 }?.id)
    }

    /// The `beforeRunId` to send when the drag ends, or nil when the order wouldn't change.
    static func dropBeforeRunId(_ rows: [RowFrame], moving id: String, translation: Double) -> String?? {
        guard let before = dragBeforeRunId(rows, moving: id, translation: translation),
              let index = rows.firstIndex(where: { $0.id == id })
        else { return nil }
        let next = index + 1 < rows.count ? rows[index + 1].id : nil
        return before == next ? nil : .some(before)
    }

    /// The queue after moving `id` right before `beforeRunId` (to the end when nil), as the server does it.
    static func reordered(_ ids: [String], moving id: String, before beforeRunId: String?) -> [String] {
        guard ids.contains(id) else { return ids }
        var result = ids.filter { $0 != id }
        let at = beforeRunId.flatMap { result.firstIndex(of: $0) } ?? result.endIndex
        result.insert(id, at: at)
        return result
    }
}
