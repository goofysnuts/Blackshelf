import AVKit
import SwiftUI

// MARK: - Bilder mit Speicher-Cache

@MainActor
final class ImageCache {
  static let shared = ImageCache()
  private let cache = NSCache<NSString, UIImage>()
  private var running: [String: Task<UIImage?, Never>] = [:]

  init() { cache.countLimit = 400 }

  /// Schlüssel ohne Token, damit ein erneuertes Token den Cache nicht leert
  private func key(_ url: URL) -> String {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    c.queryItems = c.queryItems?.filter { $0.name != "token" }
    return c.string ?? url.absoluteString
  }

  func cached(_ url: URL) -> UIImage? { cache.object(forKey: key(url) as NSString) }

  func load(_ url: URL) async -> UIImage? {
    let k = key(url)
    if let img = cache.object(forKey: k as NSString) { return img }
    if let t = running[k] { return await t.value }
    let t = Task<UIImage?, Never> {
      guard let result = try? await URLSession.shared.data(from: url),
            (result.1 as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
      return await Task.detached(priority: .userInitiated) { () -> UIImage? in
        UIImage(data: result.0)?.preparingForDisplay()
      }.value
    }
    running[k] = t
    let img = await t.value
    running[k] = nil
    if let img { cache.setObject(img, forKey: k as NSString) }
    return img
  }
}

struct RemoteImage<Placeholder: View>: View {
  let url: URL?
  @ViewBuilder var placeholder: () -> Placeholder
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        placeholder()
      }
    }
    .task(id: url) {
      guard let url else { image = nil; return }
      if let c = ImageCache.shared.cached(url) { image = c; return }
      let loaded = await ImageCache.shared.load(url)
      withAnimation(.easeOut(duration: 0.2)) { image = loaded }
    }
  }
}

/// Quadratische Fläche für Cover. Nicht-quadratische Cover werden vollständig gezeigt
/// (eingepasst) und mit einer unscharfen Version ihrer selbst hinterlegt – so überlappt nichts
/// und es wird kein Titeltext abgeschnitten.
struct SquareArtwork<Placeholder: View>: View {
  let url: URL?
  @ViewBuilder var placeholder: () -> Placeholder
  @State private var image: UIImage?

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let image {
          let ratio = image.size.width / max(image.size.height, 1)
          if abs(ratio - 1) < 0.04 {
            Image(uiImage: image).resizable().scaledToFill()
          } else {
            ZStack {
              Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 20, opaque: true)
                .overlay(Color.black.opacity(0.25))
              Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .shadow(color: .black.opacity(0.35), radius: 6)
            }
          }
        } else {
          placeholder()
        }
      }
      .clipped()
      .task(id: url) {
        guard let url else { image = nil; return }
        if let c = ImageCache.shared.cached(url) { image = c; return }
        let loaded = await ImageCache.shared.load(url)
        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
      }
  }
}

/// Quadratisches Hörbuch-Cover mit optionalem Fortschrittsbalken
struct BookCover: View {
  let item: ABSItem?
  var cornerRadius: CGFloat = 8
  var progress: Double? = nil
  var finished = false
  var width = 400

  var body: some View {
    SquareArtwork(url: item.flatMap { AudibleCovers.shared.url(for: $0, width: width) }) {
      ZStack {
        Rectangle().fill(.quaternary)
        Image(systemName: "book.closed.fill")
          .font(.title)
          .foregroundStyle(.secondary)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
    }
    .overlay(alignment: .bottom) {
      if let progress, progress > 0, !finished {
        ProgressBar(value: progress)
          .padding(6)
      }
    }
    .overlay(alignment: .topTrailing) {
      if finished {
        Image(systemName: "checkmark.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .green)
          .font(.title3)
          .padding(5)
          .accessibilityLabel("Beendet")
      }
    }
    .accessibilityHidden(progress == nil && !finished)
    .task(id: item?.id) {
      if let item { AudibleCovers.shared.resolveIfNeeded(item) }
    }
  }
}

struct ProgressBar: View {
  let value: Double
  var height: CGFloat = 4

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.black.opacity(0.35))
        Capsule().fill(.white).frame(width: geo.size.width * min(max(value, 0), 1))
      }
    }
    .frame(height: height)
    .accessibilityElement()
    .accessibilityLabel("Fortschritt")
    .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
  }
}

/// Raster-Kachel: Cover, Titel, Autor
struct BookTile: View {
  let item: ABSItem
  @Environment(AppModel.self) private var app

  var body: some View {
    let p = app.progress(for: item.id)
    VStack(alignment: .leading, spacing: 6) {
      BookCover(item: item, progress: p?.progress, finished: p?.isFinished ?? false, width: 300)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
          .foregroundStyle(.primary)
        Text(item.author)
          .font(.caption)
          .lineLimit(1)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Listenzeile für Bücher
struct BookRow: View {
  let item: ABSItem
  @Environment(AppModel.self) private var app

  var body: some View {
    let p = app.progress(for: item.id)
    HStack(spacing: 12) {
      BookCover(item: item, cornerRadius: 6, finished: p?.isFinished ?? false, width: 160)
        .frame(width: 56)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.body).lineLimit(2)
        Text(item.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        if let s = item.media.metadata.displaySeries {
          Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if let p, p.progress > 0, !p.isFinished {
          ProgressView(value: p.progress)
            .tint(.accentColor)
            .padding(.top, 2)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

/// AirPlay-Auswahl
struct RoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let v = AVRoutePickerView()
    v.prioritizesVideoDevices = false
    v.tintColor = .label
    v.activeTintColor = UIColor(Color.accentColor)
    return v
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Formatierung

enum Fmt {
  /// „12 Std. 5 Min.“
  static func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60
    if h > 0 { return m > 0 ? "\(h) Std. \(m) Min." : "\(h) Std." }
    if m > 0 { return "\(m) Min." }
    return "\(total % 60) Sek."
  }

  /// „1:02:03“ bzw. „2:03“
  static func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(max(0, seconds).rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  static func rate(_ r: Float) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = 2
    return (f.string(from: NSNumber(value: r)) ?? "\(r)") + "×"
  }
}

// MARK: - Navigation

enum Route: Hashable {
  case book(ABSItem)
  case series(id: String, name: String)
  case author(id: String, name: String)
  case collection(ABSCollection)
  case requestBook(String)
  case findInLibrary(title: String, author: String)
  case bookId(String)
  case stats
}

extension View {
  /// Gemeinsame Ziele für alle Navigations-Stacks
  func appDestinations() -> some View {
    navigationDestination(for: Route.self) { route in
      switch route {
      case let .book(item): BookDetailView(item: item)
      case let .series(id, name): SeriesView(seriesId: id, name: name)
      case let .author(id, name): AuthorView(authorId: id, name: name)
      case let .collection(c): CollectionView(collection: c)
      case let .requestBook(id): RequestBookDetailView(bookId: id)
      case let .findInLibrary(title, author): FindInLibraryView(title: title, author: author)
      case let .bookId(id): BookLoaderView(itemId: id)
      case .stats: StatsView()
      }
    }
  }

  /// Mini-Player über der Tab-Leiste
  func miniPlayerInset() -> some View {
    safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
  }
}
