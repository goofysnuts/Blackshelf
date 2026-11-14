import SwiftUI

struct BookDetailView: View {
  let item: ABSItem
  @Environment(AppModel.self) private var app
  @Environment(PlayerEngine.self) private var player
  @State private var full: ABSItem?
  @State private var showFullDescription = false
  @State private var confirmReset = false

  private var book: ABSItem { full ?? item }
  private var meta: ABSMetadata { book.media.metadata }
  private var progress: ABSProgress? { app.progress(for: item.id) }
  private var isCurrent: Bool { player.item?.id == item.id }
  private var isFinished: Bool { progress?.isFinished ?? false }

  private var position: Double {
    isCurrent ? player.currentTime : (progress?.currentTime ?? 0)
  }

  private var playTitle: String {
    if isCurrent, player.isPlaying { return "Pause" }
    if isFinished { return "Erneut hören" }
    return position > 5 ? "Fortsetzen" : "Abspielen"
  }

  var body: some View {
    List {
      header
      Section {
        playButton
          .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }

      if let d = meta.description, !d.isEmpty {
        Section("Beschreibung") {
          VStack(alignment: .leading, spacing: 6) {
            Text(cleanDescription(d))
              .font(.callout)
              .lineLimit(showFullDescription ? nil : 5)
            Button(showFullDescription ? "Weniger" : "Mehr") {
              withAnimation { showFullDescription.toggle() }
            }
            .font(.callout.weight(.semibold))
            .buttonStyle(.borderless)
          }
        }
      }

      detailsSection

      if let chapters = book.media.chapters, chapters.count > 1 {
        Section("Kapitel (\(chapters.count))") {
          ForEach(chapters) { c in
            Button {
              Task { await player.play(book, from: c.start) }
            } label: {
              ChapterRow(chapter: c, isCurrent: isCurrent && player.currentChapter?.id == c.id,
                         isDone: position >= c.end - 1 && !isFinished)
            }
            .foregroundStyle(.primary)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(meta.title ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            Task { await app.setFinished(item.id, !isFinished) }
          } label: {
            Label(isFinished ? "Als nicht beendet markieren" : "Als beendet markieren",
                  systemImage: isFinished ? "circle" : "checkmark.circle")
          }
          if (progress?.currentTime ?? 0) > 0 || isFinished {
            Button(role: .destructive) { confirmReset = true } label: {
              Label("Fortschritt zurücksetzen", systemImage: "arrow.counterclockwise")
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Weitere Aktionen")
      }
    }
    .confirmationDialog("Fortschritt zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
      Button("Zurücksetzen", role: .destructive) { Task { await app.resetProgress(item.id) } }
    } message: {
      Text("Das Hörbuch beginnt dann wieder am Anfang.")
    }
    .task { full = try? await ABSClient.shared.item(item.id) }
  }

  // MARK: Kopfbereich

  private var header: some View {
    Section {
      VStack(spacing: 10) {
        BookCover(itemId: item.id, cornerRadius: 14, width: 800)
          .frame(maxWidth: 260)
          .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
          .padding(.bottom, 6)
        Text(meta.title ?? "")
          .font(.title2.bold())
          .multilineTextAlignment(.center)
        if let sub = meta.subtitle, !sub.isEmpty {
          Text(sub).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        authorLink
        if let n = meta.displayNarrator {
          Text("Gelesen von \(n)").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        progressLine
      }
      .frame(maxWidth: .infinity)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }

  @ViewBuilder private var authorLink: some View {
    if let a = meta.authors?.first {
      NavigationLink(value: Route.author(id: a.id, name: a.name)) {
        Text(meta.displayAuthor).font(.headline).foregroundStyle(.tint)
      }
      .buttonStyle(.plain)
    } else {
      Text(meta.displayAuthor).font(.headline).foregroundStyle(.tint)
    }
  }

  @ViewBuilder private var progressLine: some View {
    let dur = book.duration
    if isFinished {
      Label("Beendet", systemImage: "checkmark.circle.fill")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.green)
    } else if position > 5, dur > 0 {
      VStack(spacing: 4) {
        ProgressView(value: min(position / dur, 1)).tint(.accentColor).frame(maxWidth: 220)
        Text("Noch \(Fmt.duration(dur - position))")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .padding(.top, 4)
    } else if dur > 0 {
      Text(Fmt.duration(dur)).font(.footnote).foregroundStyle(.secondary)
    }
  }

  private var playButton: some View {
    Button {
      if isCurrent, player.isPlaying {
        player.pause()
      } else if isFinished {
        Task { await player.play(book, from: 0) }
      } else {
        Task { await player.play(book) }
      }
    } label: {
      HStack(spacing: 8) {
        if player.isStarting, isCurrent {
          ProgressView().tint(.white)
        } else {
          Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
        }
        Text(playTitle)
      }
      .font(.headline)
      .frame(maxWidth: .infinity, minHeight: 34)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
  }

  // MARK: Details

  @ViewBuilder private var detailsSection: some View {
    Section("Informationen") {
      if let s = meta.series?.first, !s.name.isEmpty {
        NavigationLink(value: Route.series(id: s.id, name: s.name)) {
          LabeledContent("Serie", value: meta.displaySeries ?? s.name)
        }
      } else if let s = meta.displaySeries {
        LabeledContent("Serie", value: s)
      }
      if book.duration > 0 { LabeledContent("Dauer", value: Fmt.duration(book.duration)) }
      if let y = meta.publishedYear, !y.isEmpty { LabeledContent("Erschienen", value: y) }
      if let p = meta.publisher, !p.isEmpty { LabeledContent("Verlag", value: p) }
      if let g = meta.genres, !g.isEmpty { LabeledContent("Genre", value: g.joined(separator: ", ")) }
      if let l = meta.language, !l.isEmpty { LabeledContent("Sprache", value: l) }
      if meta.abridged == true { LabeledContent("Fassung", value: "Gekürzt") }
    }
  }

  /// HTML aus Audiobookshelf-Beschreibungen entfernen
  private func cleanDescription(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
    t = t.replacingOccurrences(of: "</p>", with: "\n\n")
    t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct ChapterRow: View {
  let chapter: ABSChapter
  let isCurrent: Bool
  var isDone = false

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if isCurrent {
          Image(systemName: "speaker.wave.2.fill")
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
          Text("\(chapter.id + 1)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.subheadline.monospacedDigit())
      .frame(width: 28)

      Text(chapter.title.isEmpty ? "Kapitel \(chapter.id + 1)" : chapter.title)
        .font(isCurrent ? .body.weight(.semibold) : .body)
        .foregroundStyle(isDone ? Color.secondary : Color.primary)
        .lineLimit(2)
      Spacer(minLength: 8)
      Text(Fmt.clock(chapter.duration))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}
