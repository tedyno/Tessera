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
    @State private var color: String?
    @State private var mcpRead = false
    @State private var mcpWrite = false
    @State private var mcpWriteNoApproval = false
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
    /// Pick the tunnel from ~/.ssh/config instead of typing host/user/port/key.
    @State private var sshUseConfig = false
    @State private var sshAlias = ""
    @State private var sshConfigBlocks: [SSHConfigBlock] = []

    private enum SSHAuthKind: Hashable { case password, privateKey }

    @State private var tester = ConnectionTester()

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
        _color = State(initialValue: editing?.color)
        _mcpRead = State(initialValue: editing?.allowsMCPRead ?? false)
        _mcpWrite = State(initialValue: editing?.mcpWrite ?? false)
        _mcpWriteNoApproval = State(initialValue: editing?.mcpWriteWithoutApproval ?? false)
        if let ssh = editing?.ssh {
            _sshEnabled = State(initialValue: true)
            _sshUseConfig = State(initialValue: ssh.usesConfigAlias)
            _sshAlias = State(initialValue: ssh.configAlias ?? "")
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
                    LabeledContent("Colour") { colorPicker }
                    Toggle("Read-only (warn before writing)", isOn: $readOnly)
                    Toggle("MCP: allow reading (let a connected AI client query this connection)", isOn: $mcpRead)
                    Toggle("MCP: allow writing (asks you first)", isOn: $mcpWrite)
                        .disabled(!mcpRead || readOnly)
                        .padding(.leading, 16)
                    Toggle("MCP: writes don't need my approval", isOn: $mcpWriteNoApproval)
                        .disabled(!mcpRead || !mcpWrite || readOnly)
                        .padding(.leading, 32)
                    if mcpWriteNoApproval, mcpWrite, mcpRead, !readOnly {
                        Label("The client can INSERT, UPDATE, DELETE and run DDL on this "
                              + "connection with no prompt. Only do this on a database you "
                              + "can afford to lose, such as a local or test one.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 32)
                    }
                    if mcpRead {
                        Text(readOnly
                             ? "Read-only connections can never grant MCP write access."
                             : (mcpWrite
                                ? "The client may read, and may write or import after you approve each time."
                                : "The client may only read from this connection."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("SSH tunnel", isOn: $sshEnabled)
                    if sshEnabled {
                        Picker("Settings", selection: $sshUseConfig) {
                            Text("From ~/.ssh/config").tag(true)
                            Text("Enter manually").tag(false)
                        }
                        .pickerStyle(.segmented)

                        if sshUseConfig {
                            if sshAliases.isEmpty {
                                Text("No hosts found in ~/.ssh/config.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Picker("Host", selection: $sshAlias) {
                                    Text("—").tag("")
                                    ForEach(sshAliases, id: \.self) { Text($0).tag($0) }
                                }
                            }
                            if let resolved = resolvedAlias {
                                // Show what the alias expands to, so it isn't a black box.
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(resolved.user ?? NSUserName())@\(resolved.hostName):\(String(resolved.port ?? 22))")
                                        .font(.system(.caption, design: .monospaced))
                                    Text(resolved.identityFile.map { "key: \($0)" }
                                         ?? String(localized: "No IdentityFile — a password will be used."))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if resolvedAlias?.identityFile == nil, !sshAlias.isEmpty {
                                revealableField("SSH password", text: $sshPassword, reveal: $revealSSHPassword)
                            } else if !sshAlias.isEmpty {
                                SecureField("Key passphrase (optional)", text: $sshPassphrase)
                            }
                        } else {
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
            }
            .formStyle(.grouped)

            Divider()
            testStatus
            footer
        }
        // minHeight, not a fixed height: the sheet grows when the test results appear
        // rather than cramming them into the leftover pixels.
        .frame(minWidth: 560, maxWidth: 560, minHeight: 640)
        .onAppear {
            sshConfigBlocks = SSHConfigFile.loadDefault()
            // A brand-new connection defaults to the config when the user has one.
            if editing == nil, !sshAliases.isEmpty { sshUseConfig = true }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(tester.isRunning ? "Stop test" : "Test connection") {
                tester.isRunning ? tester.cancel() : tester.start(profile: makeProfile(), secrets: makeSecrets())
            }
            .disabled(!canSave)
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

    /// Stage-by-stage result, so a failure names the stage that broke.
    @ViewBuilder
    private var testStatus: some View {
        if !tester.states.isEmpty {
            // A failed stage can carry a long server message; let it wrap and scroll
            // instead of squeezing the stages into a couple of clipped lines.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                ForEach(ConnectionTester.Stage.allCases) { stage in
                    if case .skipped = tester.state(stage) {
                        EmptyView()
                    } else {
                        HStack(spacing: 6) {
                            stageIcon(tester.state(stage))
                            Text(stage.title).font(.caption.weight(.medium))
                            Text(stageDetail(tester.state(stage)))
                                .font(.caption)
                                .foregroundStyle(tester.state(stage).isFailure ? Color.red : .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func stageIcon(_ state: ConnectionTester.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary).font(.caption)
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }

    private func stageDetail(_ state: ConnectionTester.State) -> String {
        switch state {
        case .pending: String(localized: "Waiting…")
        case .skipped: ""
        case .running(let m), .ok(let m), .failed(let m): m
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

    private var sshAliases: [String] { SSHConfigFile.aliases(in: sshConfigBlocks) }

    /// What the chosen alias currently expands to, for the preview line.
    private var resolvedAlias: SSHConfigResolution? {
        guard sshUseConfig, !sshAlias.isEmpty else { return nil }
        return SSHConfigFile.resolve(sshAlias, in: sshConfigBlocks)
    }

    /// Swatches tagging the connection; the crossed-out one clears the colour.
    private var colorPicker: some View {
        HStack(spacing: 6) {
            Button {
                color = nil
            } label: {
                Image(systemName: "slash.circle")
                    .foregroundStyle(color == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help("No colour")

            ForEach(ConnectionPalette.names, id: \.self) { name in
                Button {
                    color = name
                } label: {
                    Circle()
                        .fill(ConnectionPalette.color(name) ?? .gray)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().strokeBorder(.primary, lineWidth: color == name ? 2 : 0)
                        }
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    private func makeProfile() -> ConnectionProfile {
        // With an alias the host/user/port/key are resolved at connect time; the
        // typed fields are kept as fallbacks for anything the config omits.
        let ssh: SSHConfig? = sshEnabled
            ? SSHConfig(
                host: sshHost, port: Int(sshPort) ?? 22, username: sshUser,
                authMethod: sshAuth == .password ? .password : .privateKey(path: sshKeyPath),
                configAlias: sshUseConfig && !sshAlias.isEmpty ? sshAlias : nil)
            : nil
        return ConnectionProfile(
            id: editing?.id ?? UUID(),
            name: name, kind: kind, host: host, port: Int(port),
            database: database, username: username, tlsMode: tlsMode, ssh: ssh, readOnly: readOnly,
            color: color,
            mcpRead: mcpRead, mcpWrite: mcpWrite,
            mcpWriteWithoutApproval: mcpWriteNoApproval)
    }

    /// Whether this tunnel authenticates with a password rather than a key — in
    /// alias mode that follows the resolved IdentityFile, not the manual picker.
    private var usesPassword: Bool {
        sshUseConfig ? (resolvedAlias?.identityFile == nil) : (sshAuth == .password)
    }

    private func makeSecrets() -> Secrets {
        Secrets(
            databasePassword: password.isEmpty ? nil : password,
            sshPassword: (sshEnabled && usesPassword && !sshPassword.isEmpty) ? sshPassword : nil,
            sshPassphrase: (sshEnabled && !usesPassword && !sshPassphrase.isEmpty) ? sshPassphrase : nil)
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

}
