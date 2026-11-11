import Foundation
import MaxFtpCore
import Testing

@Suite("Commandes shell")
struct ShellCommandTests {
    @Test func quotesForPOSIXShell() {
        #expect(ShellCommand.quote("/var/www") == "'/var/www'")
        #expect(ShellCommand.quote("l'été $HOME") == #"'l'\''été $HOME'"#)
    }

    @Test func changeDirectoryIsHiddenFromHistory() {
        #expect(ShellCommand.changeDirectory(to: "/srv/mon site") == " cd -- '/srv/mon site' && clear\n")
    }

    @Test func interactiveSSHWithPortKeyAndDirectory() {
        let configuration = ConnectionConfiguration(
            connectionProtocol: .sftp, host: "exemple.fr", port: 2222, username: "max",
            credential: .privateKey(URL(fileURLWithPath: "/Users/max/.ssh/id_ed25519"), passphrase: nil)
        )
        #expect(ShellCommand.interactiveSSH(configuration, at: "/var/www") == [
            "ssh", "-t", "-p", "2222", "-i", "/Users/max/.ssh/id_ed25519", "max@exemple.fr",
            #"cd -- '/var/www' && exec "$SHELL" -l"#,
        ])
        let plain = ConnectionConfiguration(connectionProtocol: .sftp, host: "h", username: "", credential: .password("x"))
        #expect(ShellCommand.interactiveSSH(plain, at: nil) == ["ssh", "-t", "h"])
    }

    @Test func terminalScriptQuotesEveryArgumentAndNeverContainsThePassword() {
        let configuration = ConnectionConfiguration(connectionProtocol: .sftp, host: "h", username: "u", credential: .password("secret"))
        let script = ShellCommand.terminalScript(configuration, at: "/a b")
        #expect(script.hasPrefix("#!/bin/sh\nrm -f -- \"$0\"\n"))
        #expect(script.contains(#"exec 'ssh' '-t' 'u@h' 'cd -- '\''/a b'\'' && exec "$SHELL" -l'"#))
        #expect(!script.contains("secret"))
    }

    @Test func onlySSHHasAShell() {
        #expect(ConnectionProtocol.sftp.supportsShell)
        #expect(!ConnectionProtocol.ftp.supportsShell)
        #expect(!ConnectionProtocol.s3.supportsShell)
    }
}
