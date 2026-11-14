import SwiftUI

/// Startseite beim Anfragen: persönliche Empfehlungen (Serien, Autoren, Sprecher), Neuerscheinungen, Beliebt
struct DiscoverBooksView: View {
  @State private var sections: [BBRSection] = []
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        ForEach(sections) { section in
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
              Image(systemName: symbol(for: section.id))
                .foregroundStyle(.tint)
              Text(section.title)
                .font(.title3.bold())
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(alignment: .top, spacing: 14) {
                ForEach(section.items) { book in
                  NavigationLink(value: Route.requestBook(book.id)) {
                    DiscoverBookCard(book: book, showDate: section.id == "new")
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
      .padding(.vertical)
    }
    .overlay {
      if sections.isEmpty {
        if loading {
          VStack(spacing: 12) {
            ProgressView()
            Text("Suche Neuerscheinungen und Empfehlungen …")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else if let error {
          ContentUnavailableView {
            Label("Nicht verfügbar", systemImage: "wifi.exclamationmark")
          } description: {
            Text(error)
          } actions: {
            Button("Erneut versuchen") { Task { await load(refresh: false) } }
          }
        } else {
          ContentUnavailableView("Hörbuch anfragen", systemImage: "text.book.closed",
                                 description: Text("Suche nach Titel, Autor oder Reihe."))
        }
      }
    }
    .refreshable { await load(refresh: true) }
    .task { if sections.isEmpty { await load(refresh: false) } }
  }

  private func load(refresh: Bool) async {
    loading = true
    defer { loading = false }
    do {
      sections = try await BlackboxClient().discover(refresh: refresh)
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
    }
  }

  private func symbol(for id: String) -> String {
    switch id {
    case "series": return "books.vertical.fill"
    case "authors": return "person.fill"
    case "new": return "sparkles"
    case "popular": return "flame.fill"
    default: return id.hasPrefix("narrator") ? "mic.fill" : "star.fill"
    }
  }
}

struct DiscoverBookCard: View {
  let book: BBRBook
  var showDate = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RequestCover(url: book.coverSmall ?? book.cover)
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
          if let r = book.request {
            StatusBadge(status: r.status, progress: r.progress)
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.ultraThinMaterial, in: Capsule())
              .padding(6)
          }
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
      VStack(alignment: .leading, spacing: 1) {
        Text(book.title)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
        Text(book.seriesText ?? book.author)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if showDate, let d = book.releasedDate {
          Text(d, format: .dateTime.day().month(.abbreviated))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: 140, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}
