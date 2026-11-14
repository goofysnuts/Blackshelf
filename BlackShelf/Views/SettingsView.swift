import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var app
  @Environment(PlayerEngine.self) private var player
  @Environment(\.dismiss) private var dismiss

  @State private var bbUrl = BlackboxConfig.url
  @State private var bbKey = BlackboxConfig.apiKey
  @State private var bbTest: String?
  @State private var bbTesting = false
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
          Button("Cover neu suchen") { AudibleCovers.shared.reset() }
            .disabled(!covers.enabled)
        } header: {
          Text("Darstellung")
        } footer: {
          Text("Zeigt statt der Cover aus Audiobookshelf die offiziellen Audible-Cover, sofern das Buch dort gefunden wird.")
        }

        Section {
          TextField("Adresse", text: $bbUrl, prompt: Text("http://NAS-IP:Port"))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: bbUrl) { _, v in BlackboxConfig.url = v; bbTest = nil }
          SecureField("API-Schlüssel (optional)", text: $bbKey)
            .textInputAutocapitalization(.never)
            .onChange(of: bbKey) { _, v in BlackboxConfig.apiKey = v; bbTest = nil }
          Button {
            Task {
              bbTesting = true
              defer { bbTesting = false }
              do { bbTest = try await BlackboxClient().health() } catch { bbTest = error.localizedDescription }
            }
          } label: {
            HStack {
              Text("Verbindung testen")
              Spacer()
              if bbTesting { ProgressView() }
            }
          }
          .disabled(bbUrl.isEmpty || bbTesting)
          if let bbTest {
            Text(bbTest).font(.footnote).foregroundStyle(.secondary)
          }
        } header: {
          Text("Blackbox Request")
        } footer: {
          Text("Der gleiche Dienst wie in Blackbox – hier nur für Hörbücher. Angefragte Bücher landen automatisch in deiner Audiobookshelf-Bibliothek.")
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
