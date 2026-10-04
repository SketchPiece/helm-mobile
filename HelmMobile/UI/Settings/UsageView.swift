import Charts
import SwiftUI

/// Settings → Usage. Limits is the live subscription quota per provider; Usage is what one Mac's
/// transcripts add up to over a period (cost at full API rates, tokens, by provider, type and model).
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private enum Tab: Hashable { case limits, usage }
    enum Metric: Hashable { case cost, tokens }

    @State private var tab = Tab.limits
    @State private var environmentId: String?
    @State private var days = 30
    @State private var metric = Metric.cost
    @State private var summary: Usage.Summary?
    @State private var loadedKey: String?
    @State private var loading = false
    @State private var error: String?
    @State private var limitsError: String?

    private var environment: EnvironmentSession? {
        environmentId.flatMap { model.environment($0) } ?? model.environments.first(where: \.isLive) ?? model.environments.first
    }
    private var totals: Usage.Totals { summary.map(Usage.Totals.init) ?? Usage.Totals() }
    private var loadKey: String { "\(environment?.id ?? "")|\(days)|\(environment?.isLive == true)" }

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $tab) {
                    Text("Limits").tag(Tab.limits)
                    Text("Usage").tag(Tab.usage)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("usageTab")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if environment == nil {
                Text("Connect a computer to see usage.").foregroundStyle(Palette.textMuted)
            } else if tab == .limits {
                limits
            } else {
                usage
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.environments.count > 1, let environment {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Computer", selection: Binding(get: { environment.id }, set: { environmentId = $0 })) {
                            ForEach(model.environments) { Text($0.label).tag($0.id) }
                        }
                    } label: {
                        Label(environment.label, systemImage: "laptopcomputer")
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .task(id: tab == .usage ? loadKey : nil) {
            guard tab == .usage, loadedKey != loadKey else { return }
            await load()
        }
    }

    // MARK: Usage

    @ViewBuilder
    private var usage: some View {
        Section {
            Picker("Period", selection: $days) {
                Text("24h").tag(1).accessibilityLabel("Past 24 hours")
                Text("7d").tag(7).accessibilityLabel("Past 7 days")
                Text("30d").tag(30).accessibilityLabel("Past 30 days")
                Text("90d").tag(90).accessibilityLabel("Past 90 days")
            }
            .pickerStyle(.segmented)
            Picker("Measure", selection: $metric) {
                Text("Cost").tag(Metric.cost)
                Text("Tokens").tag(Metric.tokens)
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)

        if let error {
            Section { Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText) }
        } else if summary == nil {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(environment?.isLive == true ? "Scanning provider transcripts…" : "Waiting for connection…")
                        .foregroundStyle(Palette.textMuted)
                }
            }
        } else if let summary {
            if !summary.isCompatible {
                Section {
                    Text(summary.contractVersion < Usage.compatibleSince
                         ? "This computer runs an older Helm; update it to see usage."
                         : "This app is older than Helm on the computer; update it to see usage.")
                        .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                }
            } else {
                let totals = totals
                ForEach(summary.sourceMessages, id: \.self) { message in
                    Text(message).font(Typography.footnote).foregroundStyle(Palette.textMuted)
                }
                chartCard(totals)
                providerSection(totals)
                totalsSection(totals)
                costSection(totals)
                modelsSection(totals)
            }
        }
    }

    private func chartCard(_ totals: Usage.Totals) -> some View {
        let periods = days == 1 ? totals.hourly : totals.daily
        return Section {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric == .cost ? "Raw token cost" : "Processed tokens")
                        .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    Text(metric == .cost ? "\(Usage.formatUsd(totals.costUsd))*" : Usage.formatTokens(totals.tokens))
                        .font(Typography.sans(34, .semibold, relativeTo: .largeTitle))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                        .accessibilityIdentifier("usageHeadline")
                    Text(metric == .cost ? String(localized: "* if billed at full API rates")
                                         : String(localized: "Across \(Int(totals.sessions)) sessions"))
                        .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                }
                if periods.contains(where: { $0.tokens > 0 }) {
                    Chart {
                        ForEach(periods) { period in
                            ForEach(Usage.providerOrder.filter { period.byProvider[$0] != nil }, id: \.self) { provider in
                                let value = period.byProvider[provider].map { metric == .cost ? $0.cost : $0.tokens } ?? 0
                                BarMark(x: .value("Period", period.key), y: .value("Value", value))
                                    .foregroundStyle(by: .value("Provider", Usage.providerLabel(provider)))
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: chartProviders(totals).map(Usage.providerLabel),
                                               range: chartProviders(totals).map(providerColor))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(Palette.border)
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(metric == .cost ? Usage.formatUsd(number) : Usage.formatTokens(number))
                                        .font(Typography.caption)
                                        .foregroundStyle(Palette.textMuted)
                                }
                            }
                        }
                    }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 180)
                } else {
                    Text("No activity in this period.")
                        .foregroundStyle(Palette.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func chartProviders(_ totals: Usage.Totals) -> [String] {
        let present = Set(totals.providers.map(\.provider))
        return Usage.providerOrder.filter(present.contains)
    }

    @ViewBuilder
    private func providerSection(_ totals: Usage.Totals) -> some View {
        if !totals.providers.isEmpty {
            Section {
                ForEach(totals.providers.sorted { metric == .cost ? $0.costUsd > $1.costUsd : $0.tokens > $1.tokens }) { provider in
                    let share = metric == .cost ? provider.costShare : provider.tokenShare
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(providerColor(provider.provider)).frame(width: 9, height: 9)
                            Text(Usage.providerLabel(provider.provider))
                            Spacer()
                            Text(metric == .cost ? Usage.formatUsd(provider.costUsd) : Usage.formatTokens(provider.tokens))
                                .monospacedDigit()
                        }
                        ShareBar(share: share, color: providerColor(provider.provider))
                        Text("\(Usage.formatPercent(share)) · \(Int(provider.sessions)) sessions")
                            .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Providers").sectionLabelStyle()
            }
        }
    }

    private func totalsSection(_ totals: Usage.Totals) -> some View {
        let activePeriods = (days == 1 ? totals.hourly : totals.daily).filter { $0.tokens > 0 }.count
        let average = activePeriods == 0 ? 0 : totals.tokens / Double(activePeriods)
        let observed = totals.uncachedInput + totals.cachedInput
        return Section {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    metricCell(String(localized: "Processed tokens"), Usage.formatTokens(totals.tokens),
                               days == 1 ? String(localized: "\(Usage.formatTokens(average)) per active hour")
                                         : String(localized: "\(Usage.formatTokens(average)) per active day"))
                    metricCell(String(localized: "Cache savings"), Usage.formatUsd(totals.cacheSavingsUsd),
                               totals.costUsd > 0 ? String(localized: "\(String(format: "%.1f", totals.cacheSavingsUsd / totals.costUsd))× the raw cost")
                                                  : String(localized: "vs full input rates"))
                }
                GridRow {
                    metricCell(String(localized: "Cached input"), Usage.formatTokens(totals.cachedInput),
                               String(localized: "\(Usage.formatPercent(observed == 0 ? 0 : totals.cachedInput / observed)) of input"))
                    metricCell(String(localized: "Uncached input"), Usage.formatTokens(totals.uncachedInput),
                               String(localized: "\(Usage.formatTokens(totals.cacheCreation)) cache writes"))
                }
                GridRow {
                    metricCell(String(localized: "Output"), Usage.formatTokens(totals.output),
                               String(localized: "incl. \(Usage.formatTokens(totals.reasoning)) reasoning"))
                    metricCell(String(localized: "Unpriced"), Usage.formatPercent(totals.unpricedShare),
                               String(localized: "of records, left out of cost"))
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Totals").sectionLabelStyle()
        }
    }

    private func metricCell(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Typography.footnote).foregroundStyle(Palette.textMuted)
            Text(value).font(Typography.sans(20, .medium, relativeTo: .title3)).monospacedDigit().foregroundStyle(Palette.text)
            Text(detail).font(Typography.caption).foregroundStyle(Palette.textMuted).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func costSection(_ totals: Usage.Totals) -> some View {
        if totals.costUsd > 0 {
            let dark = colorScheme == .dark
            let byType: [(String, Double, Color)] = [
                (String(localized: "Input"), totals.cost.input, Color(hex: dark ? 0x737373 : 0x848484)),
                (String(localized: "Cache read"), totals.cost.cacheRead, Color(hex: dark ? 0x282828 : 0xC0C0C0)),
                (String(localized: "Cache write"), totals.cost.cacheWrite, Color(hex: dark ? 0x949494 : 0x6D6D6D)),
                (String(localized: "Output"), totals.cost.output, Color(hex: dark ? 0xE6E6E6 : 0x3C3C43)),
                // Below a cent the unsplit remainder is rounding, not usage.
                (String(localized: "Other"), totals.cost.unsplit >= 0.005 ? totals.cost.unsplit : 0, Color(hex: dark ? 0x494949 : 0xA3A3A3)),
            ]
            let bySpeed: [(String, Double, Color)] = [
                (String(localized: "Standard"), totals.speed.standard, Color(hex: dark ? 0x313131 : 0xB8B8B8)),
                (String(localized: "Fast"), totals.speed.fast, Color(hex: dark ? 0x838383 : 0x797979)),
                (String(localized: "Ultrafast"), totals.speed.ultrafast, Color(hex: dark ? 0xE6E6E6 : 0x3C3C43)),
            ]
            Section {
                SegmentBar(title: String(localized: "By type"), aside: nil, segments: byType)
                if totals.speed.fast + totals.speed.ultrafast > 0 {
                    SegmentBar(title: String(localized: "By speed"),
                               aside: String(localized: "\(Usage.formatUsd(totals.speed.premium)) premium"), segments: bySpeed)
                }
            } header: {
                Text("Cost").sectionLabelStyle()
            }
        }
    }

    @ViewBuilder
    private func modelsSection(_ totals: Usage.Totals) -> some View {
        if !totals.models.isEmpty {
            Section {
                ForEach(totals.models.prefix(6)) { modelRow($0) }
                if totals.models.count > 6 {
                    NavigationLink("All \(totals.models.count) models") {
                        Form {
                            ForEach(totals.models) { modelRow($0) }
                        }
                        .font(Typography.body)
                        .scrollContentBackground(.hidden)
                        .background(Palette.canvas)
                        .navigationTitle("By model")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            } header: {
                Text("By model").sectionLabelStyle()
            }
        }
    }

    private func modelRow(_ model: Usage.ModelTotals) -> some View {
        HStack(spacing: 10) {
            Circle().fill(providerColor(model.provider)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.model).font(Typography.mono(14)).lineLimit(1).truncationMode(.middle)
                Text(model.costUnknown
                     ? String(localized: "no known rates · \(Usage.formatTokens(model.tokens)) tokens")
                     : String(localized: "\(Usage.formatPercent(model.costShare)) of cost · \(Usage.formatTokens(model.tokens)) tokens"))
                    .font(Typography.footnote).foregroundStyle(Palette.textMuted)
            }
            Spacer()
            Text(model.costUnknown ? String(localized: "Unpriced") : Usage.formatUsd(model.costUsd)).monospacedDigit()
        }
    }

    // MARK: Limits

    @ViewBuilder
    private var limits: some View {
        let providers = (environment?.config?.providers ?? []).filter {
            $0.enabled && $0.installed && $0.usageLimits?.unavailableReason != "unsupported" && $0.usageLimits != nil
        }
        if let limitsError {
            Section { Text(limitsError).font(Typography.footnote).foregroundStyle(Palette.errorText) }
        }
        if providers.isEmpty {
            Section {
                Text(environment?.isLive == true ? "No provider on this computer reports subscription limits." : "Waiting for connection…")
                    .foregroundStyle(Palette.textMuted)
            }
        }
        ForEach(providers) { provider in
            Section {
                if let limits = provider.usageLimits {
                    if limits.windows.isEmpty {
                        Text(limits.unavailableMessage ?? String(localized: "No limits reported right now."))
                            .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    }
                    ForEach(limits.windows) { window in
                        LimitRow(window: window)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    ProviderIcon(driver: provider.driver, iconUrl: provider.iconUrl, size: 18)
                        .frame(width: 22)
                    Text(provider.displayName).sectionLabelStyle()
                }
            } footer: {
                if let checked = provider.usageLimits?.checkedAt {
                    Text("Checked \(checked, style: .relative) ago").font(Typography.footnote)
                }
            }
        }
    }

    // MARK: Data

    private func load() async {
        guard let environment, environment.isLive else { return }
        let key = loadKey
        loading = true
        defer { loading = false }
        do {
            let result = try await environment.usageSummary(Usage.window(days: days))
            guard key == loadKey else { return }
            summary = result
            loadedKey = key
            error = nil
        } catch {
            guard key == loadKey, !Task.isCancelled else { return }
            summary = nil
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        if tab == .usage {
            await load()
        } else if let environment {
            do {
                try await environment.refreshProviders()
                limitsError = nil
            } catch {
                limitsError = error.localizedDescription
            }
        }
        await UsageWidgetPublisher.shared.publish(from: model.environments, force: true)
    }

    private func providerColor(_ kind: String) -> Color {
        let dark = colorScheme == .dark
        return switch kind {
        case "claude": Color(hex: 0xD97757)
        case "codex": Color(hex: dark ? 0xE6E6E6 : 0x3C3C43)
        case "grok": Color(hex: dark ? 0xA1A1AA : 0x52525B)
        case "cursor": Color(hex: 0x8B8B8B)
        case "opencode": Color(hex: 0x5B9BBD)
        case "antigravity": Color(hex: 0x8C7BD1)
        default: Palette.textMuted
        }
    }
}

/// A thin part-of-whole bar.
private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.border)
                Capsule().fill(color).frame(width: max(2, proxy.size.width * min(1, share)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// One cost breakdown: a stacked bar and its legend. Empty segments are left out.
private struct SegmentBar: View {
    let title: String
    let aside: String?
    let segments: [(String, Double, Color)]

    var body: some View {
        let visible = segments.filter { $0.1 > 0 }
        let total = visible.reduce(0) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(Typography.footnote).foregroundStyle(Palette.textMuted)
                Spacer()
                if let aside { Text(aside).font(Typography.footnote).foregroundStyle(Palette.textMuted).monospacedDigit() }
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(visible, id: \.0) { segment in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segment.2)
                            .frame(width: max(2, (proxy.size.width - CGFloat(visible.count - 1) * 2) * segment.1 / max(total, 0.0001)))
                    }
                }
            }
            .frame(height: 8)
            FlowLegend(items: visible.map { ($0.0, Usage.formatUsd($0.1), $0.2) })
        }
        .padding(.vertical, 4)
    }
}

private struct FlowLegend: View {
    let items: [(String, String, Color)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(item.2).frame(width: 8, height: 8)
                    Text(item.0).font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    Text(item.1).font(Typography.footnote).foregroundStyle(Palette.text).monospacedDigit()
                }
            }
        }
    }
}

/// One quota window: what's left, as a bar, and when it resets.
private struct LimitRow: View {
    let window: ProviderUsageLimits.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(Typography.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(window.remainingPercent < 15 ? Palette.errorText : Palette.text)
            }
            ShareBar(share: window.remainingPercent / 100, color: window.remainingPercent < 15 ? Palette.error : Palette.working)
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
