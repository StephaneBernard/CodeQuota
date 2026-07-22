import Foundation
import Combine

// MARK: - Usage Data Models

struct UsageBucket: Equatable, Codable {
    var percent: Double // 0.0 to 100.0
    var resetAt: Date?
    
    var timeRemainingString: String {
        guard let resetAt = resetAt else { return "--" }
        let seconds = Int(resetAt.timeIntervalSinceNow)
        if seconds <= 0 { return "now" }
        
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

struct ClaudeUsage: Equatable, Codable {
    var fiveHour: UsageBucket
    var dailyAllModels: UsageBucket
    var dailyFable: UsageBucket

    static let empty = ClaudeUsage(
        fiveHour: UsageBucket(percent: 0, resetAt: nil),
        dailyAllModels: UsageBucket(percent: 0, resetAt: nil),
        dailyFable: UsageBucket(percent: 0, resetAt: nil)
    )
}

enum UsageState: Equatable {
    case notConnected
    case loading
    case loaded(ClaudeUsage)
    case error(String)
}

// MARK: - Refresh Backoff

/// Computes the polling interval between usage refreshes.
/// Starts at `base`, doubles on failure up to `max`, and resets on success.
struct RefreshBackoff: Equatable {
    let base: TimeInterval
    let max: TimeInterval
    private(set) var interval: TimeInterval

    init(base: TimeInterval, max: TimeInterval) {
        self.base = base
        self.max = max
        self.interval = base
    }

    mutating func reset() {
        interval = base
    }

    mutating func increase() {
        interval = Swift.min(interval * 2, max)
    }

    mutating func apply(retryAfter: TimeInterval?) {
        guard let retryAfter = retryAfter else {
            increase()
            return
        }
        interval = Swift.min(Swift.max(retryAfter, base), max)
    }
}

// MARK: - Usage Manager

class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    private static let baseRefreshInterval: TimeInterval = 60
    private static let maxRefreshInterval: TimeInterval = 15 * 60
    private static let cachedUsageKey = "claude_last_known_usage"

    @Published var state: UsageState = .notConnected
    @Published var lastUpdateText: String = "never"
    @Published var debugLog: String = ""

    private var lastUpdateTime: Date?
    private var refreshTimer: Timer?
    private var textTimer: Timer?
    private var backoff = RefreshBackoff(base: baseRefreshInterval, max: maxRefreshInterval)
    private let authManager = AnthropicAuthManager.shared

    // Parsing is delegated to ClaudeUsageParser

    private init() {
        if let cached = loadCachedUsage() {
            state = .loaded(cached)
        }
    }

    private func loadCachedUsage() -> ClaudeUsage? {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedUsageKey) else { return nil }
        return try? JSONDecoder().decode(ClaudeUsage.self, from: data)
    }

    private func cacheUsage(_ usage: ClaudeUsage) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedUsageKey)
    }
    
    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)"
        print(line)
        DispatchQueue.main.async {
            self.debugLog += line + "\n"
            // Keep only the last 2000 chars
            if self.debugLog.count > 2000 {
                self.debugLog = String(self.debugLog.suffix(2000))
            }
        }
    }
    
    func startAutoRefresh() {
        textTimer?.invalidate()
        backoff.reset()
        scheduleRefreshTimer()

        // Update "updated X ago" text every second
        textTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateLastUpdateText()
        }

        // Initial refresh
        refresh()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: backoff.interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    private func resetBackoff() {
        backoff.reset()
        scheduleRefreshTimer()
    }

    private func increaseBackoff() {
        backoff.increase()
        log("backoff: next refresh in \(Int(backoff.interval))s")
        scheduleRefreshTimer()
    }

    private func backOff(retryAfter: TimeInterval?) {
        backoff.apply(retryAfter: retryAfter)
        log("backoff: next refresh in \(Int(backoff.interval))s")
        scheduleRefreshTimer()
    }

    private func retryAfterSeconds(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let response = response else { return nil }
        let headers = response.allHeaderFields
        guard let raw = (headers["Retry-After"] ?? headers["retry-after"]) as? String,
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return seconds
    }
    
    func refresh() {
        guard authManager.isConnected else {
            state = .notConnected
            scheduleRefreshTimer()
            return
        }
        
        // Always show loading if we don't have data yet
        if case .loaded = state {
            // Keep showing existing data while refreshing
        } else {
            state = .loading
        }
        
        log("refresh: getting valid access token...")
        
        authManager.getValidAccessToken { [weak self] (token: String?) in
            guard let self = self else { return }
            guard let token = token else {
                self.log("refresh: no valid token returned")
                DispatchQueue.main.async {
                    self.state = .error("Session expired. Please reconnect in Settings.")
                }
                return
            }
            self.log("refresh: got token (\(token.prefix(8))...), fetching usage")
            self.fetchUsage(accessToken: token)
        }
    }
    
    private var retryCount = 0
    private let maxRetries = 1
    
    private func fetchUsage(accessToken: String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let error = error {
                    self.log("fetchUsage: network error: \(error.localizedDescription)")
                    self.state = .error("Network error: \(error.localizedDescription)")
                    self.increaseBackoff()
                    return
                }
                
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0
                self.log("fetchUsage: HTTP \(statusCode)")
                
                guard let data = data else {
                    self.log("fetchUsage: no data")
                    self.state = .error("No data received.")
                    self.increaseBackoff()
                    return
                }
                
                let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "(binary)"
                self.log("fetchUsage: body=\(bodyPreview)")
                
                if statusCode == 401 {
                    if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        self.log("fetchUsage: 401, attempting token refresh (retry \(self.retryCount)/\(self.maxRetries))")
                        self.authManager.refreshAccessToken { (success: Bool) in
                            if success {
                                self.log("fetchUsage: token refreshed, retrying")
                                self.refresh()
                            } else {
                                self.log("fetchUsage: token refresh failed")
                                self.retryCount = 0
                                self.state = .error("Session expired. Please reconnect in Settings.")
                            }
                        }
                    } else {
                        self.retryCount = 0
                        let bodyStr = String(data: data, encoding: .utf8) ?? ""
                        self.log("fetchUsage: 401 after max retries. body=\(bodyStr.prefix(200))")
                        self.state = .error("Authentication failed. Please reconnect in Settings.")
                    }
                    return
                }
                
                // Handle 429 (rate limited)
                // This is likely transient rate limiting on the usage endpoint.
                // Preserve last known usage data instead of showing an error.
                if statusCode == 429 {
                    let bodyStr = String(data: data, encoding: .utf8) ?? "(no body)"
                    self.log("fetchUsage: 429 RATE LIMITED")
                    self.log("fetchUsage: 429 body=\(bodyStr)")
                    
                    let retryAfter = self.retryAfterSeconds(from: httpResponse)
                    if let retryAfter = retryAfter {
                        self.log("fetchUsage: 429 Retry-After=\(retryAfter)s")
                    }

                    // Keep existing data if we have it, otherwise show error
                    if case .loaded = self.state {
                        self.log("fetchUsage: 429 - keeping previous usage data")
                        // Don't change state - keep showing last known good data
                    } else {
                        self.state = .error("Rate limited. Please wait and try again.")
                    }
                    self.backOff(retryAfter: retryAfter)
                    return
                }

                if statusCode < 200 || statusCode >= 300 {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    self.log("fetchUsage: HTTP \(statusCode) body=\(bodyStr.prefix(200))")
                    self.state = .error("Server error (HTTP \(statusCode))")
                    self.increaseBackoff()
                    return
                }

                self.retryCount = 0
                self.parseUsageResponse(data)
                self.resetBackoff()
            }
        }.resume()
    }
    
    private func parseUsageResponse(_ data: Data) {
        let result = ClaudeUsageParser.parseResponse(data)
        switch result {
        case .success(let usage):
            log("parseUsage: success! 5h=\(usage.fiveHour.percent)% daily=\(usage.dailyAllModels.percent)% fable=\(usage.dailyFable.percent)%")
            state = .loaded(usage)
            cacheUsage(usage)
            lastUpdateTime = Date()
            lastUpdateText = "just now"
        case .failure(let error):
            switch error {
            case .invalidJSON:
                log("parseUsage: response is not a JSON object")
                state = .error("Invalid response format.")
            case .unrecognizedFormat(let keys):
                log("parseUsage: no known keys matched")
                state = .error("Unrecognized usage format. Keys: \(keys.joined(separator: ", "))")
            }
        }
    }
    
    private func updateLastUpdateText() {
        guard let lastUpdateTime = lastUpdateTime else {
            lastUpdateText = "never"
            return
        }
        
        let seconds = Int(Date().timeIntervalSince(lastUpdateTime))
        
        if seconds < 5 {
            lastUpdateText = "just now"
        } else if seconds < 60 {
            lastUpdateText = "\(seconds)s ago"
        } else if seconds < 3600 {
            lastUpdateText = "\(seconds / 60)m ago"
        } else {
            lastUpdateText = "\(seconds / 3600)h ago"
        }
    }
    
    deinit {
        refreshTimer?.invalidate()
        textTimer?.invalidate()
    }
}
