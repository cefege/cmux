#if DEBUG
import AppKit
import CMUXFleet
import Foundation
import SwiftUI

/// Debug-only viewer for the fleet attach protocol. Lets you open a
/// `FleetAttachSession` against an arbitrary peer (host, port, workspace
/// id), dumps the decoded bytes into a scrollback view, and provides
/// an input field that ships keystrokes back through `sendInput`.
///
/// This isn't the final UX — eventually peer workspaces will mount as
/// real tabs with a Ghostty renderer. The window exists so the network
/// plumbing can be exercised end-to-end before the heavy
/// TerminalSurface integration lands.
@MainActor
final class PeerAttachViewModel: ObservableObject {
    @Published var host: String
    @Published var port: String
    @Published var workspaceId: String
    @Published var transcript: String = ""
    @Published var status: String = "Disconnected"
    @Published var isConnected: Bool = false
    @Published var pendingInput: String = ""
    @Published var availableWorkspaces: [RemoteWorkspace] = []
    @Published var listStatus: String = ""

    private var session: FleetAttachSession?
    private var consumer: Task<Void, Never>?
    // Tailscale CGNAT IPs (and even MagicDNS .ts.net names in some macOS
    // configurations) get bounced by ATS even with NSExceptionDomains
    // entries. NWFleetAttachClient talks raw NWConnection so ATS never
    // gets to see the URL. The HTTP /v1/workspaces probe still goes
    // through URLSession (covered by the ts.net exception) — if that
    // turns out to also fail we'll port it to NWConnection too.
    private let attachClient: FleetAttachClient = NWFleetAttachClient()
    private let httpClient: FleetClient = URLSessionFleetClient(
        session: URLSession(configuration: .ephemeral)
    )
    private static let maxTranscriptChars = 256 * 1024

    private enum DefaultsKey {
        static let host = "fleet.peerAttachDebug.host"
        static let port = "fleet.peerAttachDebug.port"
        static let workspaceId = "fleet.peerAttachDebug.workspaceId"
    }

    init() {
        let defaults = UserDefaults.standard
        self.host = defaults.string(forKey: DefaultsKey.host) ?? ""
        self.port = defaults.string(forKey: DefaultsKey.port) ?? "14242"
        self.workspaceId = defaults.string(forKey: DefaultsKey.workspaceId) ?? ""
    }

    func connect() {
        disconnect()
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkspace = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedWorkspace.isEmpty else {
            status = "Need host + workspaceId"
            return
        }
        guard let portValue = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              portValue > 0
        else {
            status = "Invalid port"
            return
        }
        persistDefaults()
        do {
            let newSession = try attachClient.attach(
                host: trimmedHost,
                port: portValue,
                workspaceId: trimmedWorkspace
            )
            session = newSession
            isConnected = true
            status = "Connecting…"
            appendTranscript("[connecting to \(trimmedHost):\(portValue) ws=\(trimmedWorkspace)]\n")
            startConsuming(session: newSession)
        } catch {
            status = "Connect failed: \(error)"
            appendTranscript("[error: \(error)]\n")
        }
    }

    func disconnect() {
        consumer?.cancel()
        consumer = nil
        session?.close()
        session = nil
        if isConnected {
            isConnected = false
            status = "Disconnected"
            appendTranscript("[disconnected]\n")
        }
    }

    /// Probe the multi-instance fleet port range on the entered host
    /// until one answers `/v1/hello`, then fetch `/v1/workspaces` from
    /// that port. Auto-fills `port` with whatever responded so the user
    /// doesn't need to know which slot the peer's cmux landed on
    /// (14242 if first instance, 14243 if there was a conflict, etc).
    /// Tailnet auth still applies — a foreign-tailnet peer returns 403.
    func listWorkspaces() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            listStatus = "Need host"
            return
        }
        let candidatePorts: [UInt16]
        if let preferred = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)),
           preferred > 0
        {
            // Try the manual entry first, then fall back across the
            // multi-instance range so a "wrong port" guess still
            // resolves automatically.
            var rest = Array(FleetPort.multiInstanceRange)
            rest.removeAll { $0 == preferred }
            candidatePorts = [preferred] + rest
        } else {
            candidatePorts = Array(FleetPort.multiInstanceRange)
        }
        listStatus = "Probing \(trimmedHost) on ports \(candidatePorts.map(String.init).joined(separator: ","))…"
        let httpClient = self.httpClient
        Task { [weak self] in
            for portValue in candidatePorts {
                // Hello first — confirms (a) something is listening,
                // (b) tailnet auth passes, (c) it's a cmux fleet peer.
                let hello: FleetHelloResponse?
                do {
                    hello = try await httpClient.hello(
                        host: trimmedHost,
                        port: portValue,
                        timeout: 1.5
                    )
                } catch {
                    hello = nil
                }
                guard let hello else { continue }
                do {
                    let response = try await httpClient.workspaces(
                        host: trimmedHost,
                        port: portValue,
                        timeout: 5
                    )
                    let summary =
                        "Found \(response.workspaces.count) workspace(s) on " +
                        "\(hello.displayName) @ :\(portValue)"
                    await MainActor.run {
                        guard let self = self else { return }
                        self.port = String(portValue)
                        self.availableWorkspaces = response.workspaces
                        self.listStatus = summary
                        self.persistDefaults()
                    }
                    return
                } catch {
                    await MainActor.run {
                        self?.listStatus = "Workspaces fetch on :\(portValue) failed: \(error)"
                    }
                    return
                }
            }
            await MainActor.run {
                self?.availableWorkspaces = []
                self?.listStatus = "No cmux fleet peer answered on \(trimmedHost)"
            }
        }
    }

    func selectWorkspace(_ workspace: RemoteWorkspace) {
        workspaceId = workspace.id
        persistDefaults()
    }

    func sendPendingInput() {
        guard let session = session else { return }
        let text = pendingInput
        guard !text.isEmpty else { return }
        pendingInput = ""
        let bytes = Data(text.utf8)
        Task { [weak self] in
            do {
                try await session.sendInput(bytes)
                await MainActor.run {
                    self?.appendTranscript("[sent \(bytes.count) bytes]\n")
                }
            } catch {
                await MainActor.run {
                    self?.appendTranscript("[send error: \(error)]\n")
                }
            }
        }
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        guard let session = session else { return }
        Task { [weak self] in
            do {
                try await session.sendResize(cols: cols, rows: rows)
                await MainActor.run {
                    self?.appendTranscript("[resize cols=\(cols) rows=\(rows)]\n")
                }
            } catch {
                await MainActor.run {
                    self?.appendTranscript("[resize error: \(error)]\n")
                }
            }
        }
    }

    private func startConsuming(session: FleetAttachSession) {
        consumer = Task { [weak self] in
            do {
                for try await event in session.events {
                    guard !Task.isCancelled else { break }
                    await MainActor.run { self?.handle(event: event) }
                }
                await MainActor.run {
                    self?.status = "Stream ended"
                    self?.isConnected = false
                }
            } catch {
                await MainActor.run {
                    self?.appendTranscript("[stream error: \(error)]\n")
                    self?.status = "Error"
                    self?.isConnected = false
                }
            }
        }
    }

    private func handle(event: FleetAttachEvent) {
        switch event {
        case .helloReceived(let workspaceId):
            status = "Attached to \(workspaceId)"
            appendTranscript("[hello workspace=\(workspaceId)]\n")
        case .outputReceived(let bytes):
            let chunk = bytes.map { byte -> String in
                if byte >= 0x20 && byte < 0x7F { return String(UnicodeScalar(byte)) }
                if byte == 0x0A { return "\n" }
                if byte == 0x0D { return "\r" }
                if byte == 0x09 { return "\t" }
                return String(format: "\\x%02X", byte)
            }.joined()
            appendTranscript(chunk)
        case .notFound(let workspaceId):
            status = "Workspace \(workspaceId) not found"
            appendTranscript("[not_found workspace=\(workspaceId)]\n")
            isConnected = false
        }
    }

    private func appendTranscript(_ text: String) {
        transcript.append(text)
        if transcript.count > Self.maxTranscriptChars {
            let overflow = transcript.count - Self.maxTranscriptChars
            transcript.removeFirst(overflow)
        }
    }

    private func persistDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: DefaultsKey.host)
        defaults.set(port, forKey: DefaultsKey.port)
        defaults.set(workspaceId, forKey: DefaultsKey.workspaceId)
    }
}

private struct PeerAttachDebugView: View {
    @ObservedObject var model: PeerAttachViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionForm
            workspacePicker
            statusLine
            transcript
            inputRow
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 540)
    }

    private var connectionForm: some View {
        HStack(spacing: 8) {
            TextField("Host (e.g. mihai-m1-eu.tailXXXXXX.ts.net)", text: $model.host)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isConnected)
                .frame(minWidth: 220)
            TextField("Port", text: $model.port)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isConnected)
                .frame(width: 70)
            TextField("Workspace UUID", text: $model.workspaceId)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isConnected)
            if model.isConnected {
                Button("Disconnect") { model.disconnect() }
            } else {
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var workspacePicker: some View {
        HStack(spacing: 8) {
            Button("List Workspaces") { model.listWorkspaces() }
                .disabled(model.isConnected)
            if !model.availableWorkspaces.isEmpty {
                Menu("Pick…") {
                    ForEach(model.availableWorkspaces, id: \.id) { workspace in
                        Button(action: { model.selectWorkspace(workspace) }) {
                            Text("\(workspace.name) — \(workspace.id.prefix(8))")
                        }
                    }
                }
                .disabled(model.isConnected)
            }
            Text(model.listStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Send 80x24 resize") {
                model.sendResize(cols: 80, rows: 24)
            }
            .disabled(!model.isConnected)
            .controlSize(.small)
        }
    }

    private var transcript: some View {
        ScrollView {
            Text(model.transcript)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Type and press Send to ship as input…", text: $model.pendingInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.sendPendingInput() }
                .disabled(!model.isConnected)
            Button("Send + LF") {
                model.pendingInput.append("\n")
                model.sendPendingInput()
            }
            .disabled(!model.isConnected)
            Button("Send") { model.sendPendingInput() }
                .disabled(!model.isConnected)
        }
    }
}

@MainActor
final class PeerAttachWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PeerAttachWindowController()
    private let model = PeerAttachViewModel()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Fleet Peer Attach"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.peerAttachDebug")
        window.minSize = NSSize(width: 560, height: 460)
        window.center()
        let rootView = PeerAttachDebugView(model: model)
        window.contentView = NSHostingView(rootView: rootView)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.disconnect()
    }
}
#endif
