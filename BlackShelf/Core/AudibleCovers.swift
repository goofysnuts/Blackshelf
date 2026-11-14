import Foundation
import Observation

/// Holt für Bücher das offizielle Audible-Cover (statt abfotografierter CD-Hüllen).
/// Mit ASIN direkt, sonst über die Audible-Katalogsuche (Titel + Autor). Ergebnisse werden dauerhaft gemerkt.
@Observable
@MainActor
final class AudibleCovers {
  static let shared = AudibleCovers()

  /// Einstellung „Cover von Audible“
  var enabled: Bool = UserDefaults.standard.object(forKey: "covers.audible.enabled") as? Bool ?? true {
    didSet { UserDefaults.standard.set(enabled, forKey: "covers.audible.enabled") }
  }

  /// itemId → Cover-URL (1024 px); leerer String = auf Audible nicht gefunden
  private var map: [String: String] = UserDefaults.standard.dictionary(forKey: "covers.audible.map") as? [String: String] ?? [:]

  /// Zuordnung von Blackbox Request (itemId → URL, "" = keins gefunden) – hat Vorrang vor der eigenen Suche
  private var serverMap: [String: String] = UserDefaults.standard.dictionary(forKey: "covers.server.map") as? [String: String] ?? [:]
  /// Server liefert Cover → keine eigene Suche mehr (die ist ungenauer)
  private(set) var serverActive: Bool = UserDefaults.standard.bool(forKey: "covers.server.active")
  @ObservationIgnored private var serverTask: Task<Void, Never>?

  @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var slots = 4
  @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
  @ObservationIgnored private var saveScheduled = false

  private static let api = "https://api.audible.de/1.0/catalog/products"

  enum Lookup { case unknown, none, found(URL) }

  func lookup(_ itemId: String, size: Int) -> Lookup {
    if let s = serverMap[itemId] {
      guard !s.isEmpty else { return .none }
      let sized = size >= 1024 ? s : s.replacingOccurrences(of: "_SL1024_", with: "_SL\(size)_")
      return URL(string: sized).map(Lookup.found) ?? .none
    }
    if serverActive { return .none }
    guard let s = map[itemId] else { return .unknown }
    guard !s.isEmpty else { return .none }
    let sized = size >= 1024 ? s : s.replacingOccurrences(of: "_SL1024_", with: "_SL\(size)_")
    return URL(string: sized).map(Lookup.found) ?? .none
  }

  /// Cover-URL für ein Buch: Audible wenn bekannt, sonst Audiobookshelf
  func url(for item: ABSItem, width: Int) -> URL? {
    let absURL = ABSClient.shared.coverURL(item.id, width: width)
    guard enabled else { return absURL }
    if case let .found(u) = lookup(item.id, size: width > 500 ? 1024 : 500) { return u }
    return absURL
  }

  /// Sucht das Audible-Cover im Hintergrund (einmal pro Buch)
  func resolveIfNeeded(_ item: ABSItem) {
    guard enabled, !serverActive, map[item.id] == nil, running[item.id] == nil else { return }
    running[item.id] = Task {
      await acquire()
      let found = await Self.find(item)
      release()
      map[item.id] = found ?? ""
      running[item.id] = nil
      scheduleSave()
    }
  }

  /// Alle gemerkten Treffer verwerfen (z. B. nach falschem Cover)
  func reset() {
    map = [:]
    UserDefaults.standard.removeObject(forKey: "covers.audible.map")
    refreshFromServer()
  }

  /// Cover-Zuordnung von Blackbox Request laden; solange der Server noch zuordnet, alle 10 s nachladen
  func refreshFromServer() {
    guard enabled, BlackboxConfig.isConfigured, serverTask == nil else { return }
    serverTask = Task {
      defer { serverTask = nil }
      for _ in 0 ..< 60 {
        guard let r = try? await BlackboxClient().libraryCovers() else { return }
        if !r.covers.isEmpty || !serverActive {
          serverMap = r.covers
          serverActive = true
          UserDefaults.standard.set(r.covers, forKey: "covers.server.map")
          UserDefaults.standard.set(true, forKey: "covers.server.active")
        }
        guard r.running else { return }
        try? await Task.sleep(nanoseconds: 10_000_000_000)
      }
    }
  }

  func forget(_ itemId: String) {
    map[itemId] = nil
    scheduleSave()
  }

  // MARK: Begrenzung paralleler Anfragen

  private func acquire() async {
    if slots > 0 { slots -= 1; return }
    await withCheckedContinuation { waiting.append($0) }
  }

  private func release() {
    if waiting.isEmpty { slots += 1 } else { waiting.removeFirst().resume() }
  }

  private func scheduleSave() {
    guard !saveScheduled else { return }
    saveScheduled = true
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      UserDefaults.standard.set(map, forKey: "covers.audible.map")
      saveScheduled = false
    }
  }

  // MARK: Audible-API

  private struct ProductResponse: Decodable { let product: Product? }
  private struct SearchResponse: Decodable { let products: [Product]? }
  private struct Product: Decodable {
    struct Person: Decodable { let name: String? }
    let asin: String?
    let title: String?
    let authors: [Person]?
    let product_images: [String: String]?
  }

  nonisolated private static func fetch<T: Decodable>(_ url: URL) async -> T? {
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let result = try? await URLSession.shared.data(for: req),
          (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return try? JSONDecoder().decode(T.self, from: result.0)
  }

  nonisolated private static func image(_ p: Product?) -> String? {
    guard let imgs = p?.product_images else { return nil }
    return imgs["1024"] ?? imgs["500"] ?? imgs.values.first
  }

  nonisolated private static func find(_ item: ABSItem) async -> String? {
    let meta = item.media.metadata
    // 1. ASIN aus Audiobookshelf
    if let asin = meta.asin?.trimmingCharacters(in: .whitespaces), !asin.isEmpty,
       let url = URL(string: "\(api)/\(asin)?response_groups=media&image_sizes=500,1024"),
       let r: ProductResponse = await fetch(url), let img = image(r.product) {
      return img
    }
    // 2. Suche nach Titel und Autor
    guard let title = meta.title, !title.isEmpty else { return nil }
    let author = meta.authors?.first?.name ?? meta.authorName?.components(separatedBy: ",").first ?? ""
    let wanted = normalize(cleanTitle(title))
    let wantedAuthor = normalize(author)

    var queries: [[URLQueryItem]] = [[URLQueryItem(name: "title", value: cleanTitle(title))]]
    if !author.isEmpty { queries[0].append(URLQueryItem(name: "author", value: author)) }
    queries.append([URLQueryItem(name: "keywords", value: "\(cleanTitle(title)) \(author)")])

    for q in queries {
      var comps = URLComponents(string: api)!
      comps.queryItems = q + [
        URLQueryItem(name: "num_results", value: "10"),
        URLQueryItem(name: "products_sort_by", value: "Relevance"),
        URLQueryItem(name: "response_groups", value: "media,contributors,product_desc"),
        URLQueryItem(name: "image_sizes", value: "500,1024"),
      ]
      guard let url = comps.url, let r: SearchResponse = await fetch(url) else { continue }
      let products = r.products ?? []
      // Titel muss passen – lieber das eigene Cover als ein falsches
      let match = products.first { p in
        let t = normalize(cleanTitle(p.title ?? ""))
        guard !t.isEmpty, t == wanted || (min(t.count, wanted.count) >= 5 && (t.contains(wanted) || wanted.contains(t)))
        else { return false }
        guard !wantedAuthor.isEmpty, let authors = p.authors, !authors.isEmpty else { return true }
        return authors.contains { a in
          let n = normalize(a.name ?? "")
          return !n.isEmpty && (n.contains(wantedAuthor) || wantedAuthor.contains(n) ||
            n.split(separator: " ").last == wantedAuthor.split(separator: " ").last)
        }
      }
      if let img = image(match) { return img }
    }
    return nil
  }

  /// Zusätze wie „(Ungekürzt)“, „- Teil 1“ oder „: Roman“ entfernen
  nonisolated static func cleanTitle(_ s: String) -> String {
    var t = s
    t = t.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "(?i)\\s*[-–:]\\s*(ungekürzt|gekürzt|hörbuch|roman|thriller|krimi)\\b.*$", with: "", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static func normalize(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
      .replacingOccurrences(of: "ß", with: "ss")
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }
}
