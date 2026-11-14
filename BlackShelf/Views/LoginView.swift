import SwiftUI

struct LoginView: View {
  @Environment(AppModel.self) private var app

  private enum Method: String, CaseIterable, Identifiable {
    case password = "Passwort", apiKey = "API-Schlüssel"
    var id: Self { self }
  }

  @State private var server = UserDefaults.standard.string(forKey: "abs.server") ?? ""
  @State private var username = ""
  @State private var password = ""
  @State private var apiKey = ""
  @State private var method: Method = .password
  @State private var busy = false
  @State private var error: String?
  @FocusState private var focus: Field?

  private enum Field { case server, user, password, key }

  private var canSubmit: Bool {
    !server.trimmingCharacters(in: .whitespaces).isEmpty && !busy &&
      (method == .password ? !username.isEmpty : !apiKey.isEmpty)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(spacing: 10) {
            Image(systemName: "books.vertical.fill")
              .font(.system(size: 52))
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
            Text("Melde dich bei deinem Audiobookshelf-Server an, um deine Hörbücher zu hören.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .listRowBackground(Color.clear)
        }

        Section {
          TextField("Serveradresse", text: $server, prompt: Text("http://NAS-IP:13378"))
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .server)
            .submitLabel(.next)
            .onSubmit { focus = method == .password ? .user : .key }
        } header: {
          Text("Server")
        } footer: {
          Text("Adresse inklusive Port, z. B. über Tailscale auch unterwegs erreichbar.")
        }

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
              .focused($focus, equals: .user)
              .submitLabel(.next)
              .onSubmit { focus = .password }
            SecureField("Passwort", text: $password)
              .textContentType(.password)
              .focused($focus, equals: .password)
              .submitLabel(.go)
              .onSubmit { Task { await submit() } }
          } else {
            SecureField("API-Schlüssel", text: $apiKey)
              .textInputAutocapitalization(.never)
              .focused($focus, equals: .key)
              .submitLabel(.go)
              .onSubmit { Task { await submit() } }
          }
        } footer: {
          if method == .apiKey {
            Text("API-Schlüssel laufen nicht ab. Du erstellst sie in Audiobookshelf unter Einstellungen → API-Schlüssel.")
          }
        }

        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        Section {
          Button {
            Task { await submit() }
          } label: {
            HStack {
              Spacer()
              if busy { ProgressView() } else { Text("Anmelden").bold() }
              Spacer()
            }
          }
          .disabled(!canSubmit)
        }
      }
      .navigationTitle("BlackShelf")
    }
  }

  private func submit() async {
    guard canSubmit else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      if method == .password {
        let r = try await ABSClient.shared.login(server: server, username: username, password: password)
        password = ""
        await app.didLogin(defaultLibraryId: r.userDefaultLibraryId)
      } else {
        try await ABSClient.shared.login(server: server, apiKey: apiKey)
        apiKey = ""
        await app.didLogin(defaultLibraryId: nil)
      }
    } catch let e as URLError {
      error = e.code == .notConnectedToInternet || e.code == .cannotConnectToHost || e.code == .timedOut
        ? "Server nicht erreichbar. Stimmt die Adresse und bist du im richtigen Netz?"
        : e.localizedDescription
    } catch {
      self.error = error.localizedDescription
    }
  }
}
