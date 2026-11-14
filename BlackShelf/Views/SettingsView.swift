import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var app
  @Environment(PlayerEngine.self) private var player
  @Environment(\.dismiss) private var dismiss

  @State private var confirmLogout = false

  private let intervals: [Double] = [10, 15, 30, 45, 60]

  var body: some View {
    @Bindable var app = app
    @Bindable var player = player
    @Bindable var covers = AudibleCovers.shared
    NavigationStack {
      Form {
        Section {
          NavigationLink(value: Route.stats) {
            Label("Hörstatistik", systemImage: "chart.bar.fill")
          }
          NavigationLink {
            HomeEditView()
          } label: {
            Label("Startseite anpassen", systemImage: "rectangle.3.group")
          }
        }

        Section("Audiobookshelf") {
          LabeledContent("Server", value: ABSClient.shared.baseURL)
          if let u = app.username { LabeledContent("Benutzer", value: u) }
          if app.bookLibraries.count > 1 {
            Picker("Bibliothek", selection: $app.libraryId) {
              ForEach(app.bookLibraries) { Text($0.name).tag(Optional($0.id)) }
            }
          }
        }

        Section {
          Picker("Zurückspringen", selection: $player.skipBackInterval) {
            ForEach(intervals, id: \.self) { Text("\(Int($0)) Sek.").tag($0) }
          }
          Picker("Vorspringen", selection: $player.skipForwardInterval) {
            ForEach(intervals, id: \.self) { Text("\(Int($0)) Sek.").tag($0) }
          }
        } header: {
          Text("Wiedergabe")
        } footer: {
          Text("Gilt auch für Sperrbildschirm, Kontrollzentrum und Kopfhörer.")
        }

        Section {
          Toggle("Cover von Audible", isOn: $covers.enabled)
          Button {
            covers.reset()
          } label: {
            HStack {
              Label("Cover neu suchen", systemImage: "arrow.triangle.2.circlepath")
              Spacer()
              if covers.isBusy { ProgressView() }
            }
          }
          .disabled(!covers.enabled || covers.isBusy)
          .sensoryFeedback(.success, trigger: covers.rebuilding) { old, new in old && !new }
          if covers.enabled, let status = covers.statusText {
            Text(status)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .contentTransition(.numericText())
              .animation(.default, value: status)
          }
        } header: {
          Text("Darstellung")
        } footer: {
          Text("Zeigt statt der Cover aus Audiobookshelf die offiziellen Audible-Cover. Mit Blackbox Request ordnet der Server die Cover zu – dieselbe Quelle wie bei angefragten Büchern.")
        }

        Section {
          NavigationLink {
            BlackboxSettingsView()
          } label: {
            LabeledContent {
              Text(BlackboxConfig.username.isEmpty ? (BlackboxConfig.isConfigured ? "Eingerichtet" : "Nicht eingerichtet") : BlackboxConfig.username)
            } label: {
              Label("Blackbox Request", systemImage: "tray.and.arrow.down")
            }
          }
        } footer: {
          Text("Hörbücher anfragen – sie landen automatisch in deiner Audiobookshelf-Bibliothek.")
        }

        Section {
          Button("Abmelden", role: .destructive) { confirmLogout = true }
        } footer: {
          Text("BlackShelf \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
      }
      .navigationTitle("Einstellungen")
      .task { AudibleCovers.shared.refreshFromServer() }
      .appDestinations()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Fertig") { dismiss() }
        }
      }
      .confirmationDialog("Wirklich abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
        Button("Abmelden", role: .destructive) {
          Task {
            await player.stop()
            app.logout()
            dismiss()
          }
        }
      } message: {
        Text("Dein Hörfortschritt bleibt auf dem Server gespeichert.")
      }
    }
  }
}
