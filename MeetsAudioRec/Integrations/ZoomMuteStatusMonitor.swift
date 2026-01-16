import Foundation
import AppKit
import ApplicationServices
import os.log

final class ZoomMuteStatusMonitor: ObservableObject {
    enum Status: String {
        case muted
        case unmuted
        case unknown
        case notRunning
        case noAccessibility
    }

    private struct StatusResult {
        let status: Status
        let detail: String
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastDetectionDetail: String?
    @Published var isMonitoring: Bool = false
    @Published private(set) var hasAccessibilityPermission: Bool = false

    private var timer: Timer?
    private let logger = Logger(subsystem: "com.saqoosha.MeetsAudioRec", category: "ZoomMuteStatus")
    private let zoomBundleIdentifier = "us.zoom.xos"
    private let debugLogFile = "/tmp/MeetsAudioRec_log.txt"
    @Published private(set) var lastDumpPath: String?
    @Published private(set) var lastDumpSummary: String?

    private let mutedMenuTitlesLowercased: Set<String> = ["unmute audio", "unmute audio..."]
    private let unmutedMenuTitlesLowercased: Set<String> = ["mute audio", "mute audio..."]
    private let audioKeywords = ["audio", "mic", "microphone", "オーディオ", "マイク"]
    private let unmuteKeywords = ["unmute", "ミュート解除", "ミュートを解除"]
    private let muteKeywords = ["mute", "ミュート"]
    private let ignoreKeywords = ["video", "camera", "ビデオ", "カメラ"]

    deinit {
        stopMonitoring()
    }

    var statusLabel: String {
        switch status {
        case .muted:
            return "Muted"
        case .unmuted:
            return "Unmuted"
        case .unknown:
            return "Unknown"
        case .notRunning:
            return "Zoom not running"
        case .noAccessibility:
            return "Accessibility needed"
        }
    }

    func startMonitoring(interval: TimeInterval = 1.0) {
        guard !isMonitoring else { return }
        _ = requestAccessibilityPermission()
        isMonitoring = true

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        timer?.tolerance = 0.2

        refreshStatus()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    func checkOnce() {
        _ = requestAccessibilityPermission()
        refreshStatus()
    }

    func dumpMenuTitles() {
        _ = requestAccessibilityPermission()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = self.buildMenuDump()
            DispatchQueue.main.async {
                self.lastDumpPath = result.path
                self.lastDumpSummary = result.summary
                self.lastUpdated = Date()
            }
        }
    }

    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = result
        return result
    }

    private func refreshStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = self.fetchMuteStatus()
            DispatchQueue.main.async {
                if result.status != self.status || result.detail != self.lastDetectionDetail {
                    self.logger.info("Zoom mute status: \(result.status.rawValue, privacy: .public)")
                    self.appendDebugLog("Zoom mute status: \(result.status.rawValue) | \(result.detail)")
                }
                self.status = result.status
                self.lastDetectionDetail = result.detail
                self.lastUpdated = Date()
            }
        }
    }

    private func fetchMuteStatus() -> StatusResult {
        guard AXIsProcessTrusted() else {
            return StatusResult(status: .noAccessibility, detail: "Accessibility permission not granted.")
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleIdentifier).first else {
            return StatusResult(status: .notRunning, detail: "Zoom is not running.")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBarValue = copyAttributeValue(appElement, attribute: kAXMenuBarAttribute as CFString),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return StatusResult(status: .unknown, detail: "Failed to read Zoom menu bar.")
        }
        let menuBar = menuBarValue as! AXUIElement

        if let match = findMenuItemTitle(in: menuBar, targets: mutedMenuTitlesLowercased) {
            return StatusResult(status: .muted, detail: "Found menu item: \(match)")
        }

        if let match = findMenuItemTitle(in: menuBar, targets: unmutedMenuTitlesLowercased) {
            return StatusResult(status: .unmuted, detail: "Found menu item: \(match)")
        }

        if let heuristicStatus = findHeuristicStatus(in: menuBar) {
            return StatusResult(status: heuristicStatus, detail: "Heuristic match from menu titles.")
        }

        return StatusResult(status: .unknown, detail: "No matching menu item found.")
    }

    private func findMenuItemTitle(in element: AXUIElement, targets: Set<String>, depth: Int = 0) -> String? {
        if depth > 12 {
            return nil
        }

        if let title = copyAttributeValue(element, attribute: kAXTitleAttribute as CFString) as? String,
           targets.contains(title.lowercased()) {
            return title
        }

        if let children = copyAttributeValue(element, attribute: kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let found = findMenuItemTitle(in: child, targets: targets, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    private func buildMenuDump() -> (path: String?, summary: String) {
        guard AXIsProcessTrusted() else {
            return (nil, "Accessibility permission not granted.")
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleIdentifier).first else {
            return (nil, "Zoom is not running.")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBarValue = copyAttributeValue(appElement, attribute: kAXMenuBarAttribute as CFString),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return (nil, "Failed to read Zoom menu bar.")
        }

        let menuBar = menuBarValue as! AXUIElement
        var lines: [String] = []
        collectMenuDumpLines(in: menuBar, depth: 0, lines: &lines)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "MeetsAudioRec_zoom_menu_\(formatter.string(from: Date())).txt"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
        let content = lines.joined(separator: "\n")

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return (path, "Dumped \(lines.count) items to \(path)")
        } catch {
            return (nil, "Failed to write dump: \(error.localizedDescription)")
        }
    }

    private func collectMenuDumpLines(in element: AXUIElement, depth: Int, lines: inout [String]) {
        if depth > 12 {
            return
        }

        let indent = String(repeating: "  ", count: depth)
        let role = (copyAttributeValue(element, attribute: kAXRoleAttribute as CFString) as? String) ?? "UnknownRole"
        if let title = copyAttributeValue(element, attribute: kAXTitleAttribute as CFString) as? String, !title.isEmpty {
            lines.append("\(indent)[\(role)] \(title)")
        } else {
            lines.append("\(indent)[\(role)]")
        }

        if let children = copyAttributeValue(element, attribute: kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                collectMenuDumpLines(in: child, depth: depth + 1, lines: &lines)
            }
        }
    }

    private func findHeuristicStatus(in element: AXUIElement, depth: Int = 0) -> Status? {
        if depth > 12 {
            return nil
        }

        if let title = copyAttributeValue(element, attribute: kAXTitleAttribute as CFString) as? String,
           let status = statusFromTitle(title) {
            return status
        }

        if let children = copyAttributeValue(element, attribute: kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let status = findHeuristicStatus(in: child, depth: depth + 1) {
                    return status
                }
            }
        }

        return nil
    }

    private func statusFromTitle(_ title: String) -> Status? {
        let lower = title.lowercased()
        if containsAny(lower, keywords: ignoreKeywords) {
            return nil
        }

        let hasAudioHint = containsAny(lower, keywords: audioKeywords) || title.contains("ミュート")
        guard hasAudioHint else { return nil }

        if containsAny(lower, keywords: unmuteKeywords) || title.contains("ミュート解除") || title.contains("ミュートを解除") {
            return .muted
        }

        if containsAny(lower, keywords: muteKeywords) || title.contains("ミュート") {
            return .unmuted
        }

        return nil
    }

    private func containsAny(_ value: String, keywords: [String]) -> Bool {
        for keyword in keywords {
            if value.contains(keyword.lowercased()) {
                return true
            }
        }
        return false
    }

    private func copyAttributeValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return nil }
        return value
    }

    private func appendDebugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogFile) {
                if let handle = FileHandle(forWritingAtPath: debugLogFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: debugLogFile))
            }
        }
    }
}
