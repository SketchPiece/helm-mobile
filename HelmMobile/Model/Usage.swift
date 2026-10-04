import Foundation

/// Token usage and API-equivalent cost one Mac reads from provider transcripts
/// (`server.getUsageSummary`, contracts/usage.ts), totalled the way shared/usageMerge.ts does.
/// The phone shows one Mac at a time, so there is no cross-Mac de-duplication to do.
enum Usage {
    /// The contract version this client understands; older summaries from v4 on still add up.
    static let contractVersion = 6
    static let compatibleSince = 4

    /// Provider kinds in chart and table order.
    static let providerOrder = ["codex", "claude", "grok", "cursor", "opencode", "antigravity"]

    static func providerLabel(_ kind: String) -> String {
        switch kind {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "grok": "Grok Build"
        case "cursor": "Cursor"
        case "opencode": "OpenCode"
        case "antigravity": "Antigravity"
        default: kind.capitalized
        }
    }

    // MARK: Window

    /// `UsageSummaryInput` for the last `days` calendar days in the phone's zone; one day means
    /// the rolling past 24 hours in hourly buckets (`makeWindow` in shared/usageFormat.ts).
    static func window(days: Int, now: Date = Date(), timeZone: TimeZone = .current) -> JSON {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func day(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
        }
        if days == 1 {
            let until = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
            let since = until.addingTimeInterval(-86_400)
            return [
                "sinceDay": .string(day(since)), "untilDay": .string(day(until)), "timeZone": .string(timeZone.identifier),
                "resolution": "hour", "sinceTime": .string(ISODate.string(since)), "untilTime": .string(ISODate.string(until)),
            ]
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        return [
            "sinceDay": .string(day(start)), "untilDay": .string(day(now)), "timeZone": .string(timeZone.identifier),
            "resolution": "day",
        ]
    }

    // MARK: Summary

    struct Bucket: Hashable {
        var day: String
        var hourStart: String?
        var provider: String
        var model: String
        var uncachedInput: Double
        var cachedInput: Double
        var cacheCreation: Double
        var output: Double
        var reasoning: Double
        var costUsd: Double
        var cacheSavingsUsd: Double
        var categoryCost: (input: Double, cacheRead: Double, cacheWrite: Double, output: Double)?
        var fastCostUsd: Double
        var ultrafastCostUsd: Double
        var speedPremiumUsd: Double
        var costSource: String
        var records: Double
        var unpricedRecords: Double

        var tokens: Double { uncachedInput + cachedInput + cacheCreation + output }

        init?(json: JSON) {
            guard let day = json["day"]?.string, let provider = json["provider"]?.string, let model = json["model"]?.string,
                  let totals = json["totals"] else { return nil }
            self.day = day
            hourStart = json["hourStart"]?.string
            self.provider = provider
            self.model = model
            uncachedInput = totals["uncachedInputTokens"]?.double ?? 0
            cachedInput = totals["cachedInputTokens"]?.double ?? 0
            cacheCreation = totals["cacheCreationTokens"]?.double ?? 0
            output = totals["outputTokens"]?.double ?? 0
            reasoning = totals["reasoningTokens"]?.double ?? 0
            costUsd = json["costUsd"]?.double ?? 0
            cacheSavingsUsd = json["cacheSavingsUsd"]?.double ?? 0
            if let split = json["categoryCostUsd"] {
                categoryCost = (split["input"]?.double ?? 0, split["cacheRead"]?.double ?? 0,
                                split["cacheWrite"]?.double ?? 0, split["output"]?.double ?? 0)
            }
            fastCostUsd = json["fastCostUsd"]?.double ?? 0
            ultrafastCostUsd = json["ultrafastCostUsd"]?.double ?? 0
            speedPremiumUsd = json["speedPremiumUsd"]?.double ?? 0
            costSource = json["costSource"]?.string ?? "unpriced"
            records = json["records"]?.double ?? 0
            unpricedRecords = json["unpricedRecords"]?.double ?? 0
        }

        static func == (a: Bucket, b: Bucket) -> Bool {
            a.day == b.day && a.hourStart == b.hourStart && a.provider == b.provider && a.model == b.model && a.costUsd == b.costUsd
                && a.tokens == b.tokens && a.records == b.records
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(day)
            hasher.combine(hourStart)
            hasher.combine(provider)
            hasher.combine(model)
        }
    }

    struct Summary: Equatable {
        var contractVersion: Int
        var buckets: [Bucket]
        /// Distinct sessions per provider, from the sources (bucket session counts overcount).
        var sessionsByProvider: [String: Double]
        /// Partial or failed scans, worth a line under the chart.
        var sourceMessages: [String]

        init(json: JSON) {
            contractVersion = json["contractVersion"]?.int ?? 0
            buckets = (json["buckets"]?.array ?? []).compactMap(Bucket.init(json:))
            var sessions: [String: Double] = [:]
            var messages: [String] = []
            for source in json["sources"]?.array ?? [] {
                guard let provider = source["fingerprint"]?["provider"]?.string else { continue }
                sessions[provider, default: 0] += source["distinctSessions"]?.double ?? 0
                let status = source["status"]?.string
                if let message = source["message"]?.nonNull?.string, source["action"] == nil,
                   status == "partial" || status == "failed" || provider == "cursor", !messages.contains(message) {
                    messages.append(message)
                }
            }
            sessionsByProvider = sessions
            sourceMessages = messages
        }

        var isCompatible: Bool { contractVersion >= Usage.compatibleSince && contractVersion <= Usage.contractVersion }
    }

    // MARK: Totals

    struct ProviderTotals: Identifiable, Equatable {
        var provider: String
        var costUsd: Double
        var tokens: Double
        var sessions: Double
        var costShare: Double
        var tokenShare: Double
        var id: String { provider }
    }

    struct ModelTotals: Identifiable, Equatable {
        var provider: String
        var model: String
        var costUsd: Double
        var tokens: Double
        var records: Double
        var unpricedRecords: Double
        var costShare: Double
        var id: String { "\(provider) \(model)" }
        /// Every record lacked rates: show "Unpriced" rather than $0.
        var costUnknown: Bool { records > 0 && unpricedRecords >= records }
    }

    /// One bar of the chart: a day, or an hour start for the 24-hour view.
    struct Period: Identifiable, Equatable {
        var key: String
        var costUsd: Double
        var tokens: Double
        var byProvider: [String: (cost: Double, tokens: Double)]
        var id: String { key }

        static func == (a: Period, b: Period) -> Bool { a.key == b.key && a.costUsd == b.costUsd && a.tokens == b.tokens }
    }

    struct Totals: Equatable {
        var costUsd = 0.0
        var uncachedInput = 0.0
        var cachedInput = 0.0
        var cacheCreation = 0.0
        var output = 0.0
        var reasoning = 0.0
        var records = 0.0
        var sessions = 0.0
        var cacheSavingsUsd = 0.0
        var unpricedShare = 0.0
        var cost = (input: 0.0, cacheRead: 0.0, cacheWrite: 0.0, output: 0.0, unsplit: 0.0)
        var speed = (standard: 0.0, fast: 0.0, ultrafast: 0.0, premium: 0.0)
        var providers: [ProviderTotals] = []
        var models: [ModelTotals] = []
        var daily: [Period] = []
        var hourly: [Period] = []

        var tokens: Double { uncachedInput + cachedInput + cacheCreation + output }

        init() {}

        init(_ summary: Summary) {
            var providerCost: [String: (cost: Double, tokens: Double)] = [:]
            var models: [String: ModelTotals] = [:]
            var daily: [String: Period] = [:]
            var hourly: [String: Period] = [:]
            var unpriced = 0.0
            for bucket in summary.buckets {
                let tokens = bucket.tokens
                costUsd += bucket.costUsd
                cacheSavingsUsd += bucket.cacheSavingsUsd
                uncachedInput += bucket.uncachedInput
                cachedInput += bucket.cachedInput
                cacheCreation += bucket.cacheCreation
                output += bucket.output
                reasoning += bucket.reasoning
                records += bucket.records
                unpriced += bucket.unpricedRecords
                if let split = bucket.categoryCost {
                    cost.input += split.input
                    cost.cacheRead += split.cacheRead
                    cost.cacheWrite += split.cacheWrite
                    cost.output += split.output
                }
                speed.fast += bucket.fastCostUsd
                speed.ultrafast += bucket.ultrafastCostUsd
                speed.premium += bucket.speedPremiumUsd

                providerCost[bucket.provider, default: (0, 0)].cost += bucket.costUsd
                providerCost[bucket.provider, default: (0, 0)].tokens += tokens

                let modelKey = "\(bucket.provider) \(bucket.model)"
                var model = models[modelKey] ?? ModelTotals(provider: bucket.provider, model: bucket.model, costUsd: 0, tokens: 0,
                                                            records: 0, unpricedRecords: 0, costShare: 0)
                model.costUsd += bucket.costUsd
                model.tokens += tokens
                model.records += bucket.records
                model.unpricedRecords += bucket.unpricedRecords
                models[modelKey] = model

                Self.add(bucket, key: bucket.day, to: &daily)
                if let hour = bucket.hourStart { Self.add(bucket, key: hour, to: &hourly) }
            }
            sessions = summary.sessionsByProvider.values.reduce(0, +)
            unpricedShare = records == 0 ? 0 : unpriced / records
            cost.unsplit = max(0, costUsd - cost.input - cost.cacheRead - cost.cacheWrite - cost.output)
            speed.standard = max(0, costUsd - speed.fast - speed.ultrafast)
            let total = tokens
            let allProviders = Set(providerCost.keys).union(summary.sessionsByProvider.filter { $0.value > 0 }.keys)
            providers = allProviders.map { provider in
                let value = providerCost[provider] ?? (0, 0)
                return ProviderTotals(provider: provider, costUsd: value.cost, tokens: value.tokens,
                                      sessions: summary.sessionsByProvider[provider] ?? 0,
                                      costShare: costUsd == 0 ? 0 : value.cost / costUsd,
                                      tokenShare: total == 0 ? 0 : value.tokens / total)
            }
            .sorted { ($0.costUsd, $1.provider) > ($1.costUsd, $0.provider) }
            let cost = costUsd
            self.models = models.values.map { model in
                var model = model
                model.costShare = cost == 0 ? 0 : model.costUsd / cost
                return model
            }
            .sorted { $0.costUsd != $1.costUsd ? $0.costUsd > $1.costUsd : $0.tokens > $1.tokens }
            self.daily = daily.values.sorted { $0.key < $1.key }
            self.hourly = hourly.values.sorted { $0.key < $1.key }
        }

        private static func add(_ bucket: Bucket, key: String, to periods: inout [String: Period]) {
            var period = periods[key] ?? Period(key: key, costUsd: 0, tokens: 0, byProvider: [:])
            period.costUsd += bucket.costUsd
            period.tokens += bucket.tokens
            period.byProvider[bucket.provider, default: (0, 0)].cost += bucket.costUsd
            period.byProvider[bucket.provider, default: (0, 0)].tokens += bucket.tokens
            periods[key] = period
        }

        static func == (a: Totals, b: Totals) -> Bool {
            a.costUsd == b.costUsd && a.tokens == b.tokens && a.records == b.records && a.providers == b.providers && a.models == b.models
                && a.daily == b.daily && a.hourly == b.hourly
        }
    }

    // MARK: Formatting

    /// Three significant figures with a unit: "19.9B", "76.7M", "804K".
    static func formatTokens(_ value: Double) -> String {
        let magnitude = abs(value)
        func trim(_ scaled: Double) -> String {
            let digits = abs(scaled) >= 100 ? 0 : abs(scaled) >= 10 ? 1 : 2
            var text = String(format: "%.\(digits)f", scaled)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text
        }
        if magnitude >= 1e12 { return "\(trim(value / 1e12))T" }
        if magnitude >= 1e9 { return "\(trim(value / 1e9))B" }
        if magnitude >= 1e6 { return "\(trim(value / 1e6))M" }
        if magnitude >= 1e3 { return "\(trim(value / 1e3))K" }
        return Int(value.rounded()).formatted()
    }

    static func formatUsd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func formatPercent(_ share: Double) -> String {
        let percent = share * 100
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }
}

/// Subscription quota a provider reports for the signed-in account (`ServerProvider.usageLimits`).
struct ProviderUsageLimits: Hashable, Sendable {
    struct Window: Hashable, Sendable, Identifiable {
        var id: String
        /// session | weekly | monthly | other
        var kind: String
        var label: String
        var usedPercent: Double
        var resetsAt: Date?
        var remainingPercent: Double { max(0, 100 - usedPercent) }
    }

    var checkedAt: Date?
    var windows: [Window]
    /// Why there are no windows: "unsupported" (API key, Bedrock) or "probeFailed".
    var unavailableReason: String?
    var unavailableMessage: String?

    init?(json: JSON?) {
        guard let json, json.object != nil else { return nil }
        checkedAt = ISODate.parse(json["checkedAt"]?.string)
        windows = (json["windows"]?.array ?? []).compactMap { window in
            guard let id = window["id"]?.string, let used = window["usedPercent"]?.double else { return nil }
            return Window(id: id, kind: window["kind"]?.string ?? "other", label: window["label"]?.string ?? id,
                          usedPercent: min(100, max(0, used)), resetsAt: ISODate.parse(window["resetsAt"]?.string))
        }
        .sorted { Self.kindOrder($0.kind) < Self.kindOrder($1.kind) }
        unavailableReason = json["unavailable"]?["reason"]?.string
        unavailableMessage = json["unavailable"]?["message"]?.string
    }

    private static func kindOrder(_ kind: String) -> Int {
        ["session": 0, "weekly": 1, "monthly": 2][kind] ?? 3
    }
}
