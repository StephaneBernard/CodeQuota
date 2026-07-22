import SwiftUI

struct UsageIconView: View {
    @StateObject private var claudeUsage = ClaudeUsageManager.shared
    @StateObject private var copilotUsage = CopilotUsageManager.shared
    @StateObject private var anthropicAuth = AnthropicAuthManager.shared
    @StateObject private var githubAuth = GitHubAuthManager.shared
    @StateObject private var settings = MenuBarSettings.shared
    
    var body: some View {
        HStack(spacing: 8) {
            let metrics = visibleMetrics()

            if metrics.isEmpty {
                // Disconnected: logo + "!"
                Image("MenuBarIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 16)

                Text("!")
                    .font(.system(size: 14, weight: .bold))
            } else {
                ForEach(metrics) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(for: entry.percent))
                            .frame(width: 8, height: 8)

                        Text(String(format: "%.0f%%", entry.percent))
                            .font(.system(size: 12, weight: .medium))

                        if settings.showResetTime, entry.showsResetTime {
                            Text(resetTimeString(until: entry.resetAt))
                                .font(.system(size: 11))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
    }

    private struct MetricReading: Identifiable {
        let metric: MenuBarMetric
        let percent: Double
        let resetAt: Date?
        // Metrics sharing a source and reset time show a single timer, after the last of the group.
        let showsResetTime: Bool

        var id: MenuBarMetric { metric }
    }

    private func visibleMetrics() -> [MetricReading] {
        let raw = MenuBarMetric.allCases
            .filter { settings.isVisible($0) }
            .compactMap { rawReading(for: $0) }

        var groups: [[(metric: MenuBarMetric, percent: Double, resetAt: Date?)]] = []
        for reading in raw {
            if let lastGroup = groups.last,
               let reference = lastGroup.first,
               reference.metric.providerName == reading.metric.providerName,
               resetTimeString(until: reference.resetAt) == resetTimeString(until: reading.resetAt) {
                groups[groups.count - 1].append(reading)
            } else {
                groups.append([reading])
            }
        }

        return groups.flatMap { group -> [MetricReading] in
            group.enumerated().map { index, reading in
                let isLastOfGroup = index == group.count - 1
                return MetricReading(
                    metric: reading.metric,
                    percent: reading.percent,
                    resetAt: reading.resetAt,
                    showsResetTime: isLastOfGroup && reading.resetAt != nil
                )
            }
        }
    }

    private func rawReading(for metric: MenuBarMetric) -> (metric: MenuBarMetric, percent: Double, resetAt: Date?)? {
        switch metric {
        case .claude5Hour:
            guard anthropicAuth.isConnected, case .loaded(let u) = claudeUsage.state else { return nil }
            return (metric, u.fiveHour.percent, u.fiveHour.resetAt)

        case .claudeWeeklyAll:
            guard anthropicAuth.isConnected, case .loaded(let u) = claudeUsage.state else { return nil }
            return (metric, u.dailyAllModels.percent, u.dailyAllModels.resetAt)

        case .claudeWeeklyFable:
            guard anthropicAuth.isConnected, case .loaded(let u) = claudeUsage.state else { return nil }
            return (metric, u.dailyFable.percent, u.dailyFable.resetAt)

        case .copilotPremium:
            guard githubAuth.isConnected, case .loaded(let u) = copilotUsage.state else { return nil }
            return (metric, u.percent, copilotMonthlyResetDate(from: Date()))
        }
    }

    private func color(for percentage: Double) -> Color {
        if percentage < 50 { return .green }
        else if percentage < 80 { return .yellow }
        else { return .red }
    }
}
