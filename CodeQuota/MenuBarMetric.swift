import Foundation

enum MenuBarMetric: String, CaseIterable, Codable {
    case claude5Hour = "claude_5hour"
    case claudeWeeklyAll = "claude_weekly_all"
    case claudeWeeklyFable = "claude_weekly_fable"
    case copilotPremium = "copilot_premium"
    
    var displayName: String {
        switch self {
        case .claude5Hour: return "Claude — 5-Hour Session"
        case .claudeWeeklyAll: return "Claude — Weekly All Models"
        case .claudeWeeklyFable: return "Claude — Weekly Fable"
        case .copilotPremium: return "Copilot — Premium Requests"
        }
    }
    
    var shortName: String {
        switch self {
        case .claude5Hour: return "5h"
        case .claudeWeeklyAll: return "Wk"
        case .claudeWeeklyFable: return "Fab"
        case .copilotPremium: return "CP"
        }
    }
    
    var providerName: String {
        switch self {
        case .claude5Hour, .claudeWeeklyAll, .claudeWeeklyFable: return "Claude"
        case .copilotPremium: return "Copilot"
        }
    }
}

class MenuBarSettings: ObservableObject {
    static let shared = MenuBarSettings()
    
    static let hiddenKey = "hidden_metrics"
    static let showResetTimeKey = "show_reset_time"

    let defaults: UserDefaults

    @Published var showResetTime: Bool {
        didSet {
            defaults.set(showResetTime, forKey: Self.showResetTimeKey)
        }
    }

    @Published var hiddenMetrics: Set<MenuBarMetric> {
        didSet {
            let rawValues = hiddenMetrics.map { $0.rawValue }
            defaults.set(rawValues, forKey: Self.hiddenKey)
        }
    }
    
    private convenience init() {
        self.init(defaults: .standard)
    }
    
    init(defaults: UserDefaults) {
        self.defaults = defaults
        
        if let rawValues = defaults.stringArray(forKey: Self.hiddenKey) {
            hiddenMetrics = Set(rawValues.compactMap { MenuBarMetric(rawValue: $0) })
        } else {
            hiddenMetrics = []
        }
        
        // Default to true if never set
        if defaults.object(forKey: Self.showResetTimeKey) != nil {
            showResetTime = defaults.bool(forKey: Self.showResetTimeKey)
        } else {
            showResetTime = true
        }
    }
    
    func isVisible(_ metric: MenuBarMetric) -> Bool {
        !hiddenMetrics.contains(metric)
    }
    
    func toggleVisibility(_ metric: MenuBarMetric) {
        if hiddenMetrics.contains(metric) {
            hiddenMetrics.remove(metric)
        } else if !isLastVisible(metric) {
            hiddenMetrics.insert(metric)
        }
    }

    private func isLastVisible(_ metric: MenuBarMetric) -> Bool {
        MenuBarMetric.allCases.allSatisfy { $0 == metric || hiddenMetrics.contains($0) }
    }
}
