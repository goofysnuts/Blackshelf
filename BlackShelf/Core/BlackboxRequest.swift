import Foundation
import SwiftUI

// MARK: - Blackbox Request (nur Hörbücher)
// Gleicher Docker-Dienst auf dem NAS wie in Blackbox/FireSonic, hier ausschließlich der Hörbuch-Teil.
// Anmeldung pro Benutzer: POST /api/auth/login → Token, das wie ein API-Key im Header X-Api-Key mitgeht.
//   GET  /api/me                 → Benutzer & Rechte
//   GET  /api/books/discover     → Neuerscheinungen & Empfehlungen für den angemeldeten Benutzer
//   GET  /api/books/search?q=…   → { books: [...] }
//   GET  /api/books/{id}
//   GET  /api/requests           → eigene Anfragen (Admins: alle), hier gefiltert auf kind == "audiobook"
//   POST /api/requests           { kind: "audiobook", id, requestedBy }
//   POST /api/requests/{id}/retry | /approve | /decline, DELETE /api/requests/{id}
//   GET  /api/health

enum BlackboxConfig {
  private static let urlKey = "blackbox.request.url"
  private static let userKey = "blackbox.request.user"
  private static let apiKeyKey = "blackbox.request.apikey"

  static var url: String {
    get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
  }

  /// Angemeldeter Benutzer (nur zur Anzeige)
  static var username: String {
    get { UserDefaults.standard.string(forKey: userKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: userKey) }
  }

  /// Anmelde-Token oder App-Schlüssel
  static var apiKey: String {
    get { Keychain.get(apiKeyKey) ?? "" }
    set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyKey) }
  }

  static var isConfigured: Bool { !url.isEmpty }
}

struct BBRStatus: Codable, Hashable {
  let id: Int
  let status: String
  let progress: Double?
  let message: String?

  var isBusy: Bool { BBRState.busy.contains(status) }
}

struct BBRBook: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let author: String
  let narrator: String?
  let cover: String?
  let coverSmall: String?
  let year: Int?
  let runtimeMin: Int?
  let series: String?
  let sequence: String?
  let description: String?
  let abridged: Bool?
  let released: String?
  let inLibrary: Bool?
  /// Audiobookshelf-ID, wenn das Buch schon in der Bibliothek ist
  let libraryId: String?
  let request: BBRStatus?

  var seriesText: String? {
    guard let series, !series.isEmpty else { return nil }
    guard let sequence, !sequence.isEmpty else { return series }
    return "\(series), Band \(sequence)"
  }

  var runtimeText: String? {
    guard let m = runtimeMin, m > 0 else { return nil }
    return m >= 60 ? "\(m / 60) Std. \(m % 60) Min." : "\(m) Min."
  }

  var releasedDate: Date? {
    guard let released, released.count >= 10 else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: String(released.prefix(10)))
  }

  var isBusy: Bool { request?.isBusy ?? false }
}

struct BBRSection: Decodable, Identifiable {
  let id: String
  let title: String
  let items: [BBRBook]
}

struct BBRRequest: Codable, Hashable, Identifiable {
  let id: Int
  let kind: String
  let sourceId: String
  let title: String
  let artist: String
  let year: Int?
  let cover: String?
  let status: String
  let message: String?
  let progress: Double?
  /// Wer hat angefragt (Admins sehen alle)
  let users: [String]?
  let mine: Bool?

  enum CodingKeys: String, CodingKey {
    case id, kind, title, artist, year, cover, status, message, progress, users, mine
    case sourceId = "source_id"
  }

  var isBusy: Bool { BBRState.busy.contains(status) }
  var canRetry: Bool { status == "failed" || status == "notfound" }
  var needsApproval: Bool { status == "approval" }
  var isMine: Bool { mine ?? true }
}

struct BBRMe: Decodable {
  let id: Int
  let username: String
  let isAdmin: Bool
  let perms: [String: Bool]
  let weeklyLimit: Int?
  let requestsWeek: Int?

  func can(_ perm: String) -> Bool { perms[perm] ?? false }
}

enum BBRState {
  static let busy: Set<String> = ["approval", "pending", "searching", "downloading", "importing"]

  static func text(_ status: String) -> String {
    switch status {
    case "approval": return "Wartet auf Freigabe"
    case "pending": return "Wartet"
    case "searching": return "Suche Release"
    case "downloading": return "Lädt"
    case "importing": return "Wird einsortiert"
    case "available": return "Verfügbar"
    case "notfound": return "Nicht gefunden"
    case "failed": return "Fehlgeschlagen"
    case "declined": return "Abgelehnt"
    case "cancelled": return "Abgebrochen"
    default: return status
    }
  }

  static func symbol(_ status: String) -> String {
    switch status {
    case "available": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.triangle.fill"
    case "notfound": return "questionmark.circle.fill"
    case "cancelled", "declined": return "xmark.circle.fill"
    case "downloading": return "arrow.down.circle.fill"
    case "approval": return "person.badge.clock.fill"
    default: return "clock.fill"
    }
  }

  static func color(_ status: String) -> Color {
    switch status {
    case "available": return .green
    case "failed", "declined": return .red
    case "notfound", "approval": return .orange
    default: return .secondary
    }
  }
}

struct BlackboxClient {
  enum ClientError: LocalizedError {
    case notConfigured, unauthorized, outdated, server(String)
    var errorDescription: String? {
      switch self {
      case .notConfigured: return "Blackbox Request ist nicht eingerichtet (Einstellungen)."
      case .unauthorized: return "Bitte in den Einstellungen bei Blackbox Request anmelden."
      case .outdated: return "Blackbox Request ist veraltet – bitte den Container auf dem NAS neu bauen."
      case let .server(m): return m
      }
    }
  }

  let base: String
  let apiKey: String

  init(base: String = BlackboxConfig.url, apiKey: String = BlackboxConfig.apiKey) {
    self.base = ABSClient.normalize(base)
    self.apiKey = apiKey
  }

  private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
    guard !base.isEmpty, let url = URL(string: base + path) else { throw ClientError.notConfigured }
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.httpMethod = method
    if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    if code == 401 {
      if path == "/api/auth/login" { throw ClientError.server(detail ?? "Benutzername oder Passwort falsch") }
      throw ClientError.unauthorized
    }
    if code == 404, path.hasPrefix("/api/books") || path.hasPrefix("/api/me") || path.hasPrefix("/api/auth") {
      throw detail == nil || detail == "Not Found" ? ClientError.outdated : ClientError.server(detail!)
    }
    guard (200 ..< 300).contains(code) else {
      throw ClientError.server(detail ?? "Serverfehler (\(code))")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private struct BookList: Decodable { let books: [BBRBook] }
  private struct Sections: Decodable { let sections: [BBRSection] }
  private struct OK: Decodable {}
  private struct Health: Decodable { let nzbget: String?; let indexers: Int? }
  private struct Login: Decodable { let token: String; let user: BBRMe }

  // MARK: Anmeldung

  /// Meldet an und speichert das Token
  @discardableResult
  static func login(base: String, username: String, password: String) async throws -> BBRMe {
    let client = BlackboxClient(base: base, apiKey: "")
    let r: Login = try await client.send("/api/auth/login", method: "POST",
                                         body: ["username": username, "password": password,
                                                "label": "BlackShelf · \(UIDevice.current.name)"])
    BlackboxConfig.url = base
    BlackboxConfig.apiKey = r.token
    BlackboxConfig.username = r.user.username
    return r.user
  }

  static func logout() async {
    let c = BlackboxClient()
    if !c.apiKey.isEmpty { _ = try? await c.send("/api/auth/logout", method: "POST") as OK }
    BlackboxConfig.apiKey = ""
    BlackboxConfig.username = ""
  }

  func me() async throws -> BBRMe { try await send("/api/me") }

  // MARK: Hörbücher

  func discover(refresh: Bool = false) async throws -> [BBRSection] {
    let r: Sections = try await send("/api/books/discover" + (refresh ? "?refresh=true" : ""))
    return r.sections
  }

  func search(_ q: String) async throws -> [BBRBook] {
    let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    let r: BookList = try await send("/api/books/search?q=\(enc)")
    return r.books
  }

  func book(_ id: String) async throws -> BBRBook {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await send("/api/books/\(enc)")
  }

  // MARK: Anfragen

  /// Nur Hörbuch-Anfragen
  func requests() async throws -> [BBRRequest] {
    let all: [BBRRequest] = try await send("/api/requests")
    return all.filter { $0.kind == "audiobook" }
  }

  @discardableResult
  func request(_ bookId: String) async throws -> BBRRequest {
    try await send("/api/requests", method: "POST",
                   body: ["kind": "audiobook", "id": bookId, "requestedBy": "BlackShelf iOS"])
  }

  func retry(_ id: Int) async throws { let _: BBRRequest = try await send("/api/requests/\(id)/retry", method: "POST") }
  func approve(_ id: Int) async throws { let _: OK = try await send("/api/requests/\(id)/approve", method: "POST") }
  func decline(_ id: Int) async throws { let _: OK = try await send("/api/requests/\(id)/decline", method: "POST") }
  func delete(_ id: Int) async throws { let _: OK = try await send("/api/requests/\(id)", method: "DELETE") }

  func health() async throws -> String {
    let h: Health = try await send("/api/health")
    return "Verbunden · NZBGet: \(h.nzbget ?? "–") · Indexer: \(h.indexers ?? 0)"
  }
}
