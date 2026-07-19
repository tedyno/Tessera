import SwiftUI
import AppKit
import DBKit
import DBDriverPostgres
import DBDriverMySQL

/// Sheet for creating a connection profile. Saves connection parameters to the
/// profile store and the password/SSH secrets to the Keychain (via the caller).
struct NewConnectionView: View {
    let editing: ConnectionProfile?
    let onSave: (ConnectionProfile, Secrets) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: DatabaseKind = .postgres
    @State private var host = ""
    @State private var port = ""
    @State private var database = ""
    @State private var username = ""
    @State private var password = ""
    @State private var tlsMode: TLSMode = .prefer
    @State private var readOnly = false
    @State private var mcpAccess = false
    @State private var revealPassword = false

    @State private var sshEnabled = false
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUser = ""
    @State private var sshAuth: SSHAuthKind = .password
    @State private var sshPassword = ""
    @State private var sshKeyPath = "~/.ssh/id_ed25519"
    @State private var sshPassphrase = ""
    @State private var revealSSHPassword = false

    private enum SSHAuthKind: Hashable { case password, privateKey }

    private enum TestState: Equatable { case none, testing, ok(String), failed(String) }
    @State private var testState: TestState = .none

    init(editing: ConnectionProfile? = nil, secrets: Secrets = Secrets(),
         onSave: @escaping (ConnectionProfile, Secrets) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _kind = State(initialValue: editing?.kind ?? .postgres)
        _host = State(initialValue: editing?.host ?? "")
        _port = State(initialValue: editing.map { String($0.port) } ?? "")
        _database = State(initialValue: editing?.database ?? "")
        _username = State(initialValue: editing?.username ?? "")
        _password = State(initialValue: secrets.databasePassword ?? "")
        _tlsMode = State(initialValue: editing?.tlsMode ?? .prefer)
        _readOnly = State(initialValue: editing?.isReadOnly ?? false)
        _mcpAccess = State(initialValue: editing?.allowsMCPAccess ?? false)
        if let ssh = editing?.ssh {
            _sshEnabled = State(initialValue: true)
            _sshHost = State(initialValue: ssh.host)
            _sshPort = State(initialValue: String(ssh.port))
            _sshUser = State(initialValue: ssh.username)
            switch ssh.authMethod {
            case .password:
                _sshAuth = State(initialValue: .password)
                _sshPassword = State(initialValue: secrets.sshPassword ?? "")
            case .privateKey(let path):
                _sshAuth = State(initialValue: .privateKey)
                _sshKeyPath = State(initialValue: path)
                _sshPassphrase = State(initialValue: secrets.sshPassphrase ?? "")
            }
        }
    }

    private var canSave: Bool {
        !name.isEmpty && !host.isEmpty && !database.isEmpty && !username.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(editing == nil ? "New Connection" : "Edit Connection").font(.headline).padding(.top, 16)

            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(DatabaseKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("Host", text: $host)
                        TextField("Port", text: $port, prompt: Text("\(kind.defaultPort)"))
                            .frame(width: 80)
                    }
                    TextField("Database", text: $database)
                    TextField("User", text: $username)
                    revealableField("Password", text: $password, reveal: $revealPassword)
                    Picker("TLS", selection: $tlsMode) {
                        ForEach(TLSMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Read-only (warn before writing)", isOn: $readOnly)
                    Toggle("Allow MCP access (let Claude query this connection)", isOn: $mcpAccess)
                    if mcpAccess {
                        Text(readOnly
                             ? "MCP may read from this connection. Writes are refused because it is read-only."
                             : "MCP may read from this connection. Writes will ask you to confirm first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("SSH tunnel", isOn: $sshEnabled)
                    if sshEnabled {
                        HStack {
                            TextField("SSH host", text: $sshHost)
                            TextField("Port", text: $sshPort).frame(width: 80)
                        }
                        TextField("SSH user", text: $sshUser)
                        Picker("Auth", selection: $sshAuth) {
                            Text("Password").tag(SSHAuthKind.password)
                            Text("Private key").tag(SSHAuthKind.privateKey)
                        }
                        .pickerStyle(.segmented)
                        if sshAuth == .password {
                            revealableField("SSH password", text: $sshPassword, reveal: $revealSSHPassword)
                        } else {
                            HStack {
                                TextField("Key path", text: $sshKeyPath)
                                Button("Choose…") { chooseKeyFile() }
                            }
                            SecureField("Key passphrase (optional)", text: $sshPassphrase)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 540, height: 640)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Test connection") { runTest() }
                .disabled(!canSave || testState == .testing)
            testStatus
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") {
                onSave(makeProfile(), makeSecrets())
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(12)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .none: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let m):
            Label(m, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .failed(let m):
            Label(m, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(1)
        }
    }

    @ViewBuilder
    private func revealableField(_ title: String, text: Binding<String>, reveal: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            if reveal.wrappedValue {
                TextField(title, text: text)
            } else {
                SecureField(title, text: text)
            }
            Button { reveal.wrappedValue.toggle() } label: {
                Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show/hide")
        }
    }

    private func makeProfile() -> ConnectionProfile {
        let ssh: SSHConfig? = sshEnabled
            ? SSHConfig(
                host: sshHost, port: Int(sshPort) ?? 22, username: sshUser,
                authMethod: sshAuth == .password ? .password : .privateKey(path: sshKeyPath))
            : nil
        return ConnectionProfile(
            id: editing?.id ?? UUID(),
            name: name, kind: kind, host: host, port: Int(port),
            database: database, username: username, tlsMode: tlsMode, ssh: ssh, readOnly: readOnly,
            mcpAccess: mcpAccess)
    }

    private func makeSecrets() -> Secrets {
        Secrets(
            databasePassword: password.isEmpty ? nil : password,
            sshPassword: (sshEnabled && sshAuth == .password && !sshPassword.isEmpty) ? sshPassword : nil,
            sshPassphrase: (sshEnabled && sshAuth == .privateKey && !sshPassphrase.isEmpty) ? sshPassphrase : nil)
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Private Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyPath = url.path
        }
    }

    private func runTest() {
        testState = .testing
        let profile = makeProfile()
        let secrets = makeSecrets()
        Task {
            let driver: any DatabaseDriver = profile.kind == .postgres ? PostgresDriver() : MySQLDriver()
            do {
                try await driver.connect(
                    profile: profile, secrets: secrets,
                    endpoint: NetworkEndpoint(host: profile.host, port: profile.port))
                let version = (try? await driver.serverVersion()) ?? ""
                await driver.close()
                testState = .ok(version.isEmpty ? "Connection OK" : "\(profile.kind.displayName) \(version)")
            } catch {
                testState = .failed(String(describing: error).prefix(80).description)
            }
        }
    }
}
