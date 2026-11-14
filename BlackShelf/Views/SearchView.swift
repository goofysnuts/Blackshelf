import SwiftUI

/// Suche in der eigenen Bibliothek – und darunter Hörbücher, die man per Blackbox Request anfragen kann
struct SearchView: View {
  @Environment(AppModel.self) private var app
  @State private var query = ""
  @State private var result: ABSSearchResult = .empty
  @State private var missing: [BBRBook] = []
  @State private var searching = false
  @State private var requestError: String?

  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var hasResults: Bool { !result.books.isEmpty || !result.series.isEmpty || !result.authors.isEmpty || !missing.isEmpty }

  var body: some View {
    NavigationStack {
      List {
        if !result.books.isEmpty {
          Section("Hörbücher") {
            ForEach(result.books) { b in
              NavigationLink(value: Route.book(b)) { BookRow(item: b) }
            }
          }
        }
        if !result.series.isEmpty {
          Section("Serien") {
            ForEach(result.series) { s in
              NavigationLink(value: Route.series(id: s.id, name: s.name)) {
                Label {
                  Text(s.name)
                } icon: {
                  BookCover(itemId: s.books.first?.id, cornerRadius: 4, width: 120).frame(width: 32)
                }
              }
            }
          }
        }
        if !result.authors.isEmpty {
          Section("Autoren") {
            ForEach(result.authors) { a in
              NavigationLink(value: Route.author(id: a.id, name: a.name)) {
                HStack(spacing: 12) {
                  AuthorImage(author: a).frame(width: 36, height: 36)
                  Text(a.name)
                }
              }
            }
          }
        }
        if BlackboxConfig.isConfigured, trimmed.count >= 2 {
          Section {
            if !missing.isEmpty {
              ForEach(missing) { b in
                NavigationLink(value: Route.requestBook(b.id)) { RequestBookRow(book: b) }
              }
            } else if let requestError {
              Label(requestError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if !searching {
              Text("Keine weiteren Hörbücher gefunden.").foregroundStyle(.secondary)
            }
          } header: {
            Text("Nicht in deiner Bibliothek")
          } footer: {
            Text("Über Blackbox Request anfragen – das Buch wird automatisch in Audiobookshelf einsortiert.")
          }
        }
      }
      .listStyle(.insetGrouped)
      .overlay {
        if trimmed.count < 2 {
          ContentUnavailableView("Hörbücher suchen", systemImage: "magnifyingglass",
                                 description: Text("Titel, Autor, Sprecher oder Serie"))
        } else if searching, !hasResults {
          ProgressView()
        } else if !hasResults, !BlackboxConfig.isConfigured {
          ContentUnavailableView.search(text: trimmed)
        }
      }
      .navigationTitle("Suche")
      .searchable(text: $query, prompt: "Titel, Autor oder Serie")
      .autocorrectionDisabled()
      .task(id: trimmed) { await search() }
      .appDestinations()
    }
  }

  private func search() async {
    let q = trimmed
    guard q.count >= 2, let lib = app.libraryId else {
      result = .empty
      missing = []
      return
    }
    try? await Task.sleep(nanoseconds: 350_000_000) // Tipp-Pause abwarten
    guard !Task.isCancelled else { return }
    searching = true
    defer { searching = false }

    async let local = try? ABSClient.shared.search(lib, q)
    async let remote = fetchRequestable(q)

    let l = await local
    guard !Task.isCancelled else { return }
    result = l ?? .empty

    let remoteResult = await remote
    switch remoteResult {
    case let .success(books):
      missing = books.filter { $0.inLibrary != true }
      requestError = nil
    case let .failure(error):
      missing = []
      requestError = error.localizedDescription
    }
  }

  private func fetchRequestable(_ q: String) async -> Result<[BBRBook], Error> {
    guard BlackboxConfig.isConfigured else { return .success([]) }
    do { return .success(try await BlackboxClient().search(q)) } catch { return .failure(error) }
  }
}
