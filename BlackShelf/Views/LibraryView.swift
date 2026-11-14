import SwiftUI

enum LibraryLayout: String {
  case grid, list
}

struct LibraryView: View {
  @Environment(AppModel.self) private var app
  @AppStorage("library.layout") private var layout: LibraryLayout = .grid

  enum Pane: String, CaseIterable, Identifiable {
    case books = "Titel", series = "Serien", authors = "Autoren", collections = "Sammlungen"
    var id: Self { self }
  }

  @AppStorage("library.section") private var section: Pane = .books

  var body: some View {
    NavigationStack {
      Group {
        switch section {
        case .books: BooksGrid()
        case .series: SeriesGrid()
        case .authors: AuthorsList()
        case .collections: CollectionsList()
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        Picker("Ansicht", selection: $section) {
          ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
      }
      .navigationTitle("Bibliothek")
      .toolbar {
        if app.bookLibraries.count > 1 {
          ToolbarItem(placement: .topBarLeading) { LibraryMenu() }
        }
        if section != .authors {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              withAnimation { layout = layout == .grid ? .list : .grid }
            } label: {
              Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
            }
            .accessibilityLabel(layout == .grid ? "Als Liste anzeigen" : "Als Kacheln anzeigen")
          }
        }
      }
      .appDestinations()
    }
  }
}

// MARK: - Titel

struct BooksGrid: View {
  @Environment(AppModel.self) private var app

  enum Sort: String, CaseIterable, Identifiable {
    case title = "Titel", author = "Autor", added = "Hinzugefügt", duration = "Dauer", published = "Erscheinungsjahr"
    var id: Self { self }
    var key: String {
      switch self {
      case .title: return "media.metadata.title"
      case .author: return "media.metadata.authorName"
      case .added: return "addedAt"
      case .duration: return "media.duration"
      case .published: return "media.metadata.publishedYear"
      }
    }
  }

  enum Filter: String, CaseIterable, Identifiable {
    case all = "Alle", inProgress = "Begonnen", notStarted = "Nicht begonnen", finished = "Beendet"
    var id: Self { self }
    var symbol: String {
      switch self {
      case .all: return "books.vertical"
      case .inProgress: return "play.circle"
      case .notStarted: return "circle"
      case .finished: return "checkmark.circle"
      }
    }
    var query: String? {
      let v: String
      switch self {
      case .all: return nil
      case .inProgress: v = "in-progress"
      case .notStarted: v = "not-started"
      case .finished: v = "finished"
      }
      let b64 = Data(v.utf8).base64EncodedString()
      return ("progress." + b64).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }
  }

  @AppStorage("library.sort") private var sort: Sort = .title
  @AppStorage("library.desc") private var descending = false
  @AppStorage("library.filter") private var filter: Filter = .all
  @AppStorage("library.layout") private var layout: LibraryLayout = .grid

  @State private var items: [ABSItem] = []
  @State private var total = 0
  @State private var page = 0
  @State private var loading = false
  @State private var error: String?

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

  @ViewBuilder private var content: some View {
    if layout == .grid {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(items) { item in
            NavigationLink(value: Route.book(item)) {
              BookTile(item: item)
            }
            .buttonStyle(.plain)
            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
          }
        }
        .padding()
        if loading, !items.isEmpty { ProgressView().padding() }
      }
    } else {
      List {
        ForEach(items) { item in
          NavigationLink(value: Route.book(item)) {
            BookRow(item: item)
          }
          .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
        }
        if loading, !items.isEmpty {
          ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
    }
  }

  var body: some View {
    content
    .overlay {
      if items.isEmpty {
        if loading { ProgressView() }
        else if let error { ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle", description: Text(error)) }
        else { ContentUnavailableView("Keine Hörbücher", systemImage: "books.vertical",
                                      description: Text(filter == .all ? "Diese Bibliothek ist leer." : "Kein Buch passt zum Filter „\(filter.rawValue)“.")) }
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Sortieren nach", selection: $sort) {
            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
          }
          Picker("Reihenfolge", selection: $descending) {
            Label("Aufsteigend", systemImage: "arrow.up").tag(false)
            Label("Absteigend", systemImage: "arrow.down").tag(true)
          }
          Section("Anzeigen") {
            Picker("Filter", selection: $filter) {
              ForEach(Filter.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
          }
        } label: {
          Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Sortieren und filtern")
      }
    }
    .refreshable { await reload() }
    .task(id: "\(app.libraryId ?? "")|\(sort.rawValue)|\(descending)|\(filter.rawValue)") { await reload() }
  }

  private func reload() async {
    page = 0
    await fetch(replace: true)
  }

  private func loadMore() async {
    guard !loading, items.count < total else { return }
    page += 1
    await fetch(replace: false)
  }

  private func fetch(replace: Bool) async {
    guard let lib = app.libraryId else { return }
    loading = true
    defer { loading = false }
    do {
      let r = try await ABSClient.shared.items(lib, sort: sort.key, desc: descending, page: page, filter: filter.query)
      items = replace ? r.results : items + r.results
      total = r.total ?? items.count
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code == .cancelled { return }
      self.error = error.localizedDescription
    }
  }
}

// MARK: - Serien

struct SeriesGrid: View {
  @Environment(AppModel.self) private var app
  @AppStorage("library.layout") private var layout: LibraryLayout = .grid
  @State private var series: [ABSSeries] = []
  @State private var total = 0
  @State private var page = 0
  @State private var loading = false

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

  @ViewBuilder private var content: some View {
    if layout == .grid {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(series) { s in
            NavigationLink(value: Route.series(id: s.id, name: s.name)) {
              SeriesTile(series: s)
            }
            .buttonStyle(.plain)
            .onAppear { if s.id == series.last?.id { Task { await load(more: true) } } }
          }
        }
        .padding()
      }
    } else {
      List(series) { s in
        NavigationLink(value: Route.series(id: s.id, name: s.name)) {
          HStack(spacing: 12) {
            BookCover(item: s.books.first, cornerRadius: 6, width: 160)
              .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
              Text(s.name).lineLimit(2)
              Text(s.books.count == 1 ? "1 Buch" : "\(s.books.count) Bücher")
                .font(.caption).foregroundStyle(.secondary)
              if let author = s.books.first?.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
          }
        }
        .onAppear { if s.id == series.last?.id { Task { await load(more: true) } } }
      }
      .listStyle(.plain)
    }
  }

  var body: some View {
    content
    .overlay {
      if series.isEmpty {
        if loading { ProgressView() } else {
          ContentUnavailableView("Keine Serien", systemImage: "square.stack")
        }
      }
    }
    .refreshable { await load(more: false) }
    .task(id: app.libraryId) { await load(more: false) }
  }

  private func load(more: Bool) async {
    guard let lib = app.libraryId, !loading else { return }
    if more { guard series.count < total else { return }; page += 1 } else { page = 0 }
    loading = true
    defer { loading = false }
    guard let r = try? await ABSClient.shared.series(lib, page: page) else { return }
    series = more ? series + r.results : r.results
    total = r.total ?? series.count
  }
}

struct SeriesView: View {
  let seriesId: String
  let name: String
  @Environment(AppModel.self) private var app
  @State private var books: [ABSItem] = []
  @State private var loaded = false

  var body: some View {
    List {
      ForEach(books) { b in
        NavigationLink(value: Route.book(b)) {
          HStack(spacing: 12) {
            Text(sequence(of: b) ?? "–")
              .font(.headline.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(minWidth: 28)
              .accessibilityLabel("Band \(sequence(of: b) ?? "")")
            BookRow(item: b)
          }
        }
      }
    }
    .listStyle(.plain)
    .overlay { if !loaded { ProgressView() } }
    .navigationTitle(name)
    .toolbar {
      if let next = nextUp {
        ToolbarItem(placement: .topBarTrailing) {
          PlayButtonSmall(item: next, label: "Nächsten Band hören")
        }
      }
    }
    .task {
      guard let lib = app.libraryId else { return }
      books = (try? await ABSClient.shared.seriesBooks(lib, seriesId: seriesId)) ?? []
      loaded = true
    }
  }

  private func sequence(of b: ABSItem) -> String? {
    b.media.metadata.series?.first(where: { $0.id == seriesId })?.sequence ?? b.sequence
  }

  /// Erster nicht beendeter Band
  private var nextUp: ABSItem? {
    books.first { !(app.progress(for: $0.id)?.isFinished ?? false) }
  }
}

struct PlayButtonSmall: View {
  let item: ABSItem
  let label: String
  @Environment(PlayerEngine.self) private var player

  var body: some View {
    Button {
      Task { await player.play(item) }
    } label: {
      Label(label, systemImage: "play.fill")
    }
  }
}

// MARK: - Autoren

struct AuthorsList: View {
  @Environment(AppModel.self) private var app
  @State private var authors: [ABSAuthor] = []
  @State private var loading = false

  var body: some View {
    List(authors) { a in
      NavigationLink(value: Route.author(id: a.id, name: a.name)) {
        HStack(spacing: 12) {
          AuthorImage(author: a).frame(width: 44, height: 44)
          VStack(alignment: .leading) {
            Text(a.name)
            if let n = a.numBooks {
              Text(n == 1 ? "1 Buch" : "\(n) Bücher").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      if authors.isEmpty {
        if loading { ProgressView() } else { ContentUnavailableView("Keine Autoren", systemImage: "person.2") }
      }
    }
    .refreshable { await load() }
    .task(id: app.libraryId) { await load() }
  }

  private func load() async {
    guard let lib = app.libraryId else { return }
    loading = true
    defer { loading = false }
    authors = (try? await ABSClient.shared.authors(lib)) ?? authors
  }
}

struct AuthorView: View {
  let authorId: String
  let name: String
  @State private var author: ABSAuthor?
  @State private var showFullBio = false

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        if let author {
          AuthorImage(author: author)
            .frame(width: 140, height: 140)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
          if let d = author.description, !d.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text(d)
                .font(.callout)
                .lineLimit(showFullBio ? nil : 4)
              Button(showFullBio ? "Weniger" : "Mehr") { withAnimation { showFullBio.toggle() } }
                .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
          }
          LazyVGrid(columns: columns, spacing: 18) {
            ForEach(author.libraryItems ?? []) { item in
              NavigationLink(value: Route.book(item)) { BookTile(item: item) }
                .buttonStyle(.plain)
            }
          }
          .padding(.horizontal)
        } else {
          ProgressView().padding(.top, 80)
        }
      }
      .padding(.vertical)
    }
    .navigationTitle(name)
    .task { author = try? await ABSClient.shared.author(authorId) }
  }
}

// MARK: - Sammlungen

struct CollectionsList: View {
  @Environment(AppModel.self) private var app
  @AppStorage("library.layout") private var layout: LibraryLayout = .grid
  @State private var collections: [ABSCollection] = []
  @State private var loading = false

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

  var body: some View {
    content
    .overlay {
      if collections.isEmpty {
        if loading { ProgressView() } else {
          ContentUnavailableView("Keine Sammlungen", systemImage: "rectangle.stack",
                                 description: Text("Sammlungen legst du in Audiobookshelf an."))
        }
      }
    }
    .refreshable { await load() }
    .task(id: app.libraryId) { await load() }
  }

  @ViewBuilder private var content: some View {
    if layout == .grid {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(collections) { c in
            NavigationLink(value: Route.collection(c)) {
              CollectionTile(collection: c)
            }
            .buttonStyle(.plain)
          }
        }
        .padding()
      }
    } else {
      list
    }
  }

  private var list: some View {
    List(collections) { c in
      NavigationLink(value: Route.collection(c)) {
        HStack(spacing: 12) {
          BookCover(item: c.books.first, cornerRadius: 6, width: 160).frame(width: 56)
          VStack(alignment: .leading, spacing: 2) {
            Text(c.name)
            Text(c.books.count == 1 ? "1 Buch" : "\(c.books.count) Bücher")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
    .listStyle(.plain)
  }

  private func load() async {
    guard let lib = app.libraryId else { return }
    loading = true
    defer { loading = false }
    collections = (try? await ABSClient.shared.collections(lib)) ?? collections
  }
}

/// Kachel einer Sammlung: Collage aus bis zu vier Covern
struct CollectionTile: View {
  let collection: ABSCollection

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if collection.books.count >= 4 {
          Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
              BookCover(item: collection.books[0], cornerRadius: 0, width: 200)
              BookCover(item: collection.books[1], cornerRadius: 0, width: 200)
            }
            GridRow {
              BookCover(item: collection.books[2], cornerRadius: 0, width: 200)
              BookCover(item: collection.books[3], cornerRadius: 0, width: 200)
            }
          }
          .aspectRatio(1, contentMode: .fit)
        } else {
          BookCover(item: collection.books.first, cornerRadius: 0, width: 300)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(collection.name)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
        Text(collection.books.count == 1 ? "1 Buch" : "\(collection.books.count) Bücher")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct CollectionView: View {
  let collection: ABSCollection

  var body: some View {
    List {
      if let d = collection.description, !d.isEmpty {
        Text(d).font(.callout).foregroundStyle(.secondary)
      }
      ForEach(collection.books) { b in
        NavigationLink(value: Route.book(b)) { BookRow(item: b) }
      }
    }
    .listStyle(.plain)
    .navigationTitle(collection.name)
  }
}

// MARK: - Angefragtes Buch in der Bibliothek finden

struct FindInLibraryView: View {
  let title: String
  let author: String
  @Environment(AppModel.self) private var app
  @State private var match: ABSItem?
  @State private var done = false

  var body: some View {
    Group {
      if let match {
        BookDetailView(item: match)
      } else if done {
        ContentUnavailableView("Noch nicht in der Bibliothek", systemImage: "hourglass",
                               description: Text("Audiobookshelf hat „\(title)“ noch nicht eingelesen. Versuche es gleich noch einmal."))
      } else {
        ProgressView()
      }
    }
    .task {
      guard let lib = app.libraryId else { done = true; return }
      let r = try? await ABSClient.shared.search(lib, title)
      let books = r?.books ?? []
      let a = author.lowercased()
      match = books.first { $0.author.lowercased().contains(a) || a.contains($0.author.lowercased()) } ?? books.first
      done = true
    }
  }
}
