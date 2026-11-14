import Foundation
import Observation

/// Globaler App-Zustand: Anmeldung, Bibliotheken, Hörfortschritt
@Observable
@MainActor
final class AppModel {
  private(set) var isLoggedIn: Bool
  private(set) var libraries: [ABSLibrary] = []
  private(set) var progress: [String: ABSProgress] = [:]
  private(set) var username: String?
  var loadError: String?

  /// Wird erhöht, wenn sich Bibliothek oder Fortschritt ändern – Listen laden dann neu
  private(set) var revision = 0

  var libraryId: String? {
    didSet {
      UserDefaults.standard.set(libraryId, forKey: "abs.libraryId")
      revision += 1
    }
  }

  var library: ABSLibrary? { libraries.first { $0.id == libraryId } }
  var bookLibraries: [ABSLibrary] { libraries.filter(\.isBookLibrary) }

  private let client = ABSClient.shared

  init() {
    isLoggedIn = ABSClient.shared.isLoggedIn
    libraryId = UserDefaults.standard.string(forKey: "abs.libraryId")
    client.onUnauthorized = { [weak self] in self?.logout() }
  }

  func didLogin(defaultLibraryId: String?) async {
    if libraryId == nil { libraryId = defaultLibraryId }
    isLoggedIn = true
    await bootstrap()
  }

  func bootstrap() async {
    guard client.isLoggedIn else { return }
    do {
      let libs = try await client.libraries()
      libraries = libs
      let books = libs.filter(\.isBookLibrary)
      if libraryId == nil || !books.contains(where: { $0.id == libraryId }) {
        libraryId = books.first?.id ?? libs.first?.id
      }
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
    await refreshProgress()
  }

  func refreshProgress() async {
    guard let me = try? await client.me() else { return }
    username = me.username
    progress = Dictionary(me.mediaProgress.filter { $0.episodeId == nil }.map { ($0.libraryItemId, $0) },
                          uniquingKeysWith: { a, b in (a.lastUpdate ?? 0) > (b.lastUpdate ?? 0) ? a : b })
    revision += 1
  }

  func progress(for itemId: String) -> ABSProgress? { progress[itemId] }

  /// Lokale Aktualisierung während der Wiedergabe (ohne Netzwerk)
  func updateLocalProgress(itemId: String, currentTime: Double, duration: Double) {
    guard duration > 0 else { return }
    if var p = progress[itemId] {
      p.currentTime = currentTime
      p.progress = min(1, currentTime / duration)
      p.duration = duration
      progress[itemId] = p
    }
  }

  func setFinished(_ itemId: String, _ finished: Bool) async {
    do {
      try await client.setFinished(itemId, finished)
      await refreshProgress()
    } catch {
      loadError = error.localizedDescription
    }
  }

  func resetProgress(_ itemId: String) async {
    try? await client.resetProgress(itemId)
    await refreshProgress()
  }

  func logout() {
    client.logout()
    isLoggedIn = false
    libraries = []
    progress = [:]
    username = nil
  }
}
