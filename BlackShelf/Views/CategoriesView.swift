import SwiftUI

// MARK: - Kategorien-Tab: eigene Bücher nach Genre

struct CategoriesView: View {
  @Environment(AppModel.self) private var app
  @State private var genres: [BlackboxClient.LibraryGenre] = []
  @State private var loading = false
  @State private var error: String?

  private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(genres) { g in
            NavigationLink(value: Route.genre(g.name)) {
              GenreTile(name: g.name, subtitle: g.count > 0 ? (g.count == 1 ? "1 Hörbuch" : "\(g.count) Hörbücher") : nil,
                        imageURL: BlackboxConfig.isConfigured ? BlackboxClient().genreCoverURL(name: g.name) : nil)
            }
            .buttonStyle(.plain)
          }
        }
        .padding()
      }
      .overlay {
        if genres.isEmpty {
          if loading {
            ProgressView()
          } else if let error {
            ContentUnavailableView("Keine Kategorien", systemImage: "exclamationmark.triangle", description: Text(error))
          } else {
            ContentUnavailableView("Keine Kategorien", systemImage: "square.grid.2x2",
                                   description: Text("Deine Hörbücher haben in Audiobookshelf noch keine Genres."))
          }
        }
      }
      .navigationTitle("Kategorien")
      .refreshable { await load() }
      .task(id: app.libraryId) { await load() }
      .appDestinations()
    }
  }

  private func load() async {
    guard let lib = app.libraryId else { return }
    loading = true
    defer { loading = false }
    // mit Blackbox Request inkl. Anzahl, sonst direkt aus Audiobookshelf
    if BlackboxConfig.isConfigured, let g = try? await BlackboxClient().libraryGenres(), !g.isEmpty {
      genres = g
      error = nil
      return
    }
    do {
      genres = try await ABSClient.shared.genres(lib).map { BlackboxClient.LibraryGenre(name: $0, count: 0) }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Kategorie-Kachel: Bild vom Server (gefächerte Cover wie bei Blackbox), sonst Farbverlauf mit Namen
struct GenreTile: View {
  let name: String
  var subtitle: String? = nil
  let imageURL: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SquareArtwork(url: imageURL) {
        FallbackGenreArt(name: name)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(name + (subtitle.map { ", \($0)" } ?? ""))
    .accessibilityAddTraits(.isButton)
  }
}

struct FallbackGenreArt: View {
  let name: String

  private var color: Color {
    let hash = name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
    return Color(hue: Double(abs(hash) % 360) / 360, saturation: 0.6, brightness: 0.62)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom)
      Text(name)
        .font(.title3.weight(.heavy))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        .padding(12)
    }
  }
}

/// Alle eigenen Bücher eines Genres
struct GenreBooksView: View {
  let genre: String
  @Environment(AppModel.self) private var app
  @AppStorage("library.layout") private var layout: LibraryLayout = .grid
  @State private var items: [ABSItem] = []
  @State private var total = 0
  @State private var page = 0
  @State private var loading = false

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

  var body: some View {
    content
      .overlay {
        if items.isEmpty {
          if loading { ProgressView() } else {
            ContentUnavailableView("Keine Hörbücher", systemImage: "books.vertical")
          }
        }
      }
      .navigationTitle(genre)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            withAnimation { layout = layout == .grid ? .list : .grid }
          } label: {
            Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
          }
          .accessibilityLabel(layout == .grid ? "Als Liste anzeigen" : "Als Kacheln anzeigen")
        }
      }
      .refreshable { await load(more: false) }
      .task { if items.isEmpty { await load(more: false) } }
  }

  @ViewBuilder private var content: some View {
    if layout == .grid {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(items) { item in
            NavigationLink(value: Route.book(item)) { BookTile(item: item) }
              .buttonStyle(.plain)
              .onAppear { if item.id == items.last?.id { Task { await load(more: true) } } }
          }
        }
        .padding()
      }
    } else {
      List(items) { item in
        NavigationLink(value: Route.book(item)) { BookRow(item: item) }
          .onAppear { if item.id == items.last?.id { Task { await load(more: true) } } }
      }
      .listStyle(.plain)
    }
  }

  private func load(more: Bool) async {
    guard let lib = app.libraryId, !loading else { return }
    if more { guard items.count < total else { return }; page += 1 } else { page = 0 }
    loading = true
    defer { loading = false }
    guard let r = try? await ABSClient.shared.items(lib, sort: "media.metadata.title", desc: false, page: page,
                                                    filter: ABSClient.genreFilter(genre)) else { return }
    items = more ? items + r.results : r.results
    total = r.total ?? items.count
  }
}

// MARK: - Entdecken → Kategorien (Audible)

struct AudibleCategoriesGrid: View {
  @State private var categories: [BlackboxClient.Category] = []
  @State private var loading = false
  @State private var error: String?

  private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 14) {
        ForEach(categories) { c in
          NavigationLink(value: Route.audibleCategory(id: c.id, name: c.name)) {
            GenreTile(name: c.name, imageURL: BlackboxClient().genreCoverURL(name: c.name, category: c.id))
          }
          .buttonStyle(.plain)
        }
      }
      .padding()
    }
    .overlay {
      if categories.isEmpty {
        if loading {
          ProgressView()
        } else if let error {
          ContentUnavailableView {
            Label("Nicht verfügbar", systemImage: "wifi.exclamationmark")
          } description: {
            Text(error)
          } actions: {
            Button("Erneut versuchen") { Task { await load() } }
          }
        }
      }
    }
    .refreshable { await load() }
    .task { if categories.isEmpty { await load() } }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    do {
      categories = try await BlackboxClient().categories()
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
    }
  }
}

/// Bestseller und Neuerscheinungen einer Audible-Kategorie
struct AudibleCategoryView: View {
  let categoryId: String
  let name: String
  @State private var sections: [BBRSection] = []
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        ForEach(sections) { section in
          VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
              .font(.title3.bold())
              .padding(.horizontal)
              .accessibilityAddTraits(.isHeader)
            RecommendationRow(books: section.items)
          }
        }
      }
      .padding(.vertical)
    }
    .overlay {
      if sections.isEmpty {
        if loading {
          ProgressView()
        } else if let error {
          ContentUnavailableView("Nicht verfügbar", systemImage: "wifi.exclamationmark", description: Text(error))
        } else {
          ContentUnavailableView("Keine Hörbücher", systemImage: "books.vertical")
        }
      }
    }
    .navigationTitle(name)
    .refreshable { await load() }
    .task { if sections.isEmpty { await load() } }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    do {
      sections = try await BlackboxClient().category(categoryId)
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
    }
  }
}
