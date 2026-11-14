import SwiftUI

// MARK: - Mini-Player

struct MiniPlayerBar: View {
  @Environment(PlayerEngine.self) private var player

  var body: some View {
    if let item = player.item {
      HStack(spacing: 12) {
        BookCover(item: item, cornerRadius: 6, width: 160)
          .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text(item.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(player.currentChapter?.title.nilIfEmpty ?? item.author)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Button {
          player.togglePlayPause()
        } label: {
          ZStack {
            if player.isBuffering || player.isStarting {
              ProgressView()
            } else {
              Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
            }
          }
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
        }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
        Button {
          player.skipForward()
        } label: {
          Image(systemName: "goforward.\(Int(player.skipForwardInterval))")
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(Int(player.skipForwardInterval)) Sekunden vor")
      }
      .buttonStyle(.plain)
      .padding(.leading, 8)
      .padding(.trailing, 4)
      .padding(.vertical, 6)
      .background {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.regularMaterial)
          .overlay(alignment: .bottom) {
            GeometryReader { geo in
              Capsule()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * fraction, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
            .accessibilityHidden(true)
          }
          .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
      }
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .onTapGesture { player.isPresented = true }
      .accessibilityElement(children: .contain)
      .accessibilityAction(named: "Player öffnen") { player.isPresented = true }
      .contextMenu {
        Button(role: .destructive) {
          Task { await player.stop() }
        } label: {
          Label("Wiedergabe beenden", systemImage: "xmark.circle")
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 6)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var fraction: Double {
    guard player.duration > 0 else { return 0 }
    return min(1, player.currentTime / player.duration)
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Vollbild-Player

struct PlayerView: View {
  @Environment(PlayerEngine.self) private var player
  @Environment(\.dismiss) private var dismiss
  @State private var scrubbing = false
  @State private var scrubValue: Double = 0
  @State private var showChapters = false

  private let rates: [Float] = [0.75, 0.9, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0]

  // Der Schieberegler bezieht sich auf das aktuelle Kapitel (bzw. das ganze Buch ohne Kapitel)
  private var range: ClosedRange<Double> {
    if let c = player.currentChapter, player.chapters.count > 1, c.end > c.start { return c.start ... c.end }
    return 0 ... max(player.duration, 1)
  }

  private var shownTime: Double { scrubbing ? scrubValue : min(max(player.currentTime, range.lowerBound), range.upperBound) }

  var body: some View {
    if let item = player.item {
      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 12)
        BookCover(item: item, cornerRadius: 16, width: 900)
          .frame(maxWidth: 340)
          .scaleEffect(player.isPlaying ? 1 : 0.86)
          .shadow(color: .black.opacity(player.isPlaying ? 0.3 : 0.15), radius: player.isPlaying ? 24 : 12, y: 10)
          .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
          .padding(.horizontal, 28)
        Spacer(minLength: 16)
        titles(item)
          .padding(.horizontal, 28)
        scrubber
          .padding(.horizontal, 28)
          .padding(.top, 18)
        transport
          .padding(.top, 14)
        Spacer(minLength: 12)
        bottomBar
          .padding(.horizontal, 36)
          .padding(.bottom, 8)
      }
      .presentationDragIndicator(.visible)
      .sheet(isPresented: $showChapters) {
        ChaptersSheet()
          .presentationDetents([.medium, .large])
      }
    } else {
      ContentUnavailableView("Nichts in Wiedergabe", systemImage: "headphones")
        .onAppear { dismiss() }
    }
  }

  // MARK: Teile

  private var topBar: some View {
    HStack {
      Button { dismiss() } label: {
        Image(systemName: "chevron.down")
          .font(.headline)
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Schließen")
      Spacer()
      Menu {
        if let item = player.item {
          Button {
            Task { await player.stop(); dismiss() }
          } label: {
            Label("Wiedergabe beenden", systemImage: "xmark.circle")
          }
          Button {
            Task { await PlayerEngine.shared.app?.setFinished(item.id, true) }
          } label: {
            Label("Als beendet markieren", systemImage: "checkmark.circle")
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.headline)
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Weitere Aktionen")
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 12)
    .padding(.top, 8)
  }

  private func titles(_ item: ABSItem) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(player.currentChapter?.title.nilIfEmpty ?? item.title)
        .font(.title3.bold())
        .lineLimit(2)
      Text(player.chapters.count > 1 ? "\(item.title) · \(item.author)" : item.author)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var scrubber: some View {
    VStack(spacing: 6) {
      Slider(value: Binding(get: { shownTime }, set: { scrubValue = $0 }), in: range, onEditingChanged: { editing in
        if editing {
          scrubValue = shownTime
          scrubbing = true
        } else {
          player.seek(to: scrubValue)
          scrubbing = false
        }
      })
      .tint(.primary)
      .accessibilityLabel("Position im Kapitel")
      .accessibilityValue(Fmt.clock(shownTime - range.lowerBound))

      HStack {
        Text(Fmt.clock(shownTime - range.lowerBound))
        Spacer()
        Text(chapterInfo)
          .lineLimit(1)
        Spacer()
        Text("-" + Fmt.clock((range.upperBound - shownTime) / Double(player.rate)))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }

  private var chapterInfo: String {
    let left = "noch " + Fmt.duration(player.remainingAtRate)
    if let i = player.currentChapterIndex, player.chapters.count > 1 {
      return "Kapitel \(i + 1)/\(player.chapters.count) · \(left)"
    }
    return left
  }

  private var transport: some View {
    HStack {
      Button { player.previousChapter() } label: {
        Image(systemName: "backward.end.fill").font(.title2)
      }
      .accessibilityLabel("Voriges Kapitel")
      .disabled(player.chapters.count < 2)

      Spacer()
      Button { player.skipBack() } label: {
        Image(systemName: "gobackward.\(Int(player.skipBackInterval))").font(.system(size: 34))
      }
      .accessibilityLabel("\(Int(player.skipBackInterval)) Sekunden zurück")

      Spacer()
      Button { player.togglePlayPause() } label: {
        ZStack {
          if player.isBuffering || player.isStarting {
            ProgressView().controlSize(.large)
          } else {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 52))
              .contentTransition(.symbolEffect(.replace))
          }
        }
        .frame(width: 72, height: 72)
      }
      .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")

      Spacer()
      Button { player.skipForward() } label: {
        Image(systemName: "goforward.\(Int(player.skipForwardInterval))").font(.system(size: 34))
      }
      .accessibilityLabel("\(Int(player.skipForwardInterval)) Sekunden vor")

      Spacer()
      Button { player.nextChapter() } label: {
        Image(systemName: "forward.end.fill").font(.title2)
      }
      .accessibilityLabel("Nächstes Kapitel")
      .disabled(player.chapters.count < 2)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .padding(.horizontal, 28)
    .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
  }

  private var bottomBar: some View {
    @Bindable var player = player
    return HStack {
      Menu {
        Picker("Geschwindigkeit", selection: $player.rate) {
          ForEach(rates, id: \.self) { Text(Fmt.rate($0)).tag($0) }
        }
      } label: {
        Text(Fmt.rate(player.rate))
          .font(.subheadline.weight(.semibold).monospacedDigit())
          .frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel("Wiedergabegeschwindigkeit \(Fmt.rate(player.rate))")

      Spacer()
      SleepTimerMenu()

      Spacer()
      Button { showChapters = true } label: {
        Image(systemName: "list.bullet")
          .font(.title3)
          .frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel("Kapitel")
      .disabled(player.chapters.isEmpty)

      Spacer()
      RoutePicker()
        .frame(width: 44, height: 44)
        .accessibilityLabel("AirPlay")
    }
    .foregroundStyle(.primary)
  }
}

// MARK: - Schlaf-Timer

struct SleepTimerMenu: View {
  @Environment(PlayerEngine.self) private var player
  private let minutes = [5, 10, 15, 30, 45, 60, 90]

  var body: some View {
    Menu {
      if player.sleepTimer != .off {
        Button(role: .destructive) { player.setSleepTimer(.off) } label: {
          Label("Timer aus", systemImage: "moon.zzz")
        }
      }
      if player.chapters.count > 1 {
        Button { player.setSleepTimer(.endOfChapter) } label: {
          Label("Ende des Kapitels", systemImage: "text.badge.checkmark")
        }
      }
      Section("Schlaf-Timer") {
        ForEach(minutes, id: \.self) { m in
          Button("\(m) Minuten") {
            player.setSleepTimer(.until(Date().addingTimeInterval(Double(m) * 60)))
          }
        }
      }
    } label: {
      // Restzeit sekundengenau als laufende Uhr
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        if let r = player.sleepTimerRemaining {
          Label(Fmt.clock(r), systemImage: "moon.zzz.fill")
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(.tint)
        } else {
          Image(systemName: "moon.zzz").font(.title3)
        }
      }
      .frame(minWidth: 44, minHeight: 44)
    }
    .accessibilityLabel(player.sleepTimer == .off ? "Schlaf-Timer" : "Schlaf-Timer aktiv")
  }
}

// MARK: - Kapitelliste

struct ChaptersSheet: View {
  @Environment(PlayerEngine.self) private var player
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        List(player.chapters) { c in
          Button {
            player.seek(to: c.start)
            if !player.isPlaying { player.play() }
            dismiss()
          } label: {
            ChapterRow(chapter: c, isCurrent: player.currentChapter?.id == c.id,
                       isDone: player.currentTime >= c.end - 1)
          }
          .foregroundStyle(.primary)
          .id(c.id)
        }
        .listStyle(.plain)
        .onAppear {
          if let id = player.currentChapter?.id { proxy.scrollTo(id, anchor: .center) }
        }
      }
      .navigationTitle("Kapitel")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
      }
    }
  }
}
