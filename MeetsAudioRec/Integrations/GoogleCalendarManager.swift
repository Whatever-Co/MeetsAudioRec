import Foundation
import Network
import AppKit
import Security
import os.log

private let logger = Logger(subsystem: "com.saqoosha.MeetsAudioRec", category: "GoogleCalendar")

// MARK: - Calendar Event Model

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startTime: Date
    let endTime: Date
    let meetingLink: String
    let meetingType: MeetingType

    enum MeetingType: String {
        case googleMeet = "Google Meet"
        case zoom = "Zoom"
    }

    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Google Calendar Manager

final class GoogleCalendarManager: ObservableObject {

    // MARK: Configuration
    // To use this feature, create a Google Cloud project with Calendar API enabled,
    // create a "Desktop" type OAuth 2.0 client, and set clientID and clientSecret below.
    // See: https://developers.google.com/calendar/api/quickstart/swift
    private static let clientID = ""
    private static let clientSecret = ""
    private static let scopes = "https://www.googleapis.com/auth/calendar.events.readonly"
    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let calendarBaseURL = "https://www.googleapis.com/calendar/v3"
    private static let keychainService = "co.whatever.MeetsAudioRec.GoogleCalendar"
    private static let keychainAccount = "refreshToken"

    // MARK: Published State

    @Published var isSignedIn = false
    @Published var userEmail: String?
    @Published var autoRecordEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRecordEnabled, forKey: "calendarAutoRecordEnabled") }
    }
    @Published var upcomingMeetings: [CalendarEvent] = []
    @Published var nextMeeting: CalendarEvent?
    @Published var isAutoRecording = false
    @Published var currentEvent: CalendarEvent?
    @Published var statusMessage: String?
    @Published var isConfigured: Bool

    // MARK: Private State

    private var accessToken: String?
    private var refreshToken: String? {
        didSet {
            if let token = refreshToken {
                saveToKeychain(token)
            } else {
                deleteFromKeychain()
            }
        }
    }
    private var tokenExpiry: Date?

    private var pollTimer: Timer?
    private var eventStartTimer: Timer?
    private var eventEndTimer: Timer?
    private var listener: NWListener?
    private var codeVerifier: String?
    private var activePort: UInt16 = 0

    // MARK: Recording Control

    weak var audioCaptureManager: AudioCaptureManager?
    weak var recordingState: RecordingState?

    // Called when auto-recording stops (so ContentView can react)
    var onAutoRecordingStopped: (() -> Void)?

    // MARK: Init

    init() {
        self.autoRecordEnabled = UserDefaults.standard.bool(forKey: "calendarAutoRecordEnabled")
        self.isConfigured = !Self.clientID.isEmpty && !Self.clientSecret.isEmpty

        if isConfigured {
            loadRefreshToken()
            if refreshToken != nil {
                Task { await refreshAccessToken() }
            }
        }
    }

    deinit {
        stopPolling()
        listener?.cancel()
    }

    // MARK: - OAuth Flow

    func signIn() {
        guard isConfigured else {
            statusMessage = "Google Calendar not configured. Set clientID and clientSecret in GoogleCalendarManager.swift."
            return
        }

        // Generate PKCE code verifier and challenge
        codeVerifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: codeVerifier!)

        // Find an available port for the callback server
        activePort = findAvailablePort()
        let redirectURI = "http://127.0.0.1:\(activePort)"

        // Start local HTTP server
        startCallbackServer(port: activePort)

        // Build authorization URL
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        if let url = components.url {
            logger.info("Opening Google OAuth URL in browser")
            NSWorkspace.shared.open(url)
            statusMessage = "Waiting for Google sign-in..."
        }
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        stopPolling()

        DispatchQueue.main.async {
            self.isSignedIn = false
            self.userEmail = nil
            self.upcomingMeetings = []
            self.nextMeeting = nil
            self.statusMessage = nil
        }

        logger.info("Signed out of Google Calendar")
    }

    // MARK: - Local Callback Server

    private func startCallbackServer(port: UInt16) {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("Invalid port: \(port)")
            return
        }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            logger.error("Failed to create listener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("OAuth callback server ready on port \(port)")
            case .failed(let error):
                logger.error("Callback server failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self,
                  let data = data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse HTTP request for authorization code
            if let code = self.extractAuthCode(from: request) {
                // Send success response to browser
                let html = """
                <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 80px;">
                <h1>Signed in successfully</h1>
                <p>You can close this window and return to MeetsAudioRec.</p>
                </body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                self.listener?.cancel()
                self.listener = nil

                // Exchange code for tokens
                Task { await self.exchangeCodeForTokens(code) }
            } else if let error = self.extractAuthError(from: request) {
                let html = """
                <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 80px;">
                <h1>Sign-in failed</h1>
                <p>\(error)</p>
                </body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                self.listener?.cancel()
                self.listener = nil

                DispatchQueue.main.async {
                    self.statusMessage = "Sign-in failed: \(error)"
                }
            } else {
                // Ignore non-OAuth requests (e.g., favicon) and keep listening
                let response = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func extractAuthCode(from request: String) -> String? {
        // Parse "GET /callback?code=XXXX&scope=... HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])

        guard let components = URLComponents(string: "http://localhost\(path)"),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        return code
    }

    private func extractAuthError(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])

        guard let components = URLComponents(string: "http://localhost\(path)"),
              let error = components.queryItems?.first(where: { $0.name == "error" })?.value else {
            return nil
        }
        return error
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(_ code: String) async {
        let redirectURI = "http://127.0.0.1:\(activePort)"

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: Self.clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                logger.error("Token exchange failed: \(errorBody)")
                await MainActor.run {
                    self.statusMessage = "Sign-in failed: token exchange error"
                }
                return
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            await handleTokenResponse(tokenResponse)

            logger.info("Google OAuth sign-in successful")
        } catch {
            logger.error("Token exchange error: \(error.localizedDescription)")
            await MainActor.run {
                self.statusMessage = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshAccessToken() async {
        guard let refreshToken = refreshToken else { return }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: Self.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                logger.error("Token refresh failed, signing out")
                await MainActor.run { self.signOut() }
                return
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            await handleTokenResponse(tokenResponse)
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
        }
    }

    private func handleTokenResponse(_ response: TokenResponse) async {
        accessToken = response.access_token
        if let newRefresh = response.refresh_token {
            refreshToken = newRefresh
        }
        tokenExpiry = Date().addingTimeInterval(TimeInterval(response.expires_in - 60))

        await MainActor.run {
            self.isSignedIn = true
            self.statusMessage = nil
        }

        // Fetch user email
        await fetchUserEmail()

        // Start polling if auto-record is enabled
        if autoRecordEnabled {
            await MainActor.run { self.startPolling() }
        }
    }

    private func fetchUserEmail() async {
        guard let accessToken = accessToken else { return }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = json["email"] as? String {
                await MainActor.run {
                    self.userEmail = email
                }
            }
        } catch {
            logger.error("Failed to fetch user email: \(error.localizedDescription)")
        }
    }

    private func ensureValidToken() async -> Bool {
        if let expiry = tokenExpiry, Date() >= expiry {
            await refreshAccessToken()
        }
        return accessToken != nil
    }

    // MARK: - Calendar API

    func startPolling() {
        guard isSignedIn else { return }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.fetchUpcomingEvents() }
        }
        pollTimer?.tolerance = 5.0

        Task { await fetchUpcomingEvents() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        eventStartTimer?.invalidate()
        eventStartTimer = nil
        eventEndTimer?.invalidate()
        eventEndTimer = nil
    }

    private func fetchUpcomingEvents() async {
        guard await ensureValidToken(), let accessToken = accessToken else { return }

        let now = Date()
        let lookAhead = now.addingTimeInterval(8 * 3600) // Next 8 hours

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "\(Self.calendarBaseURL)/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: now)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: lookAhead)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "20"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.error("Calendar API returned status \(code)")
                if code == 401 {
                    await refreshAccessToken()
                }
                return
            }

            let events = parseCalendarEvents(from: data)

            await MainActor.run {
                self.upcomingMeetings = events
                self.nextMeeting = events.first(where: { $0.startTime > Date() })
                if self.autoRecordEnabled {
                    self.scheduleNextEvent()
                }
            }

            logger.info("Found \(events.count) upcoming meetings with video links")
        } catch {
            logger.error("Calendar fetch error: \(error.localizedDescription)")
        }
    }

    private func parseCalendarEvents(from data: Data) -> [CalendarEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Also support datetime format without seconds fraction
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var events: [CalendarEvent] = []

        for item in items {
            guard let id = item["id"] as? String,
                  let summary = item["summary"] as? String else { continue }

            // Parse start/end times
            guard let startObj = item["start"] as? [String: Any],
                  let endObj = item["end"] as? [String: Any] else { continue }

            let startStr = startObj["dateTime"] as? String ?? startObj["date"] as? String ?? ""
            let endStr = endObj["dateTime"] as? String ?? endObj["date"] as? String ?? ""

            guard let startTime = formatter.date(from: startStr) ?? altFormatter.date(from: startStr),
                  let endTime = formatter.date(from: endStr) ?? altFormatter.date(from: endStr) else { continue }

            // Detect meeting link
            if let (link, type) = extractMeetingLink(from: item) {
                events.append(CalendarEvent(
                    id: id,
                    title: summary,
                    startTime: startTime,
                    endTime: endTime,
                    meetingLink: link,
                    meetingType: type
                ))
            }
        }

        return events
    }

    private func extractMeetingLink(from event: [String: Any]) -> (String, CalendarEvent.MeetingType)? {
        // 1. Check hangoutLink (Google Meet)
        if let hangoutLink = event["hangoutLink"] as? String {
            return (hangoutLink, .googleMeet)
        }

        // 2. Check conferenceData.entryPoints
        if let conferenceData = event["conferenceData"] as? [String: Any],
           let entryPoints = conferenceData["entryPoints"] as? [[String: Any]] {
            for entry in entryPoints {
                if let entryType = entry["entryPointType"] as? String,
                   entryType == "video",
                   let uri = entry["uri"] as? String {
                    if uri.contains("meet.google.com") {
                        return (uri, .googleMeet)
                    } else if uri.contains("zoom.us") {
                        return (uri, .zoom)
                    }
                }
            }
        }

        // 3. Search location and description for meeting links
        let textFields = [
            event["location"] as? String,
            event["description"] as? String,
        ].compactMap { $0 }

        let meetPattern = #"https://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#
        let zoomPattern = #"https://[a-zA-Z0-9.-]+\.zoom\.us/j/[0-9]+"#

        for text in textFields {
            if let range = text.range(of: meetPattern, options: .regularExpression) {
                return (String(text[range]), .googleMeet)
            }
            if let range = text.range(of: zoomPattern, options: .regularExpression) {
                return (String(text[range]), .zoom)
            }
        }

        return nil
    }

    // MARK: - Auto-Record Scheduling

    private func scheduleNextEvent() {
        eventStartTimer?.invalidate()
        eventEndTimer?.invalidate()

        let now = Date()

        // Find the current or next event
        if let current = upcomingMeetings.first(where: { $0.startTime <= now && $0.endTime > now }) {
            // Event is happening now - start recording if not already
            if !isAutoRecording {
                startAutoRecording(for: current)
            }
            // Schedule stop at event end
            let stopDelay = current.endTime.timeIntervalSince(now)
            eventEndTimer = Timer.scheduledTimer(withTimeInterval: stopDelay, repeats: false) { [weak self] _ in
                self?.stopAutoRecording()
            }
            return
        }

        if let next = upcomingMeetings.first(where: { $0.startTime > now }) {
            // Schedule start at event begin
            let startDelay = next.startTime.timeIntervalSince(now)
            logger.info("Next meeting '\(next.title)' in \(Int(startDelay))s")

            eventStartTimer = Timer.scheduledTimer(withTimeInterval: startDelay, repeats: false) { [weak self] _ in
                self?.startAutoRecording(for: next)

                // Schedule stop at event end
                let duration = next.endTime.timeIntervalSince(next.startTime)
                self?.eventEndTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                    self?.stopAutoRecording()
                }
            }
        }
    }

    private func startAutoRecording(for event: CalendarEvent) {
        guard let audioCaptureManager = audioCaptureManager,
              let recordingState = recordingState,
              !audioCaptureManager.isRecording else {
            logger.info("Skipping auto-record: already recording or managers unavailable")
            return
        }

        logger.info("Auto-starting recording for: \(event.title)")

        let url = recordingState.generateRecordingFilename(eventTitle: event.title)

        DispatchQueue.main.async {
            self.isAutoRecording = true
            self.currentEvent = event

            audioCaptureManager.startRecording(
                to: url,
                microphoneUID: recordingState.selectedMicrophoneID,
                systemEnabled: recordingState.systemAudioEnabled,
                micEnabled: recordingState.microphoneEnabled,
                systemVolume: recordingState.systemVolume,
                micVolume: recordingState.microphoneVolume
            )
        }
    }

    func stopAutoRecording() {
        guard isAutoRecording, let audioCaptureManager = audioCaptureManager else { return }

        logger.info("Auto-stopping recording for: \(currentEvent?.title ?? "unknown")")

        DispatchQueue.main.async {
            audioCaptureManager.stopRecording()
            self.isAutoRecording = false
            self.currentEvent = nil
            self.onAutoRecordingStopped?()

            // Reschedule for next event
            self.scheduleNextEvent()
        }
    }

    /// Called when user manually stops a recording that was auto-started
    func recordingWasManuallyStopped() {
        if isAutoRecording {
            isAutoRecording = false
            currentEvent = nil
            eventEndTimer?.invalidate()
            eventEndTimer = nil
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func findAvailablePort() -> UInt16 {
        // Try to find an available port by binding to 0
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return 28734 }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Let OS assign a port
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(socketFD)
            return 28734
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(socketFD, sockPtr, &addrLen)
            }
        }

        let port = UInt16(bigEndian: boundAddr.sin_port)
        close(socketFD)
        return port
    }

    // MARK: - Keychain

    private func saveToKeychain(_ token: String) {
        deleteFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: token.data(using: .utf8)!,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain save failed: \(status)")
        }
    }

    private func loadRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            refreshToken = String(data: data, encoding: .utf8)
        }
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Token Response

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    let token_type: String
}

// MARK: - CommonCrypto Bridge

import CommonCrypto
