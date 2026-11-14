import SwiftUI

struct HomeView: View {
  @Environment(AppModel.self) private var app
  @Environment(PlayerEngine.self) private var player
  @State private var shelves: [ABSShelf] = []
  @State private var loading = false
  @State private var error: String?
  @State private var showSettings = false

  private var continueShelf: ABSShelf? { shelves.first { $0.id == "continue-listening" } }
  private var otherShelves: [ABSShelf] {
    shelves.filter { $0.id != "continue-listening" && (!$0.items.isEmpty || !$0.series.isEmpty || !$0.authors.isEmpty) }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 28) {
          if let c = continueShelf, !c.items.isEmpty {
            ContinueListeningSection(items: c.items)
          }
          ForEach(otherShelves) { shelf in
            ShelfSection(shelf: shelf)
          }
        }
        .padding(.vertical)
      }
      .overlay {
        if shelves.isEmpty {
          if loading {
            ProgressView()
          } else if let error {
            ContentUnavailableView {
              Label("Keine Verbindung", systemImage: "wifi.exclamationmark")
            } description: {
              Text(error)
            } actions: {
              Button("Erneut versuchen") { Task { await load() } }
            }
          } else {
            ContentUnavailableView("Noch nichts zu hören", systemImage: "books.vertical",
                                   description: Text("Füge Hörbücher in Audiobookshelf hinzu oder frage welche unter „Anfragen“ an."))
          }
        }
      }
      .navigationTitle(app.library?.name ?? "Start")
      .toolbar {
        if app.bookLibraries.count > 1 {
          ToolbarItem(placement: .topBarLeading) { LibraryMenu() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button { showSettings = true } label: {
            Image(systemName: "person.crop.circle")
          }
          .accessibilityLabel("Einstellungen")
        }
      }
      .refreshable {
        await app.refreshProgress()
        await load()
      }
      .task(id: app.libraryId) { await load() }
      .onChange(of: player.isPlaying) { _, playing in
        // nach dem Pausieren „Weiterhören“ aktualisieren
        if !playing { Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await load() } }
      }
      .sheet(isPresented: $showSettings) { SettingsView() }
      .appDestinations()
    }
  }

  private func load() async {
    guard let lib = app.libraryId else { return }
    loading = true
    defer { loading = false }
    do {
      shelves = try await ABSClient.shared.personalized(lib)
      error = nil
    } catch {
      if shelves.isEmpty { self.error = error.localizedDescription }
    }
  }
}

struct LibraryMenu: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    Menu {
      Picker("Bibliothek", selection: $app.libraryId) {
        ForEach(app.bookLibraries) { Label($0.name, systemImage: "books.vertical").tag(Optional($0.id)) }
      }
    } label: {
      Image(systemName: "books.vertical.circle")
    }
    .accessibilityLabel("Bibliothek wählen")
  }
}

// MARK: - Weiterhören (große Karten)

struct ContinueListeningSection: View {
  let items: [ABSItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Weiterhören")
        .font(.title2.bold())
        .padding(.horizontal)
        .accessibilityAddTraits(.isHeader)
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 14) {
          ForEach(items) { item in
            ContinueCard(item: item)
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal)
      }
      .scrollTargetBehavior(.viewAligned)
    }
  }
}

struct ContinueCard: View {
  let item: ABSItem
  @Environment(AppModel.self) private var app
  @Environment(PlayerEngine.self) private var player

  private var isCurrent: Bool { player.item?.id == item.id }

  var body: some View {
    let p = app.progress(for: item.id)
    let remaining = max(0, (p?.duration ?? item.duration) - (p?.currentTime ?? 0))
    NavigationLink(value: Route.book(item)) {
      VStack(alignment: .leading, spacing: 8) {
        BookCover(itemId: item.id, cornerRadius: 12, progress: p?.progress, width: 500)
          .frame(width: 220)
          .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(1)
            Text("Noch \(Fmt.duration(remaining))").font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          Button {
            if isCurrent { player.togglePlayPause() } else { Task { await player.play(item) } }
          } label: {
            Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
              .font(.system(size: 34))
              .symbolRenderingMode(.hierarchical)
              .contentTransition(.symbolEffect(.replace))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
          .frame(minWidth: 44, minHeight: 44)
          .accessibilityLabel(isCurrent && player.isPlaying ? "Pause" : "Weiterhören")
        }
        .frame(width: 220)
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Weitere Regale

struct ShelfSection: View {
  let shelf: ABSShelf

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(shelf.germanLabel)
        .font(.title3.bold())
        .padding(.horizontal)
        .accessibilityAddTraits(.isHeader)
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 12) {
          ForEach(shelf.items) { item in
            NavigationLink(value: Route.book(item)) {
              BookTile(item: item).frame(width: 140)
            }
            .buttonStyle(.plain)
          }
          ForEach(shelf.series) { s in
            NavigationLink(value: Route.series(id: s.id, name: s.name)) {
              SeriesTile(series: s).frame(width: 140)
            }
            .buttonStyle(.plain)
          }
          ForEach(shelf.authors) { a in
            NavigationLink(value: Route.author(id: a.id, name: a.name)) {
              AuthorTile(author: a)
            }
            .buttonStyle(.plain)
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal)
      }
      .scrollTargetBehavior(.viewAligned)
    }
  }
}

struct SeriesTile: View {
  let series: ABSSeries

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack {
        // gestapelte Cover deuten die Reihe an
        if series.books.count > 1 {
          BookCover(itemId: series.books[1].id, width: 300)
            .scaleEffect(0.9)
            .offset(x: 8, y: -8)
            .opacity(0.6)
        }
        BookCover(itemId: series.books.first?.id, width: 300)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(series.name).font(.subheadline.weight(.medium)).lineLimit(2)
        Text(series.books.count == 1 ? "1 Buch" : "\(series.books.count) Bücher")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct AuthorTile: View {
  let author: ABSAuthor

  var body: some View {
    VStack(spacing: 6) {
      AuthorImage(author: author)
        .frame(width: 110, height: 110)
      Text(author.name)
        .font(.subheadline.weight(.medium))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(width: 120)
    }
    .accessibilityElement(children: .combine)
  }
}

struct AuthorImage: View {
  let author: ABSAuthor

  var body: some View {
    RemoteImage(url: author.imagePath == nil ? nil : ABSClient.shared.authorImageURL(author.id)) {
      ZStack {
        Circle().fill(.quaternary)
        Text(initials).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
      }
    }
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private var initials: String {
    author.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
  }
}
