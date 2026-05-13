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
    @Published var host: String = ""
    @Published var port: String = "14242"
    @Published var workspaceId: String = ""
    @Published var transcript: String = ""
    @Published var status: String = "Disconnected"
    @Published var isConnected: Bool = false
    @Published var pendingInput: String = ""

    private var session: FleetAttachSession?
    private var consumer: Task<Void, Never>?
    private let client: FleetAttachClient = URLSessionFleetAttachClient(
        session: URLSession(configuration: .ephemeral)
    )
    private static let maxTranscriptChars = 256 * 1024

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
        do {
            let newSession = try client.attach(
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
}

private struct PeerAttachDebugView: View {
    @ObservedObject var model: PeerAttachViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionForm
            statusLine
            transcript
            inputRow
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 480)
    }

    private var connectionForm: some View {
        HStack(spacing: 8) {
            TextField("Host (Tailscale IP)", text: $model.host)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isConnected)
                .frame(minWidth: 160)
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

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
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
        window.minSize = NSSize(width: 520, height: 420)
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
