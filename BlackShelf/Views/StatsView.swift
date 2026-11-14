import Charts
import SwiftUI

// MARK: - Hörstatistik

struct StatsView: View {
  @Environment(AppModel.self) private var app
  @State private var stats: ABSListeningStats?
  @State private var users: [ABSUser] = []
  @State private var selectedUser: ABSUser?
  @State private var error: String?
  @State private var range: StatsRange = .week

  enum StatsRange: String, CaseIterable, Identifiable {
    case week = "7 Tage", month = "30 Tage", year = "12 Monate"
    var id: Self { self }
  }

  /// nil = eigene Statistik
  private var viewedUserId: String? {
    guard let u = selectedUser, u.id != app.userId else { return nil }
    return u.id
  }

  private var title: String {
    if let u = selectedUser, u.id != app.userId { return u.username }
    return "Hörstatistik"
  }

  var body: some View {
    List {
      if let stats {
        Section {
          StatTiles(stats: stats)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        Section {
          Picker("Zeitraum", selection: $range) {
            ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .listRowSeparator(.hidden)
          ListeningChart(stats: stats, range: range)
            .frame(height: 200)
            .padding(.vertical, 4)
        } header: {
          Text("Verlauf")
        } footer: {
          Text(averageText(stats))
        }

        if stats.weekdays.contains(where: { $0.seconds > 0 }) {
          Section {
            WeekdayChart(stats: stats)
              .frame(height: 140)
              .padding(.vertical, 4)
          } header: {
            Text("Wochentage")
          } footer: {
            if let best = stats.weekdays.max(by: { $0.seconds < $1.seconds }), best.seconds > 0 {
              Text("Am meisten hörst du \(longWeekday(best.name)).")
            }
          }
        }

        if !stats.items.isEmpty {
          Section("Meistgehört") {
            ForEach(Array(stats.items.prefix(10).enumerated()), id: \.element.id) { index, item in
              NavigationLink(value: Route.bookId(item.id)) {
                HStack(spacing: 12) {
                  Text("\(index + 1)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                  ItemIdCover(itemId: item.id)
                    .frame(width: 44, height: 44)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(2)
                    Text(item.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer(minLength: 6)
                  Text(Fmt.duration(item.timeListening))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        if !stats.recentSessions.isEmpty {
          Section("Zuletzt gehört") {
            ForEach(stats.recentSessions.prefix(15)) { s in
              NavigationLink(value: Route.bookId(s.libraryItemId)) {
                HStack(spacing: 12) {
                  ItemIdCover(itemId: s.libraryItemId)
                    .frame(width: 44, height: 44)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayTitle).lineLimit(1)
                    Text(s.updatedAt, format: .relative(presentation: .named))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 6)
                  Text(Fmt.duration(s.timeListening))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      } else if let error {
        ContentUnavailableView("Statistik nicht verfügbar", systemImage: "chart.bar.xaxis",
                               description: Text(error))
          .listRowBackground(Color.clear)
      }
    }
    .listStyle(.insetGrouped)
    .overlay { if stats == nil, error == nil { ProgressView() } }
    .navigationTitle(title)
    .toolbar {
      if app.isAdmin, users.count > 1 {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Picker("Nutzer", selection: $selectedUser) {
              ForEach(users) { u in
                Label(u.username + (u.id == app.userId ? " (ich)" : ""),
                      systemImage: u.type == "root" || u.type == "admin" ? "person.badge.key" : "person")
                  .tag(Optional(u))
              }
            }
          } label: {
            Image(systemName: "person.2.circle")
          }
          .accessibilityLabel("Nutzer wählen")
        }
      }
    }
    .refreshable { await load() }
    .task {
      if app.isAdmin, users.isEmpty {
        users = (try? await ABSClient.shared.users()) ?? []
        selectedUser = users.first { $0.id == app.userId }
      }
    }
    .task(id: selectedUser?.id) { await load() }
  }

  private func load() async {
    do {
      stats = try await ABSClient.shared.listeningStats(userId: viewedUserId)
      error = nil
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
    }
  }

  private func averageText(_ s: ABSListeningStats) -> String {
    switch range {
    case .week: return "Ø \(Fmt.duration(s.thisWeek / 7)) pro Tag in den letzten 7 Tagen"
    case .month:
      let total = s.lastDays(30).reduce(0) { $0 + $1.seconds }
      return "Ø \(Fmt.duration(total / 30)) pro Tag in den letzten 30 Tagen"
    case .year:
      let total = s.lastMonths(12).reduce(0) { $0 + $1.seconds }
      return "\(Fmt.duration(total)) in den letzten 12 Monaten"
    }
  }

  private func longWeekday(_ short: String) -> String {
    ["Mo": "montags", "Di": "dienstags", "Mi": "mittwochs", "Do": "donnerstags",
     "Fr": "freitags", "Sa": "samstags", "So": "sonntags"][short] ?? short
  }
}

// MARK: - Kacheln

struct StatTiles: View {
  let stats: ABSListeningStats

  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
      StatTile(title: "Heute", value: Fmt.duration(stats.today), symbol: "sun.max.fill", color: .orange)
      StatTile(title: "Diese Woche", value: Fmt.duration(stats.thisWeek), symbol: "calendar", color: .blue)
      StatTile(title: "Insgesamt", value: Fmt.duration(stats.totalTime), symbol: "headphones", color: .purple)
      StatTile(title: "Serie", value: stats.streak == 1 ? "1 Tag" : "\(stats.streak) Tage",
               symbol: "flame.fill", color: .red)
    }
  }
}

struct StatTile: View {
  let title: String
  let value: String
  let symbol: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
      Text(value)
        .font(.title3.bold())
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Diagramme

struct ListeningChart: View {
  let stats: ABSListeningStats
  let range: StatsView.StatsRange

  private struct Point: Identifiable {
    let date: Date
    let minutes: Double
    var id: Date { date }
  }

  private var points: [Point] {
    switch range {
    case .week: return stats.lastDays(7).map { Point(date: $0.date, minutes: $0.seconds / 60) }
    case .month: return stats.lastDays(30).map { Point(date: $0.date, minutes: $0.seconds / 60) }
    case .year: return stats.lastMonths(12).map { Point(date: $0.date, minutes: $0.seconds / 60) }
    }
  }

  private var axisDates: [Date] {
    let dates = points.map(\.date)
    guard range == .month else { return dates }
    return dates.enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
  }

  private func axisLabel(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    switch range {
    case .week: f.dateFormat = "EEEEEE"
    case .month: f.dateFormat = "d.M."
    case .year: f.dateFormat = "MMMMM"
    }
    return f.string(from: d)
  }

  /// Ab 2 Stunden auf der Achse in Stunden statt Minuten
  private var useHours: Bool { (points.map(\.minutes).max() ?? 0) >= 120 }

  var body: some View {
    Chart(points) { p in
      BarMark(
        x: .value("Datum", p.date, unit: range == .year ? .month : .day),
        y: .value(useHours ? "Stunden" : "Minuten", useHours ? p.minutes / 60 : p.minutes)
      )
      .foregroundStyle(Color.accentColor.gradient)
      .cornerRadius(3)
    }
    .chartXAxis {
      AxisMarks(values: axisDates) { value in
        AxisGridLine()
        AxisValueLabel(centered: range != .month) {
          if let d = value.as(Date.self) { Text(axisLabel(d)) }
        }
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let v = value.as(Double.self) { Text("\(Int(v)) \(useHours ? "h" : "min")") }
        }
      }
    }
    .environment(\.locale, Locale(identifier: "de_DE"))
    .accessibilityLabel("Hörzeit-Verlauf")
  }
}

struct WeekdayChart: View {
  let stats: ABSListeningStats

  var body: some View {
    Chart(stats.weekdays) { d in
      BarMark(x: .value("Tag", d.name), y: .value("Stunden", d.seconds / 3600))
        .foregroundStyle(Color.accentColor.opacity(0.75).gradient)
        .cornerRadius(3)
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let v = value.as(Double.self) { Text("\(Int(v)) h") }
        }
      }
    }
  }
}

// MARK: - Kompakte Karte für die Startseite

struct StatsSummaryCard: View {
  let stats: ABSListeningStats

  var body: some View {
    NavigationLink(value: Route.stats) {
      HStack(spacing: 14) {
        Image(systemName: "chart.bar.fill")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 36)
        VStack(alignment: .leading, spacing: 2) {
          Text("Hörzeit diese Woche")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(Fmt.duration(stats.thisWeek))
            .font(.title3.bold())
        }
        Spacer(minLength: 8)
        MiniWeekBars(stats: stats)
          .frame(width: 84, height: 34)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(14)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Öffnet die Hörstatistik")
  }
}

struct MiniWeekBars: View {
  let stats: ABSListeningStats

  var body: some View {
    let days = stats.lastDays(7)
    let maxV = max(days.map(\.seconds).max() ?? 0, 1)
    HStack(alignment: .bottom, spacing: 4) {
      ForEach(days) { d in
        Capsule()
          .fill(Calendar.current.isDateInToday(d.date) ? Color.accentColor : Color.accentColor.opacity(0.4))
          .frame(height: max(3, 34 * d.seconds / maxV))
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Hilfsansichten

/// Cover nur über die Item-ID (Statistik kennt kein vollständiges Buch)
struct ItemIdCover: View {
  let itemId: String

  var body: some View {
    let url: URL? = {
      if AudibleCovers.shared.enabled, case let .found(u) = AudibleCovers.shared.lookup(itemId, size: 500) { return u }
      return ABSClient.shared.coverURL(itemId, width: 160)
    }()
    SquareArtwork(url: url) {
      Rectangle().fill(.quaternary)
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .accessibilityHidden(true)
  }
}

/// Lädt ein Buch über die ID und zeigt die Detailseite
struct BookLoaderView: View {
  let itemId: String
  @State private var item: ABSItem?
  @State private var failed = false

  var body: some View {
    Group {
      if let item {
        BookDetailView(item: item)
      } else if failed {
        ContentUnavailableView("Nicht mehr vorhanden", systemImage: "book.closed",
                               description: Text("Dieses Hörbuch ist nicht mehr in der Bibliothek."))
      } else {
        ProgressView()
      }
    }
    .task {
      do { item = try await ABSClient.shared.item(itemId) } catch { failed = true }
    }
  }
}
