import SwiftUI

/// Reihenfolge und Sichtbarkeit der Abschnitte auf der Startseite
enum HomeLayout {
  static let orderKey = "home.order"
  static let hiddenKey = "home.hidden"

  /// Alle bekannten Abschnitte in Standard-Reihenfolge
  static let defaults: [String] = [
    "continue-listening", "book-of-day", "stats", "continue-series", "recently-added",
    "discover", "recent-series", "listen-again", "newest-authors",
  ]

  static func title(_ id: String) -> String {
    switch id {
    case "book-of-day": return "Hörbuch des Tages"
    case "stats": return "Hörzeit"
    default: return ABSShelf.germanLabel(id: id, fallback: id)
    }
  }

  static func symbol(_ id: String) -> String {
    switch id {
    case "continue-listening": return "play.circle"
    case "book-of-day": return "sun.max"
    case "stats": return "chart.bar"
    case "continue-series": return "books.vertical"
    case "recently-added": return "clock"
    case "discover": return "sparkles"
    case "recent-series": return "square.stack"
    case "listen-again": return "arrow.counterclockwise"
    case "newest-authors": return "person.2"
    default: return "rectangle.stack"
    }
  }

  static func decode(_ raw: String) -> [String] {
    raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
  }

  /// Gespeicherte Reihenfolge + neue (unbekannte) Abschnitte an ihrer Standardposition
  static func ordered(_ raw: String, including extra: [String] = []) -> [String] {
    var order = decode(raw)
    if order.isEmpty { order = defaults }
    for id in defaults + extra where !order.contains(id) {
      // nach dem Vorgänger aus der Standardliste einsortieren
      if let i = defaults.firstIndex(of: id), i > 0, let prev = order.firstIndex(of: defaults[i - 1]) {
        order.insert(id, at: prev + 1)
      } else {
        order.append(id)
      }
    }
    return order
  }
}

struct HomeEditView: View {
  @AppStorage(HomeLayout.orderKey) private var orderRaw = ""
  @AppStorage(HomeLayout.hiddenKey) private var hiddenRaw = ""
  @State private var order: [String] = []
  @State private var hidden: Set<String> = []

  var body: some View {
    List {
      Section {
        ForEach(order, id: \.self) { id in
          Button {
            toggle(id)
          } label: {
            HStack(spacing: 14) {
              Image(systemName: hidden.contains(id) ? "circle" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(hidden.contains(id) ? Color.secondary : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
              Label(HomeLayout.title(id), systemImage: HomeLayout.symbol(id))
                .foregroundStyle(.primary)
            }
          }
          .accessibilityValue(hidden.contains(id) ? "ausgeblendet" : "sichtbar")
          .accessibilityHint("Doppeltippen zum Ein- oder Ausblenden")
        }
        .onMove { from, to in
          order.move(fromOffsets: from, toOffset: to)
          save()
        }
      } footer: {
        Text("Tippen blendet einen Abschnitt ein oder aus, mit dem Griff rechts änderst du die Reihenfolge. Abschnitte ohne Inhalt erscheinen nicht.")
      }

      Section {
        Button("Standard wiederherstellen") {
          withAnimation {
            order = HomeLayout.defaults
            hidden = []
            save()
          }
        }
      }
    }
    .environment(\.editMode, .constant(.active))
    .navigationTitle("Startseite")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      order = HomeLayout.ordered(orderRaw)
      hidden = Set(HomeLayout.decode(hiddenRaw))
    }
  }

  private func toggle(_ id: String) {
    withAnimation {
      if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
    }
    save()
  }

  private func save() {
    orderRaw = order.joined(separator: ",")
    hiddenRaw = hidden.sorted().joined(separator: ",")
  }
}
