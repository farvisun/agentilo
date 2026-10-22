import AgentLimitsCore
import SwiftUI

struct ProxyTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Global proxy") {
                ProxyEditor(
                    config: $state.settings.globalProxy,
                    credentialKey: ProxyCredentialKey.global,
                    testURL: Provider.claude.probeURL,
                    onPasswordChange: state.proxyChanged
                )
            }
            ForEach(Provider.allCases) { p in
                Section(p.displayName) {
                    ProviderProxyEditor(state: state, provider: p)
                }
            }
            Section {
                Text("HTTP and HTTPS use CONNECT tunnels (HTTPS talks TLS to the proxy itself). SOCKS5 supports username and password. Passwords are kept in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProviderProxyEditor: View {
    @Bindable var state: AppState
    var provider: Provider

    private var binding: Binding<ProviderProxy> {
        Binding(
            get: { state.settings.providerProxy(provider) },
            set: { state.settings.providerProxies[provider.rawValue] = $0 }
        )
    }

    var body: some View {
        Toggle("Use global proxy", isOn: binding.useGlobal)
        if binding.wrappedValue.useGlobal {
            HStack {
                Text(state.settings.globalProxy.summary).foregroundStyle(.secondary)
                Spacer()
                ProxyTestButton(proxy: { state.settings.effectiveProxy(for: provider) }, url: provider.probeURL)
            }
        } else {
            ProxyEditor(
                config: binding.config,
                credentialKey: ProxyCredentialKey.provider(provider),
                testURL: provider.probeURL,
                onPasswordChange: state.proxyChanged
            )
        }
    }
}

struct ProxyEditor: View {
    @Binding var config: ProxyConfig
    var credentialKey: String
    var testURL: URL
    var onPasswordChange: () -> Void

    @State private var password = ""
    @State private var loaded = false

    var body: some View {
        Picker("Type", selection: $config.kind) {
            ForEach(ProxyKind.allCases) { Text($0.displayName).tag($0) }
        }
        .onChange(of: config.kind) { old, new in
            if new.needsServer && (!old.needsServer || config.port == old.defaultPort) { config.port = new.defaultPort }
        }
        if config.kind.needsServer {
            TextField("Host", text: $config.host, prompt: Text("127.0.0.1"))
            TextField("Port", value: $config.port, format: .number.grouping(.never))
            TextField("Username", text: $config.username, prompt: Text("optional"))
            SecureField("Password", text: $password, prompt: Text("optional"))
                .onSubmit(savePassword)
                .onChange(of: password) { _, _ in savePassword() }
                .disabled(config.username.isEmpty)
            if !config.isValid {
                Text("Enter a host and a port between 1 and 65535.").font(.caption).foregroundStyle(.red)
            }
        }
        HStack {
            Spacer()
            ProxyTestButton(
                proxy: { EffectiveProxy(config: config, password: config.username.isEmpty ? "" : password) },
                url: testURL
            )
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            password = config.username.isEmpty ? "" : KeychainStore.password(for: credentialKey)
        }
    }

    private func savePassword() {
        guard loaded else { return }
        KeychainStore.setPassword(password, for: credentialKey)
        onPasswordChange()
    }
}

struct ProxyTestButton: View {
    var proxy: () -> EffectiveProxy
    var url: URL
    @State private var running = false
    @State private var result: ProxyTestResult?

    var body: some View {
        HStack(spacing: 8) {
            if let result {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button {
                running = true
                result = nil
                let p = proxy()
                Task {
                    let r = await ProxyTester.test(p, url: url)
                    result = r
                    running = false
                }
            } label: {
                if running { ProgressView().controlSize(.small) } else { Text("Test connection") }
            }
            .disabled(running)
        }
    }
}
