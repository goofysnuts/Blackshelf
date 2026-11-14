import SwiftUI

// MARK: - Anfragen-Tab: eigene Hörbuch-Anfragen mit Live-Status

/// Anfragen-Liste (für Admins über „Anfragen“ im Entdecken-Tab erreichbar)
struct RequestsListView: View {
  @State private var requests: [BBRRequest] = []
  @State private var loaded = false
  @State private var error: String?
  @State private var me: BBRMe?

  private var approvals: [BBRRequest] { requests.filter { $0.needsApproval } }
  private var active: [BBRRequest] { requests.filter { $0.isBusy && !$0.needsApproval } }
  private var problems: [BBRRequest] { requests.filter { $0.canRetry } }
  private var done: [BBRRequest] { requests.filter { !$0.isBusy && !$0.canRetry } }

  var body: some View {
    List {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
      if !approvals.isEmpty {
        Section {
          rows(approvals)
        } header: {
          Text("Wartet auf Freigabe")
        } footer: {
          if me?.can("view_all") == true { Text("Nach rechts wischen zum Freigeben oder Ablehnen.") }
        }
      }
      if !active.isEmpty {
        Section("In Arbeit") { rows(active) }
      }
      if !problems.isEmpty {
        Section {
          rows(problems)
        } header: {
          Text("Nicht geklappt")
        } footer: {
          Text("Nach links wischen, um es erneut zu versuchen.")
        }
      }
      if !done.isEmpty {
        Section("Erledigt") { rows(done) }
      }
    }
    .listStyle(.insetGrouped)
    .overlay { emptyState }
    .navigationTitle("Anfragen")
    .refreshable { await load() }
    .task {
      // Status live aktualisieren, solange die Liste sichtbar ist
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(nanoseconds: active.isEmpty ? 15_000_000_000 : 4_000_000_000)
      }
    }
  }

  @ViewBuilder private func rows(_ list: [BBRRequest]) -> some View {
    ForEach(list) { r in
      Group {
        if r.status == "available" {
          NavigationLink(value: Route.findInLibrary(title: r.title, author: r.artist)) {
            RequestRow(request: r, showUsers: me?.can("view_all") ?? false)
          }
        } else {
          RequestRow(request: r, showUsers: me?.can("view_all") ?? false)
        }
      }
      .swipeActions(edge: .leading) {
        if r.needsApproval, me?.can("view_all") == true {
          Button {
            Task {
              try? await BlackboxClient().approve(r.id)
              await load()
            }
          } label: {
            Label("Freigeben", systemImage: "checkmark")
          }
          .tint(.green)
          Button {
            Task {
              try? await BlackboxClient().decline(r.id)
              await load()
            }
          } label: {
            Label("Ablehnen", systemImage: "xmark")
          }
          .tint(.red)
        }
      }
      .contextMenu {
        if r.needsApproval, me?.can("view_all") == true {
          Button {
            Task { try? await BlackboxClient().approve(r.id); await load() }
          } label: { Label("Freigeben", systemImage: "checkmark.circle") }
          Button(role: .destructive) {
            Task { try? await BlackboxClient().decline(r.id); await load() }
          } label: { Label("Ablehnen", systemImage: "xmark.circle") }
        }
      }
      .swipeActions(edge: .trailing) {
        Button(role: .destructive) {
          Task {
            try? await BlackboxClient().delete(r.id)
            await load()
          }
        } label: {
          Label("Entfernen", systemImage: "trash")
        }
        if r.canRetry {
          Button {
            Task {
              try? await BlackboxClient().retry(r.id)
              await load()
            }
          } label: {
            Label("Erneut", systemImage: "arrow.clockwise")
          }
          .tint(.orange)
        }
      }
    }
  }

  @ViewBuilder private var emptyState: some View {
    if !loaded {
      ProgressView()
    } else if requests.isEmpty, error == nil {
      ContentUnavailableView("Keine Anfragen", systemImage: "tray",
                             description: Text("Angefragte Hörbücher erscheinen hier mit ihrem Status."))
    }
  }

  private func load() async {
    guard BlackboxConfig.isConfigured else { loaded = true; return }
    if me == nil { me = try? await BlackboxClient().me() }
    do {
      let r = try await BlackboxClient().requests()
      withAnimation { requests = r.sorted { $0.id > $1.id } }
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
    }
    loaded = true
  }
}

struct RequestRow: View {
  let request: BBRRequest
  var showUsers = false

  var body: some View {
    HStack(spacing: 12) {
      RequestCover(url: request.cover)
        .frame(width: 52, height: 52)
      VStack(alignment: .leading, spacing: 3) {
        Text(request.title).lineLimit(2)
        Text([request.artist, request.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        if request.status == "downloading" {
          ProgressView(value: request.progress ?? 0).tint(.accentColor)
        }
        if showUsers, let users = request.users, !users.isEmpty {
          Label(users.joined(separator: ", "), systemImage: "person")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let m = request.message, !m.isEmpty, !request.isBusy || request.status == "searching" {
          Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 6)
      StatusBadge(status: request.status, progress: request.progress)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

struct StatusBadge: View {
  let status: String
  var progress: Double? = nil

  var body: some View {
    let text = status == "downloading" && (progress ?? 0) > 0
      ? "\(Int(((progress ?? 0) * 100).rounded())) %"
      : BBRState.text(status)
    Label(text, systemImage: BBRState.symbol(status))
      .font(.caption.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .foregroundStyle(BBRState.color(status))
      .symbolEffect(.pulse, isActive: BBRState.busy.contains(status))
  }
}

struct RequestCover: View {
  let url: String?

  var body: some View {
    SquareArtwork(url: url.flatMap(URL.init(string:))) {
      ZStack {
        Rectangle().fill(.quaternary)
        Image(systemName: "book.closed").foregroundStyle(.secondary)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .accessibilityHidden(true)
  }
}

// MARK: - Entdecken-Tab: Empfehlungen & Neuerscheinungen, Suche zum Anfragen

struct DiscoverTabView: View {
  @State private var query = ""
  @State private var books: [BBRBook] = []
  @State private var searching = false
  @State private var error: String?
  @State private var me: BBRMe?
  @State private var pendingApprovals = 0
  @State private var configured = BlackboxConfig.isConfigured
  @State private var showSettings = false
  @AppStorage("discover.mode") private var mode: DiscoverMode = .forYou

  enum DiscoverMode: String, CaseIterable, Identifiable {
    case forYou = "Für dich", categories = "Kategorien"
    var id: Self { self }
  }

  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var isAdmin: Bool { me?.isAdmin == true || me?.can("view_all") == true }

  var body: some View {
    NavigationStack {
      Group {
        if !configured {
          ContentUnavailableView {
            Label("Blackbox Request einrichten", systemImage: "sparkles")
          } description: {
            Text("Verbinde BlackShelf mit Blackbox Request, um neue Hörbücher zu entdecken und anzufragen.")
          } actions: {
            Button("Einrichten") { showSettings = true }
              .buttonStyle(.borderedProminent)
          }
        } else if trimmed.count < 2 {
          Group {
            if mode == .categories {
              AudibleCategoriesGrid()
            } else {
              DiscoverBooksView()
            }
          }
          .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Ansicht", selection: $mode) {
              ForEach(DiscoverMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
          }
        } else {
          resultsList
        }
      }
      .navigationTitle("Entdecken")
      .searchable(text: $query, prompt: "Hörbücher suchen und anfragen")
      .autocorrectionDisabled()
      .toolbar {
        if isAdmin {
          ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: Route.requests) {
              Text(pendingApprovals > 0 ? "Anfragen (\(pendingApprovals))" : "Anfragen")
            }
            .accessibilityHint(pendingApprovals > 0 ? "\(pendingApprovals) warten auf Freigabe" : "")
          }
        }
      }
      .task(id: trimmed) {
        guard trimmed.count >= 2 else { books = []; return }
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
          let r = try await BlackboxClient().search(trimmed)
          guard !Task.isCancelled else { return }
          books = r
          error = nil
        } catch {
          if !Task.isCancelled { self.error = error.localizedDescription }
        }
      }
      .task {
        // Rolle prüfen und offene Freigaben zählen
        while !Task.isCancelled {
          configured = BlackboxConfig.isConfigured
          if configured {
            if me == nil { me = try? await BlackboxClient().me() }
            if isAdmin, let r = try? await BlackboxClient().requests() {
              pendingApprovals = r.filter(\.needsApproval).count
            }
          }
          try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
      }
      .sheet(isPresented: $showSettings, onDismiss: {
        configured = BlackboxConfig.isConfigured
        me = nil
      }) {
        NavigationStack {
          BlackboxSettingsView()
            .toolbar {
              ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showSettings = false } }
            }
        }
      }
      .appDestinations()
    }
  }

  private var resultsList: some View {
    List {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
      ForEach(books) { b in
        NavigationLink(value: Route.requestBook(b.id)) { RequestBookRow(book: b) }
      }
    }
    .listStyle(.plain)
    .overlay {
      if searching, books.isEmpty {
        ProgressView()
      } else if books.isEmpty, error == nil {
        ContentUnavailableView.search(text: trimmed)
      }
    }
  }
}

struct RequestBookRow: View {
  let book: BBRBook

  var body: some View {
    HStack(spacing: 12) {
      RequestCover(url: book.coverSmall ?? book.cover)
        .frame(width: 56, height: 56)
      VStack(alignment: .leading, spacing: 2) {
        Text(book.title).lineLimit(2)
        Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        if let s = book.seriesText {
          Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        BookRequestState(book: book).font(.caption)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct BookRequestState: View {
  let book: BBRBook

  var body: some View {
    if book.inLibrary == true {
      Label("In deiner Bibliothek", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    } else if let r = book.request {
      StatusBadge(status: r.status, progress: r.progress)
    }
  }
}

// MARK: - Detail eines anfragbaren Hörbuchs

struct RequestBookDetailView: View {
  let bookId: String

  @State private var book: BBRBook?
  @State private var error: String?
  @State private var sending = false
  @State private var justRequested = false

  var body: some View {
    List {
      if let book {
        Section {
          VStack(spacing: 10) {
            RequestCover(url: book.cover)
              .frame(width: 220, height: 220)
              .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
              .padding(.bottom, 4)
            Text(book.title).font(.title2.bold()).multilineTextAlignment(.center)
            if let sub = book.subtitle, !sub.isEmpty {
              Text(sub).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(book.author).font(.headline).foregroundStyle(.tint)
            if let n = book.narrator, !n.isEmpty {
              Text("Gelesen von \(n)").font(.subheadline).foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }

        Section {
          action(book)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
          if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
          }
        }

        Section("Informationen") {
          if let s = book.seriesText { LabeledContent("Serie", value: s) }
          if let r = book.runtimeText { LabeledContent("Dauer", value: r) }
          if let y = book.year { LabeledContent("Erschienen", value: String(y)) }
          if book.abridged == true { LabeledContent("Fassung", value: "Gekürzt") }
        }

        if let d = book.description, !d.isEmpty {
          Section("Beschreibung") { Text(d).font(.callout) }
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
    }
    .listStyle(.insetGrouped)
    .overlay { if book == nil, error == nil { ProgressView() } }
    .navigationTitle(book?.title ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task {
      await load()
      // Fortschritt verfolgen, solange die Anfrage läuft
      while !Task.isCancelled, book?.isBusy == true {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await load()
      }
    }
    .sensoryFeedback(.success, trigger: justRequested)
  }

  @ViewBuilder private func action(_ book: BBRBook) -> some View {
    if book.inLibrary == true {
      NavigationLink(value: book.libraryId.map { Route.bookId($0) } ?? Route.findInLibrary(title: book.title, author: book.author)) {
        Label("In der Bibliothek öffnen", systemImage: "books.vertical")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 34)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
    } else if let r = book.request, r.isBusy {
      VStack(alignment: .leading, spacing: 8) {
        StatusBadge(status: r.status, progress: r.progress)
        if r.status == "downloading" { ProgressView(value: r.progress ?? 0).tint(.accentColor) }
        if let m = r.message, !m.isEmpty { Text(m).font(.footnote).foregroundStyle(.secondary) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else {
      VStack(spacing: 8) {
        Button {
          Task { await request() }
        } label: {
          HStack {
            if sending { ProgressView().tint(.white) } else { Image(systemName: "plus") }
            Text(book.request == nil ? "Hörbuch anfragen" : "Erneut anfragen")
          }
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(sending)
        if let r = book.request, let m = r.message, !m.isEmpty {
          Text(m).font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func load() async {
    do {
      book = try await BlackboxClient().book(bookId)
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
    }
  }

  private func request() async {
    sending = true
    do {
      try await BlackboxClient().request(bookId)
      justRequested.toggle()
      error = nil
    } catch {
      self.error = error.localizedDescription
      sending = false
      return
    }
    sending = false
    await load()
    // Fortschritt weiter verfolgen
    while !Task.isCancelled, book?.isBusy == true {
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      await load()
    }
  }
}
