import Foundation
import MaxFtpCore
import MaxFtpTerminal
import MaxFtpTestSupport
import Testing

@MainActor
@Suite("Session de terminal")
struct TerminalSessionTests {
    /// Laisse tourner les tâches du main actor (lecture du flux, délai de fin de commande).
    func settle(_ duration: Duration = .milliseconds(80)) async {
        try? await Task.sleep(for: duration)
    }

    @Test func opensInInitialDirectoryAndShowsOutput() async {
        let shell = FakeShell()
        let session = TerminalSession(shell: shell, initialDirectory: "/var/www")
        var shown = ""
        await session.start(columns: 80, rows: 24) { shown += String(decoding: $0, as: UTF8.self) }
        #expect(session.state == .running)
        #expect(await shell.sentText == " cd -- '/var/www' && clear\n")

        await shell.emit("max@serveur:/var/www$ ")
        await settle()
        #expect(shown == "max@serveur:/var/www$ ")
    }

    @Test func commandCompletionIsSignaledOnceOutputSettles() async {
        let shell = FakeShell()
        var completions = 0
        let session = TerminalSession(shell: shell, initialDirectory: nil, settleDelay: .milliseconds(30)) { completions += 1 }
        await session.start(columns: 80, rows: 24) { _ in }

        // Sortie sans commande tapée (bannière) : pas d'actualisation.
        await shell.emit("Bienvenue\n$ ")
        await settle()
        #expect(completions == 0)

        session.send(Data("mkdir test\r".utf8))
        await shell.emit("$ ")
        await settle()
        #expect(completions == 1)

        // Une frappe sans Entrée ne déclenche rien.
        session.send(Data("l".utf8))
        await shell.emit("l")
        await settle()
        #expect(completions == 1)
    }

    @Test func endsWhenShellExits() async {
        let shell = FakeShell()
        let session = TerminalSession(shell: shell, initialDirectory: nil)
        await session.start(columns: 80, rows: 24) { _ in }
        await shell.finish()
        await settle()
        #expect(session.state == .ended)
    }

    @Test func reportsConnectionFailure() async {
        let session = TerminalSession(shell: FakeShell(failure: RemoteError.authenticationFailed(nil)), initialDirectory: nil)
        await session.start(columns: 80, rows: 24) { _ in }
        #expect(session.state == .failed(RemoteError.authenticationFailed(nil).localizedDescription))
    }

    @Test func closeShutsTheShell() async {
        let shell = FakeShell()
        let session = TerminalSession(shell: shell, initialDirectory: nil)
        await session.start(columns: 80, rows: 24) { _ in }
        await session.close()
        #expect(await shell.isClosed)
        #expect(session.state == .ended)
    }
}
