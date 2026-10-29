import Foundation

struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Minimal Supabase client: anonymous auth that persists in the Keychain, plus Postgres function calls.
/// Every read and write in geo# is a database function (backend/schema.sql), so that's all we need.
actor SupabaseClient {
    static let shared = SupabaseClient()

    nonisolated var isConfigured: Bool { !Secrets.supabaseURL.isEmpty && !Secrets.supabaseAnonKey.isEmpty }

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshing: Task<Void, Error>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            // Postgres sometimes omits the colon in the offset: 2026-10-29T14:05:00.123+00
            let fixed = s.count > 3 && (s.hasSuffix("+00") || s.hasSuffix("-00")) ? s + ":00" : s
            if let date = withFraction.date(from: fixed) ?? plain.date(from: fixed) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    // MARK: auth

    /// Makes sure we have a valid access token: refresh if we can, otherwise sign in anonymously.
    func ensureSession() async throws {
        if accessToken != nil, expiresAt.timeIntervalSinceNow > 60 { return }
        if let refreshing { return try await refreshing.value }
        let task = Task {
            defer { self.refreshing = nil }
            if let refresh = Keychain.get("refresh") {
                do {
                    try await self.auth(path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
                    return
                } catch {
                    // A dead refresh token means starting over as a new anonymous user (who needs a new invite).
                    Keychain.set("refresh", nil)
                }
            }
            try await self.auth(path: "signup", body: ["data": [String: String]()])
        }
        refreshing = task
        try await task.value
    }

    private func auth(path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: Secrets.supabaseURL + "/auth/v1/" + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await send(req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 300,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw APIError(message: Self.describe(data, fallback: "couldn't sign in. turn on anonymous sign-ins in supabase"))
        }
        accessToken = token
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        expiresAt = Date().addingTimeInterval(ttl)
        if let refresh = obj["refresh_token"] as? String { Keychain.set("refresh", refresh) }
    }

    /// Forget this device's login entirely (after deleting the account).
    func signOutLocally() {
        accessToken = nil
        expiresAt = .distantPast
        Keychain.set("refresh", nil)
    }

    var bearer: String? { accessToken }

    // MARK: calls

    func rpc<T: Decodable>(_ fn: String, _ args: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        let data = try await rpcData(fn, args)
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            print("geo#: decode \(fn) failed: \(error)\n\(String(data: data.prefix(600), encoding: .utf8) ?? "")")
            throw APIError(message: "the server sent something the app couldn't read")
        }
    }

    func rpcVoid(_ fn: String, _ args: [String: Any] = [:]) async throws {
        _ = try await rpcData(fn, args)
    }

    /// Decodes an RPC that may return SQL null.
    func rpcOptional<T: Decodable>(_ fn: String, _ args: [String: Any] = [:], as: T.Type = T.self) async throws -> T? {
        let data = try await rpcData(fn, args)
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "null" { return nil }
        return try Self.decoder.decode(T.self, from: data)
    }

    private func rpcData(_ fn: String, _ args: [String: Any]) async throws -> Data {
        guard isConfigured else { throw APIError(message: "geo# isn't connected to a server yet") }
        for attempt in 0..<2 {
            try await ensureSession()
            var req = URLRequest(url: URL(string: Secrets.supabaseURL + "/rest/v1/rpc/" + fn)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: args)
            let (data, resp) = try await send(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 500
            if code == 401 && attempt == 0 { accessToken = nil; continue }
            guard code < 300 else { throw APIError(message: Self.describe(data, fallback: "server error \(code)")) }
            return data
        }
        throw APIError(message: "couldn't sign in")
    }

    /// Calls a Supabase Edge Function as the signed-in user.
    func function(_ name: String) async throws -> [String: Any] {
        try await ensureSession()
        var req = URLRequest(url: URL(string: Secrets.supabaseURL + "/functions/v1/" + name)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await send(req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 300,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: Self.describe(data, fallback: "\(name) failed"))
        }
        return obj
    }

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            throw APIError(message: "no connection. check your data or wifi")
        }
    }

    /// Turns database errors into short lines a person can act on.
    static func describe(_ data: Data, fallback: String) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = (obj?["message"] ?? obj?["msg"] ?? obj?["error_description"] ?? obj?["error"]) as? String ?? fallback
        switch msg {
        case "bad_invite": return "that crew code doesn't work or is used up"
        case "handle_taken": return "that name is taken"
        case "bad_handle": return "names are 2 to 20 letters, numbers, dots or underscores"
        case "not_a_member": return "you need a crew code to do that"
        case "slow_down": return "you're going fast. take a breather"
        case "not_allowed": return "that comment isn't allowed"
        case "wall_gone": return "that wall has changed and is archived"
        case "not_signed_in": return "couldn't sign in"
        default: return msg
        }
    }
}

struct Empty: Decodable {}
