import Foundation

// MARK: - Nachsichtiges Decoding (Audiobookshelf liefert je nach Endpunkt/Version leicht andere Formen)

extension KeyedDecodingContainer {
  func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
    (try? decodeIfPresent(type, forKey: key)) ?? nil
  }

  /// Zahl, die mal als String, mal als Zahl kommt
  func flexibleString(_ key: Key) -> String? {
    if let s = lenient(String.self, key) { return s }
    if let i = lenient(Int.self, key) { return String(i) }
    if let d = lenient(Double.self, key) { return String(d) }
    return nil
  }
}

// MARK: - Bibliothek

struct ABSLibrary: Codable, Identifiable, Hashable {
  let id: String
  let name: String
  let mediaType: String?

  var isBookLibrary: Bool { (mediaType ?? "book") == "book" }
}

struct ABSLibrariesResponse: Decodable { let libraries: [ABSLibrary] }

struct ABSNamed: Codable, Hashable, Identifiable {
  let id: String
  let name: String
}

struct ABSSeriesRef: Codable, Hashable, Identifiable {
  let id: String
  let name: String
  let sequence: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenient(String.self, .id) ?? UUID().uuidString
    name = c.lenient(String.self, .name) ?? ""
    sequence = c.flexibleString(.sequence)
  }
}

struct ABSChapter: Codable, Hashable, Identifiable {
  let id: Int
  let start: Double
  let end: Double
  let title: String

  init(id: Int, start: Double, end: Double, title: String) {
    self.id = id; self.start = start; self.end = end; self.title = title
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenient(Int.self, .id) ?? 0
    start = c.lenient(Double.self, .start) ?? 0
    end = c.lenient(Double.self, .end) ?? 0
    title = c.lenient(String.self, .title) ?? ""
  }

  var duration: Double { max(0, end - start) }
}

struct ABSMetadata: Codable, Hashable {
  var title: String?
  var subtitle: String?
  var authorName: String?
  var authors: [ABSNamed]?
  var narratorName: String?
  var narrators: [String]?
  var seriesName: String?
  var series: [ABSSeriesRef]?
  var description: String?
  var publishedYear: String?
  var publisher: String?
  var genres: [String]?
  var language: String?
  var abridged: Bool?
  var asin: String?
  var isbn: String?

  enum CodingKeys: String, CodingKey {
    case title, subtitle, authorName, authors, narratorName, narrators, seriesName, series
    case description, publishedYear, publisher, genres, language, abridged, asin, isbn
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = c.lenient(String.self, .title)
    subtitle = c.lenient(String.self, .subtitle)
    authorName = c.lenient(String.self, .authorName)
    authors = c.lenient([ABSNamed].self, .authors)
    narratorName = c.lenient(String.self, .narratorName)
    narrators = c.lenient([String].self, .narrators)
    seriesName = c.lenient(String.self, .seriesName)
    // erweitert: Array, manchmal (Serien-Filter) ein einzelnes Objekt
    if let arr = c.lenient([ABSSeriesRef].self, .series) {
      series = arr
    } else if let one = c.lenient(ABSSeriesRef.self, .series) {
      series = [one]
    }
    description = c.lenient(String.self, .description)
    publishedYear = c.flexibleString(.publishedYear)
    publisher = c.lenient(String.self, .publisher)
    genres = c.lenient([String].self, .genres)
    language = c.lenient(String.self, .language)
    abridged = c.lenient(Bool.self, .abridged)
    asin = c.lenient(String.self, .asin)
    isbn = c.lenient(String.self, .isbn)
  }

  var displayAuthor: String {
    if let a = authorName, !a.isEmpty { return a }
    if let a = authors, !a.isEmpty { return a.map(\.name).joined(separator: ", ") }
    return "Unbekannter Autor"
  }

  var displayNarrator: String? {
    if let n = narratorName, !n.isEmpty { return n }
    if let n = narrators, !n.isEmpty { return n.joined(separator: ", ") }
    return nil
  }

  var displaySeries: String? {
    if let s = series?.first, !s.name.isEmpty {
      if let seq = s.sequence, !seq.isEmpty { return "\(s.name), Band \(seq)" }
      return s.name
    }
    if let s = seriesName, !s.isEmpty { return s.replacingOccurrences(of: " #", with: ", Band ") }
    return nil
  }
}

struct ABSTrack: Codable, Hashable {
  let index: Int
  let startOffset: Double
  let duration: Double
  let title: String?
  let contentUrl: String
  let mimeType: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    index = c.lenient(Int.self, .index) ?? 0
    startOffset = c.lenient(Double.self, .startOffset) ?? 0
    duration = c.lenient(Double.self, .duration) ?? 0
    title = c.lenient(String.self, .title)
    contentUrl = c.lenient(String.self, .contentUrl) ?? ""
    mimeType = c.lenient(String.self, .mimeType)
  }
}

struct ABSBookMedia: Codable, Hashable {
  var metadata: ABSMetadata
  var duration: Double?
  var numChapters: Int?
  var chapters: [ABSChapter]?
  var coverPath: String?

  enum CodingKeys: String, CodingKey { case metadata, duration, numChapters, chapters, coverPath }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    metadata = try c.decode(ABSMetadata.self, forKey: .metadata)
    duration = c.lenient(Double.self, .duration)
    numChapters = c.lenient(Int.self, .numChapters)
    chapters = c.lenient([ABSChapter].self, .chapters)
    coverPath = c.lenient(String.self, .coverPath)
  }
}

struct ABSItem: Codable, Identifiable, Hashable {
  let id: String
  var libraryId: String?
  var mediaType: String?
  var addedAt: Double?
  var media: ABSBookMedia
  var userMediaProgress: ABSProgress?
  /// in Serien-Ansichten vorhanden
  var sequence: String?

  enum CodingKeys: String, CodingKey { case id, libraryId, mediaType, addedAt, media, userMediaProgress, sequence }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    libraryId = c.lenient(String.self, .libraryId)
    mediaType = c.lenient(String.self, .mediaType)
    addedAt = c.lenient(Double.self, .addedAt)
    media = try c.decode(ABSBookMedia.self, forKey: .media)
    userMediaProgress = c.lenient(ABSProgress.self, .userMediaProgress)
    sequence = c.flexibleString(.sequence)
  }

  var title: String { media.metadata.title ?? "Ohne Titel" }
  var author: String { media.metadata.displayAuthor }
  var duration: Double { media.duration ?? 0 }
  var isBook: Bool { (mediaType ?? "book") == "book" }
}

struct ABSItemsPage: Decodable {
  let results: [ABSItem]
  let total: Int?

  enum CodingKeys: String, CodingKey { case results, total }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // fehlerhafte Einzelelemente überspringen statt die ganze Seite zu verwerfen
    results = (c.lenient([Lossy<ABSItem>].self, .results) ?? []).compactMap(\.value)
    total = c.lenient(Int.self, .total)
  }
}

/// Dekodiert ein Element oder ignoriert es still
struct Lossy<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Fortschritt

struct ABSProgress: Codable, Hashable {
  let libraryItemId: String
  let episodeId: String?
  var duration: Double
  var progress: Double
  var currentTime: Double
  var isFinished: Bool
  var lastUpdate: Double?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    libraryItemId = c.lenient(String.self, .libraryItemId) ?? ""
    episodeId = c.lenient(String.self, .episodeId)
    duration = c.lenient(Double.self, .duration) ?? 0
    progress = c.lenient(Double.self, .progress) ?? 0
    currentTime = c.lenient(Double.self, .currentTime) ?? 0
    isFinished = c.lenient(Bool.self, .isFinished) ?? false
    lastUpdate = c.lenient(Double.self, .lastUpdate)
  }
}

struct ABSMe: Decodable {
  let id: String?
  let username: String?
  let type: String?
  let mediaProgress: [ABSProgress]

  enum CodingKeys: String, CodingKey { case id, username, type, mediaProgress }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenient(String.self, .id)
    username = c.lenient(String.self, .username)
    type = c.lenient(String.self, .type)
    mediaProgress = (c.lenient([Lossy<ABSProgress>].self, .mediaProgress) ?? []).compactMap(\.value)
  }
}

// MARK: - Serien, Autoren, Sammlungen

struct ABSSeries: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let books: [ABSItem]

  enum CodingKeys: String, CodingKey { case id, name, books }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = c.lenient(String.self, .name) ?? ""
    books = (c.lenient([Lossy<ABSItem>].self, .books) ?? []).compactMap(\.value)
  }
}

struct ABSSeriesPage: Decodable {
  let results: [ABSSeries]
  let total: Int?
}

struct ABSAuthor: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let numBooks: Int?
  let imagePath: String?
  let description: String?
  let libraryItems: [ABSItem]?

  enum CodingKeys: String, CodingKey { case id, name, numBooks, imagePath, description, libraryItems }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = c.lenient(String.self, .name) ?? ""
    numBooks = c.lenient(Int.self, .numBooks)
    imagePath = c.lenient(String.self, .imagePath)
    description = c.lenient(String.self, .description)
    libraryItems = c.lenient([Lossy<ABSItem>].self, .libraryItems)?.compactMap(\.value)
  }
}

struct ABSAuthorsResponse: Decodable { let authors: [ABSAuthor] }

struct ABSCollection: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let description: String?
  let books: [ABSItem]

  enum CodingKeys: String, CodingKey { case id, name, description, books }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = c.lenient(String.self, .name) ?? ""
    description = c.lenient(String.self, .description)
    books = (c.lenient([Lossy<ABSItem>].self, .books) ?? []).compactMap(\.value)
  }
}

struct ABSCollectionsPage: Decodable { let results: [ABSCollection] }

// MARK: - Startseite (personalisiert)

struct ABSShelf: Decodable, Identifiable {
  let id: String
  let label: String
  let type: String
  let items: [ABSItem]
  let series: [ABSSeries]
  let authors: [ABSAuthor]

  enum CodingKeys: String, CodingKey { case id, label, type, entities }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenient(String.self, .id) ?? UUID().uuidString
    label = c.lenient(String.self, .label) ?? ""
    type = c.lenient(String.self, .type) ?? ""
    items = type == "book" ? (c.lenient([Lossy<ABSItem>].self, .entities) ?? []).compactMap(\.value) : []
    series = type == "series" ? (c.lenient([Lossy<ABSSeries>].self, .entities) ?? []).compactMap(\.value) : []
    authors = type == "authors" ? (c.lenient([Lossy<ABSAuthor>].self, .entities) ?? []).compactMap(\.value) : []
  }

  /// Deutsche Bezeichnungen für die bekannten Regale
  var germanLabel: String {
    switch id {
    case "continue-listening": return "Weiterhören"
    case "continue-series": return "Serie fortsetzen"
    case "recently-added": return "Neu hinzugefügt"
    case "recent-series": return "Neue Serien"
    case "discover": return "Entdecken"
    case "listen-again": return "Nochmal hören"
    case "newest-authors": return "Neue Autoren"
    case "episodes-recently-added": return "Neue Folgen"
    default: return label
    }
  }
}

// MARK: - Suche

struct ABSSearchResult: Decodable {
  let books: [ABSItem]
  let series: [ABSSeries]
  let authors: [ABSAuthor]

  private struct BookHit: Decodable { let libraryItem: ABSItem }
  private struct SeriesHit: Decodable {
    let series: ABSNamed
    let books: [Lossy<ABSItem>]?
  }

  enum CodingKeys: String, CodingKey { case book, series, authors }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    books = (c.lenient([Lossy<BookHit>].self, .book) ?? []).compactMap { $0.value?.libraryItem }
    series = (c.lenient([Lossy<SeriesHit>].self, .series) ?? []).compactMap(\.value).map {
      ABSSeries(id: $0.series.id, name: $0.series.name, books: ($0.books ?? []).compactMap(\.value))
    }
    authors = (c.lenient([Lossy<ABSAuthor>].self, .authors) ?? []).compactMap(\.value)
  }

  static let empty = ABSSearchResult()
  private init() { books = []; series = []; authors = [] }
}

extension ABSSeries {
  init(id: String, name: String, books: [ABSItem]) {
    self.id = id; self.name = name; self.books = books
  }
}

// MARK: - Wiedergabe

struct ABSPlaySession: Decodable {
  let id: String
  let libraryItemId: String
  let currentTime: Double
  let duration: Double
  let chapters: [ABSChapter]
  let audioTracks: [ABSTrack]

  enum CodingKeys: String, CodingKey { case id, libraryItemId, currentTime, duration, chapters, audioTracks }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    libraryItemId = c.lenient(String.self, .libraryItemId) ?? ""
    currentTime = c.lenient(Double.self, .currentTime) ?? 0
    duration = c.lenient(Double.self, .duration) ?? 0
    chapters = c.lenient([ABSChapter].self, .chapters) ?? []
    audioTracks = (c.lenient([ABSTrack].self, .audioTracks) ?? []).sorted { $0.startOffset < $1.startOffset }
  }
}

// MARK: - Anmeldung

struct ABSLoginResponse: Decodable {
  struct User: Decodable {
    let id: String?
    let username: String?
    let token: String?
    let accessToken: String?
    let refreshToken: String?
  }
  let user: User
  let userDefaultLibraryId: String?
}

// MARK: - Hörstatistik

struct ABSUser: Decodable, Identifiable, Hashable {
  let id: String
  let username: String
  let type: String?
  let isActive: Bool?
}

struct ABSUsersResponse: Decodable { let users: [ABSUser] }

struct ABSListeningStats: Decodable {
  struct Item: Identifiable, Hashable {
    let id: String
    let timeListening: Double
    let title: String
    let author: String
  }

  struct Session: Decodable, Identifiable, Hashable {
    let id: String
    let libraryItemId: String
    let displayTitle: String
    let displayAuthor: String
    let timeListening: Double
    let startedAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
      case id, libraryItemId, displayTitle, displayAuthor, timeListening, startedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      libraryItemId = c.lenient(String.self, .libraryItemId) ?? ""
      displayTitle = c.lenient(String.self, .displayTitle) ?? ""
      displayAuthor = c.lenient(String.self, .displayAuthor) ?? ""
      timeListening = c.lenient(Double.self, .timeListening) ?? 0
      startedAt = Date(timeIntervalSince1970: (c.lenient(Double.self, .startedAt) ?? 0) / 1000)
      updatedAt = Date(timeIntervalSince1970: (c.lenient(Double.self, .updatedAt) ?? 0) / 1000)
    }
  }

  private struct RawItem: Decodable {
    let id: String?
    let timeListening: Double?
    let mediaMetadata: ABSMetadata?
  }

  let totalTime: Double
  let today: Double
  /// "yyyy-MM-dd" → Sekunden
  let days: [String: Double]
  /// "Monday" … → Sekunden
  let dayOfWeek: [String: Double]
  let items: [Item]
  let recentSessions: [Session]

  enum CodingKeys: String, CodingKey { case totalTime, today, days, dayOfWeek, items, recentSessions }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    totalTime = c.lenient(Double.self, .totalTime) ?? 0
    today = c.lenient(Double.self, .today) ?? 0
    days = c.lenient([String: Double].self, .days) ?? [:]
    dayOfWeek = c.lenient([String: Double].self, .dayOfWeek) ?? [:]
    let raw = c.lenient([String: Lossy<RawItem>].self, .items) ?? [:]
    items = raw.compactMap { key, value in
      guard let v = value.value else { return nil }
      return Item(id: v.id ?? key, timeListening: v.timeListening ?? 0,
                  title: v.mediaMetadata?.title ?? "Unbekannt",
                  author: v.mediaMetadata?.displayAuthor ?? "")
    }
    .sorted { $0.timeListening > $1.timeListening }
    recentSessions = (c.lenient([Lossy<Session>].self, .recentSessions) ?? []).compactMap(\.value)
  }

  // MARK: Auswertungen

  struct DayValue: Identifiable, Hashable {
    let date: Date
    let seconds: Double
    var id: Date { date }
  }

  struct WeekdayValue: Identifiable, Hashable {
    let name: String
    let seconds: Double
    var id: String { name }
  }

  static let dayKey: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  func seconds(on date: Date) -> Double { days[Self.dayKey.string(from: date)] ?? 0 }

  /// Hörzeit der letzten n Tage (inkl. heute), älteste zuerst
  func lastDays(_ n: Int) -> [DayValue] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    return (0 ..< n).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: today).map { DayValue(date: $0, seconds: seconds(on: $0)) }
    }
  }

  /// Hörzeit pro Monat der letzten n Monate
  func lastMonths(_ n: Int) -> [DayValue] {
    let cal = Calendar.current
    let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    var sums: [Date: Double] = [:]
    for (k, v) in days {
      guard let d = Self.dayKey.date(from: k),
            let m = cal.date(from: cal.dateComponents([.year, .month], from: d)) else { continue }
      sums[m, default: 0] += v
    }
    return (0 ..< n).reversed().compactMap { offset in
      cal.date(byAdding: .month, value: -offset, to: start).map { DayValue(date: $0, seconds: sums[$0] ?? 0) }
    }
  }

  var thisWeek: Double { lastDays(7).reduce(0) { $0 + $1.seconds } }

  /// Tage am Stück mit mindestens einer Minute Hörzeit (heute darf noch fehlen)
  var streak: Int {
    let cal = Calendar.current
    var day = cal.startOfDay(for: Date())
    if seconds(on: day) < 60 { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
    var count = 0
    while seconds(on: day) >= 60 {
      count += 1
      guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
      day = prev
    }
    return count
  }

  var activeDays: Int { days.values.filter { $0 >= 60 }.count }

  /// Wochentage Mo–So mit deutschen Kurznamen
  var weekdays: [WeekdayValue] {
    let order = [("Monday", "Mo"), ("Tuesday", "Di"), ("Wednesday", "Mi"), ("Thursday", "Do"),
                 ("Friday", "Fr"), ("Saturday", "Sa"), ("Sunday", "So")]
    return order.map { WeekdayValue(name: $0.1, seconds: dayOfWeek[$0.0] ?? 0) }
  }
}
