import SwiftUI

@main
struct BlackShelfApp: App {
  @State private var app = AppModel()
  private let player = PlayerEngine.shared
  @Environment(\.scenePhase) private var scenePhase

  init() {
    URLCache.shared = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(app)
        .environment(player)
        .task {
          player.app = app
          if app.isLoggedIn {
            await app.bootstrap()
            await player.restoreLastItem()
          }
        }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background: player.sync()
      case .active: if app.isLoggedIn { Task { await app.refreshProgress() } }
      default: break
      }
    }
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Group {
      if app.isLoggedIn {
        MainTabView()
      } else {
        LoginView()
      }
    }
    .animation(.default, value: app.isLoggedIn)
  }
}

enum AppTab: Hashable { case home, library, requests, search }

struct MainTabView: View {
  @Environment(PlayerEngine.self) private var player
  @State private var tab: AppTab = .home

  var body: some View {
    @Bindable var player = player
    TabView(selection: $tab) {
      Tab("Start", systemImage: "house", value: AppTab.home) {
        HomeView().miniPlayerInset()
      }
      Tab("Bibliothek", systemImage: "books.vertical", value: AppTab.library) {
        LibraryView().miniPlayerInset()
      }
      Tab("Anfragen", systemImage: "tray.and.arrow.down", value: AppTab.requests) {
        RequestsView().miniPlayerInset()
      }
      Tab(value: AppTab.search, role: .search) {
        SearchView().miniPlayerInset()
      }
    }
    .sheet(isPresented: $player.isPresented) {
      PlayerView()
    }
    .alert("Wiedergabe", isPresented: Binding(
      get: { player.errorMessage != nil },
      set: { if !$0 { player.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(player.errorMessage ?? "")
    }
  }
}
