import SwiftUI

/// Verbindung zu Blackbox Request: Adresse und Anmeldung pro Benutzer
struct BlackboxSettingsView: View {
  private enum Method: String, CaseIterable, Identifiable {
    case password = "Passwort", key = "App-Schlüssel"
    var id: Self { self }
  }

  @State private var url = BlackboxConfig.url
  @State private var username = BlackboxConfig.username
  @State private var password = ""
  @State private var key = ""
  @State private var method: Method = .password
  @State private var me: BBRMe?
  @State private var loggedIn = !BlackboxConfig.apiKey.isEmpty
  @State private var busy = false
  @State private var message: String?
  @State private var health: String?
  @FocusState private var focus: Bool

  var body: some View {
    Form {
      Section {
        TextField("Adresse", text: $url, prompt: Text("http://NAS-IP:8686"))
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { BlackboxConfig.url = url }
          .onChange(of: url) { _, v in BlackboxConfig.url = v }
      } header: {
        Text("Server")
      }

      if loggedIn {
        Section("Konto") {
          if let me {
            LabeledContent("Angemeldet als", value: me.username)
            LabeledContent("Rolle", value: me.isAdmin ? "Admin" : "Benutzer")
            if !me.can("request_audiobooks") {
              Label("Du darfst keine Hörbücher anfragen.", systemImage: "nosign")
                .foregroundStyle(.orange)
            } else if !me.can("auto_approve") {
              Label("Deine Anfragen werden von einem Admin freigegeben.", systemImage: "person.badge.clock")
                .foregroundStyle(.secondary)
            }
            if let limit = me.weeklyLimit, limit > 0 {
              LabeledContent("Anfragen diese Woche", value: "\(me.requestsWeek ?? 0) von \(limit)")
            }
          } else if busy {
            HStack { Text("Prüfe Anmeldung …"); Spacer(); ProgressView() }
          }
          Button {
            Task { await check() }
          } label: {
            HStack {
              Text("Verbindung testen")
              Spacer()
              if busy { ProgressView() }
            }
          }
          .disabled(busy)
          if let health {
            Text(health).font(.footnote).foregroundStyle(.secondary)
          }
          Button("Abmelden", role: .destructive) {
            Task {
              await BlackboxClient.logout()
              me = nil
              loggedIn = false
              health = nil
            }
          }
        }
      } else {
        Section {
          Picker("Anmeldung mit", selection: $method) {
            ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())

          if method == .password {
            TextField("Benutzername", text: $username)
              .textContentType(.username)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            SecureField("Passwort", text: $password)
              .textContentType(.password)
              .submitLabel(.go)
              .onSubmit { Task { await login() } }
          } else {
            SecureField("App-Schlüssel oder API-Key", text: $key)
              .textInputAutocapitalization(.never)
          }
          Button {
            Task { await login() }
          } label: {
            HStack {
              Spacer()
              if busy { ProgressView() } else { Text("Anmelden").bold() }
              Spacer()
            }
          }
          .disabled(busy || url.isEmpty || (method == .password ? username.isEmpty || password.isEmpty : key.isEmpty))
        } header: {
          Text("Anmelden")
        } footer: {
          Text(method == .password
            ? "Mit deinem Benutzer aus Blackbox Request. Ein Admin legt neue Benutzer in der Weboberfläche unter „Benutzer“ an."
            : "App-Schlüssel erzeugst du in der Weboberfläche über deinen Namen oben rechts.")
        }
      }

      if let message {
        Section {
          Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("Blackbox Request")
    .navigationBarTitleDisplayMode(.inline)
    .task { if loggedIn { await check() } }
  }

  private func login() async {
    busy = true
    message = nil
    defer { busy = false }
    do {
      if method == .password {
        me = try await BlackboxClient.login(base: url, username: username.trimmingCharacters(in: .whitespaces),
                                            password: password)
        password = ""
      } else {
        BlackboxConfig.url = url
        let candidate = BlackboxClient(base: url, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
        let m = try await candidate.me()
        BlackboxConfig.apiKey = candidate.apiKey
        BlackboxConfig.username = m.username
        me = m
        key = ""
      }
      loggedIn = true
    } catch {
      message = error.localizedDescription
    }
  }

  private func check() async {
    busy = true
    defer { busy = false }
    do {
      let m = try await BlackboxClient().me()
      me = m
      BlackboxConfig.username = m.username
      health = try? await BlackboxClient().health()
      message = nil
    } catch BlackboxClient.ClientError.unauthorized {
      message = "Anmeldung abgelaufen oder widerrufen – bitte erneut anmelden."
      BlackboxConfig.apiKey = ""
      loggedIn = false
    } catch {
      message = error.localizedDescription
    }
  }
}
