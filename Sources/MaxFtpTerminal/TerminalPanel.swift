import AppKit
import MaxFtpCore
@preconcurrency import SwiftTerm
import SwiftUI

/// Panneau terminal : émulateur SwiftTerm + état de la session (connexion, fin, erreur).
public struct TerminalPanel: View {
    @State private var session: TerminalSession
    private let restart: @MainActor () -> TerminalSession

    /// `makeSession` est rappelé par « Rouvrir » pour repartir d'une session neuve.
    public init(makeSession: @escaping @MainActor () -> TerminalSession) {
        _session = State(initialValue: makeSession())
        restart = makeSession
    }

    public var body: some View {
        ZStack {
            TerminalEmulator(session: session)
                .id(ObjectIdentifier(session))
            switch session.state {
            case .idle, .running:
                EmptyView()
            case .connecting:
                ProgressView("Ouverture du shell…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            case .ended:
                overlay("Session terminée.", systemImage: "terminal")
            case .failed(let message):
                overlay(message, systemImage: "exclamationmark.triangle")
            }
        }
        .onDisappear {
            let session = session
            Task { await session.close() }
        }
    }

    private func overlay(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .multilineTextAlignment(.center)
            Button("Rouvrir") { session = restart() }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Pont AppKit ↔ SwiftUI autour de `SwiftTerm.TerminalView`.
private struct TerminalEmulator: NSViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        context.coordinator.view = view
        context.coordinator.startWhenSized()
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        weak var view: TerminalView?

        init(session: TerminalSession) {
            self.session = session
        }

        /// La taille réelle n'est connue qu'après la première mise en page.
        func startWhenSized() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let view else { return }
                let terminal = view.getTerminal()
                await session.start(columns: max(terminal.cols, 20), rows: max(terminal.rows, 5)) { [weak view] data in
                    view?.feed(byteArray: ArraySlice([UInt8](data)))
                }
                view.window?.makeFirstResponder(view)
            }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated { session.send(bytes) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(columns: newCols, rows: newRows) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
