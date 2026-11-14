import Foundation
import UIKit

enum ABSError: LocalizedError {
  case notConfigured, unauthorized, invalidURL, server(Int, String?)

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Kein Audiobookshelf-Server eingerichtet."
    case .unauthorized: return "Anmeldung abgelaufen – bitte erneut anmelden."
    case .invalidURL: return "Die Serveradresse ist ungültig."
    case let .server(code, msg): return msg?.isEmpty == false ? msg : "Serverfehler (\(code))."
    }
  }
}

/// Zugriff auf die Audiobookshelf-API (inkl. Token-Erneuerung)
@MainActor
final class ABSClient {
  static let shared = ABSClient()

  private enum Keys {
    static let server = "abs.server"
    static let access = "abs.accessToken"
    static let refresh = "abs.refreshToken"
    static let deviceId = "abs.deviceId"
  }

  private(set) var baseURL: String = UserDefaults.standard.string(forKey: Keys.server) ?? ""
  private(set) var accessToken: String? = Keychain.get(Keys.access)
  private var refreshToken: String? = Keychain.get(Keys.refresh)
  private var refreshTask: Task<Bool, Never>?

  /// Wird aufgerufen, wenn die Sitzung endgültig ungültig ist
  var onUnauthorized: (@MainActor () -> Void)?

  var isLoggedIn: Bool { !baseURL.isEmpty && accessToken != nil }

  let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  var deviceId: String {
    if let id = UserDefaults.standard.string(forKey: Keys.deviceId) { return id }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: Keys.deviceId)
    return id
  }

  nonisolated static func normalize(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !s.isEmpty, !s.lowercased().hasPrefix("http") { s = "http://" + s }
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  // MARK: Anmeldung

  func login(server: String, username: String, password: String) async throws -> ABSLoginResponse {
    let base = Self.normalize(server)
    guard let url = URL(string: base + "/login") else { throw ABSError.invalidURL }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("true", forHTTPHeaderField: "x-return-tokens")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw ABSError.server(401, "Benutzername oder Passwort falsch.") }
    guard (200 ..< 300).contains(code) else { throw ABSError.server(code, String(data: data, encoding: .utf8)) }
    let r = try JSONDecoder().decode(ABSLoginResponse.self, from: data)
    guard let token = r.user.accessToken ?? r.user.token else {
      throw ABSError.server(code, "Der Server hat kein Token geliefert.")
    }
    store(base: base, access: token, refresh: r.user.refreshToken)
    return r
  }

  /// Anmeldung mit API-Schlüssel (Audiobookshelf ≥ 2.26: Einstellungen → API-Schlüssel)
  func login(server: String, apiKey: String) async throws {
    let base = Self.normalize(server)
    guard URL(string: base) != nil else { throw ABSError.invalidURL }
    store(base: base, access: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), refresh: nil)
    do {
      let _: ABSMe = try await get("/api/me")
    } catch {
      logout()
      throw error
    }
  }

  func logout() {
    store(base: baseURL, access: nil, refresh: nil)
  }

  private func store(base: String, access: String?, refresh: String?) {
    baseURL = base
    accessToken = access
    refreshToken = refresh
    UserDefaults.standard.set(base, forKey: Keys.server)
    Keychain.set(access, for: Keys.access)
    Keychain.set(refresh, for: Keys.refresh)
  }

  /// Erneuert das Access-Token. Mehrere gleichzeitige 401er teilen sich eine Erneuerung.
  func refreshAccessToken() async -> Bool {
    if let t = refreshTask { return await t.value }
    guard let refresh = refreshToken, let url = URL(string: baseURL + "/auth/refresh") else { return false }
    let task = Task<Bool, Never> { [weak self] in
      guard let self else { return false }
      var req = URLRequest(url: url)
      req.httpMethod = "POST"
      req.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
      guard let result = try? await self.session.data(for: req),
            (result.1 as? HTTPURLResponse)?.statusCode == 200,
            let r = try? JSONDecoder().decode(ABSLoginResponse.self, from: result.0),
            let token = r.user.accessToken ?? r.user.token else { return false }
      self.store(base: self.baseURL, access: token, refresh: r.user.refreshToken ?? refresh)
      return true
    }
    refreshTask = task
    let ok = await task.value
    refreshTask = nil
    return ok
  }

  // MARK: Anfragen

  private func request(_ path: String, method: String, body: Any?, retry: Bool = true) async throws -> Data {
    guard !baseURL.isEmpty, let token = accessToken else { throw ABSError.notConfigured }
    guard let url = URL(string: baseURL + path) else { throw ABSError.invalidURL }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 {
      if retry, await refreshAccessToken() {
        return try await request(path, method: method, body: body, retry: false)
      }
      onUnauthorized?()
      throw ABSError.unauthorized
    }
    guard (200 ..< 300).contains(code) else {
      throw ABSError.server(code, String(data: data, encoding: .utf8).map { String($0.prefix(200)) })
    }
    return data
  }

  func get<T: Decodable>(_ path: String) async throws -> T {
    let data = try await request(path, method: "GET", body: nil)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func send<T: Decodable>(_ path: String, method: String = "POST", body: Any? = nil) async throws -> T {
    let data = try await request(path, method: method, body: body)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func fire(_ path: String, method: String = "POST", body: Any? = nil) async throws {
    _ = try await request(path, method: method, body: body)
  }

  // MARK: URLs (Bilder & Streams brauchen das Token als Query-Parameter)

  func authorizedURL(_ path: String, query: [URLQueryItem] = []) -> URL? {
    guard var comps = URLComponents(string: baseURL + path) else { return nil }
    var items = comps.queryItems ?? []
    items.append(contentsOf: query)
    if let accessToken { items.append(URLQueryItem(name: "token", value: accessToken)) }
    comps.queryItems = items
    return comps.url
  }

  func coverURL(_ itemId: String, width: Int = 400) -> URL? {
    authorizedURL("/api/items/\(itemId)/cover", query: [URLQueryItem(name: "width", value: String(width)),
                                                       URLQueryItem(name: "format", value: "jpeg")])
  }

  func authorImageURL(_ authorId: String, width: Int = 300) -> URL? {
    authorizedURL("/api/authors/\(authorId)/image", query: [URLQueryItem(name: "width", value: String(width))])
  }

  func streamURL(_ contentUrl: String) -> URL? { authorizedURL(contentUrl) }

  // MARK: Endpunkte

  func libraries() async throws -> [ABSLibrary] {
    let r: ABSLibrariesResponse = try await get("/api/libraries")
    return r.libraries
  }

  func me() async throws -> ABSMe { try await get("/api/me") }

  func personalized(_ libraryId: String) async throws -> [ABSShelf] {
    let r: [Lossy<ABSShelf>] = try await get("/api/libraries/\(libraryId)/personalized?limit=12")
    return r.compactMap(\.value)
  }

  func items(_ libraryId: String, sort: String, desc: Bool, page: Int, limit: Int = 60,
             filter: String? = nil) async throws -> ABSItemsPage {
    var q = "sort=\(sort)&desc=\(desc ? 1 : 0)&limit=\(limit)&page=\(page)&minified=1"
    if let filter { q += "&filter=\(filter)" }
    return try await get("/api/libraries/\(libraryId)/items?\(q)")
  }

  func series(_ libraryId: String, page: Int, limit: Int = 50) async throws -> ABSSeriesPage {
    try await get("/api/libraries/\(libraryId)/series?sort=name&limit=\(limit)&page=\(page)&minified=1")
  }

  /// Bücher einer Serie in Reihenfolge der Bandnummer
  func seriesBooks(_ libraryId: String, seriesId: String) async throws -> [ABSItem] {
    let b64 = Data(seriesId.utf8).base64EncodedString()
    let enc = ("series." + b64).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
    let r = try await items(libraryId, sort: "media.metadata.title", desc: false, page: 0, limit: 200, filter: enc)
    func num(_ s: String?) -> Double { Double(s ?? "") ?? .greatestFiniteMagnitude }
    return r.results.sorted { a, b in
      let sa = a.media.metadata.series?.first(where: { $0.id == seriesId })?.sequence ?? a.sequence
      let sb = b.media.metadata.series?.first(where: { $0.id == seriesId })?.sequence ?? b.sequence
      return num(sa) < num(sb)
    }
  }

  /// Genres der Bibliothek (Filterdaten von Audiobookshelf)
  func genres(_ libraryId: String) async throws -> [String] {
    struct FilterData: Decodable { let genres: [String]? }
    let r: FilterData = try await get("/api/libraries/\(libraryId)/filterdata")
    return (r.genres ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  static func genreFilter(_ name: String) -> String {
    let b64 = Data(name.utf8).base64EncodedString()
    return ("genres." + b64).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
  }

  func authors(_ libraryId: String) async throws -> [ABSAuthor] {
    let r: ABSAuthorsResponse = try await get("/api/libraries/\(libraryId)/authors")
    return r.authors.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func author(_ id: String) async throws -> ABSAuthor {
    try await get("/api/authors/\(id)?include=items")
  }

  func collections(_ libraryId: String) async throws -> [ABSCollection] {
    let r: ABSCollectionsPage = try await get("/api/libraries/\(libraryId)/collections?limit=100&minified=1")
    return r.results
  }

  func search(_ libraryId: String, _ q: String) async throws -> ABSSearchResult {
    let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    return try await get("/api/libraries/\(libraryId)/search?q=\(enc)&limit=20")
  }

  func item(_ id: String) async throws -> ABSItem {
    try await get("/api/items/\(id)?expanded=1&include=progress")
  }

  func startPlayback(_ itemId: String) async throws -> ABSPlaySession {
    let body: [String: Any] = [
      "deviceInfo": [
        "clientName": "BlackShelf",
        "clientVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        "deviceId": deviceId,
        "manufacturer": "Apple",
        "model": UIDevice.current.model,
      ],
      "forceDirectPlay": true,
      "forceTranscode": false,
      "mediaPlayer": "AVPlayer",
      "supportedMimeTypes": ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/x-m4b", "audio/aac",
                             "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav", "audio/aiff"],
    ]
    return try await send("/api/items/\(itemId)/play", body: body)
  }

  func syncSession(_ sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
    try await fire("/api/session/\(sessionId)/sync",
                   body: ["currentTime": currentTime, "timeListened": timeListened, "duration": duration])
  }

  func closeSession(_ sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
    try await fire("/api/session/\(sessionId)/close",
                   body: ["currentTime": currentTime, "timeListened": timeListened, "duration": duration])
  }

  /// Hörstatistik: eigene (userId nil) oder – als Admin – die eines anderen Nutzers
  func listeningStats(userId: String? = nil) async throws -> ABSListeningStats {
    if let userId { return try await get("/api/users/\(userId)/listening-stats") }
    return try await get("/api/me/listening-stats")
  }

  /// Alle Nutzer (nur für Admins)
  func users() async throws -> [ABSUser] {
    let r: ABSUsersResponse = try await get("/api/users")
    return r.users.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
  }

  func setFinished(_ itemId: String, _ finished: Bool) async throws {
    try await fire("/api/me/progress/\(itemId)", method: "PATCH", body: ["isFinished": finished])
  }

  func resetProgress(_ itemId: String) async throws {
    try await fire("/api/me/progress/\(itemId)", method: "PATCH",
                   body: ["isFinished": false, "currentTime": 0, "progress": 0])
  }
}
