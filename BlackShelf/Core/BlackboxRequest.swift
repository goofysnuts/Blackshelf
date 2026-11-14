import Foundation
import SwiftUI

// MARK: - Blackbox Request (nur Hörbücher)
// Gleicher Docker-Dienst auf dem NAS wie in Blackbox/FireSonic, hier ausschließlich der Hörbuch-Teil:
//   GET  /api/books/search?q=…   → { books: [...] }
//   GET  /api/books/{id}
//   GET  /api/requests           → alle Anfragen (gefiltert auf kind == "audiobook")
//   POST /api/requests           { kind: "audiobook", id, requestedBy }
//   POST /api/requests/{id}/retry, DELETE /api/requests/{id}
//   GET  /api/health

enum BlackboxConfig {
  private static let urlKey = "blackbox.request.url"
  private static let apiKeyKey = "blackbox.request.apikey"

  static var url: String {
    get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
  }

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
  let inLibrary: Bool?
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

  var isBusy: Bool { request?.isBusy ?? false }
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

  enum CodingKeys: String, CodingKey {
    case id, kind, title, artist, year, cover, status, message, progress
    case sourceId = "source_id"
  }

  var isBusy: Bool { BBRState.busy.contains(status) }
  var canRetry: Bool { status == "failed" || status == "notfound" }
}

enum BBRState {
  static let busy: Set<String> = ["pending", "searching", "downloading", "importing"]

  static func text(_ status: String) -> String {
    switch status {
    case "pending": return "Wartet"
    case "searching": return "Suche Release"
    case "downloading": return "Lädt"
    case "importing": return "Wird einsortiert"
    case "available": return "Verfügbar"
    case "notfound": return "Nicht gefunden"
    case "failed": return "Fehlgeschlagen"
    case "cancelled": return "Abgebrochen"
    default: return status
    }
  }

  static func symbol(_ status: String) -> String {
    switch status {
    case "available": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.triangle.fill"
    case "notfound": return "questionmark.circle.fill"
    case "cancelled": return "xmark.circle.fill"
    case "downloading": return "arrow.down.circle.fill"
    default: return "clock.fill"
    }
  }

  static func color(_ status: String) -> Color {
    switch status {
    case "available": return .green
    case "failed": return .red
    case "notfound": return .orange
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
      case .unauthorized: return "API-Schlüssel für Blackbox Request fehlt oder ist falsch."
      case .outdated: return "Blackbox Request kennt noch keine Hörbücher – bitte den Container auf dem NAS neu bauen."
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
    var req = URLRequest(url: url, timeoutInterval: 25)
    req.httpMethod = method
    if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw ClientError.unauthorized }
    if code == 404, path.hasPrefix("/api/books") { throw ClientError.outdated }
    guard (200 ..< 300).contains(code) else {
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw ClientError.server(detail ?? "Serverfehler (\(code))")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private struct BookList: Decodable { let books: [BBRBook] }
  private struct OK: Decodable {}
  private struct Health: Decodable { let nzbget: String?; let indexers: Int? }

  func search(_ q: String) async throws -> [BBRBook] {
    let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    let r: BookList = try await send("/api/books/search?q=\(enc)")
    return r.books
  }

  func book(_ id: String) async throws -> BBRBook {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await send("/api/books/\(enc)")
  }

  /// Nur Hörbuch-Anfragen
  func requests() async throws -> [BBRRequest] {
    let all: [BBRRequest] = try await send("/api/requests")
    return all.filter { $0.kind == "audiobook" }
  }

  @discardableResult
  func request(_ bookId: String) async throws -> BBRRequest {
    try await send("/api/requests", method: "POST",
                   body: ["kind": "audiobook", "id": bookId, "requestedBy": "BlackShelf iOS", "replace": "false"])
  }

  func retry(_ id: Int) async throws { let _: BBRRequest = try await send("/api/requests/\(id)/retry", method: "POST") }
  func delete(_ id: Int) async throws { let _: OK = try await send("/api/requests/\(id)", method: "DELETE") }

  func health() async throws -> String {
    let h: Health = try await send("/api/health")
    return "Verbunden · NZBGet: \(h.nzbget ?? "–") · Indexer: \(h.indexers ?? 0)"
  }
}
