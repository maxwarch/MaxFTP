import MaxFtpCore
@testable import MaxFtpSFTP
import Testing

@Suite("Commandes sudo SFTP")
struct SFTPSudoCommandTests {
    @Test func buildsQuotedRemoveCommands() {
        let path = RemotePath("/var/www/mon fichier/test'file.txt")

        let fileCmd = SFTPFileSystem.sudoRemoveFileCommand(at: path)
        #expect(fileCmd.contains("rm -f -- \"$1\" && echo __MAXFTP_OK__"))
        #expect(fileCmd.contains("'/var/www/mon fichier/test'\\''file.txt'"))

        let dirCmd = SFTPFileSystem.sudoRemoveDirectoryCommand(at: path)
        #expect(dirCmd.contains("rmdir -- \"$1\" && echo __MAXFTP_OK__"))
        #expect(dirCmd.contains("'/var/www/mon fichier/test'\\''file.txt'"))

        let treeCmd = SFTPFileSystem.sudoRemoveTreeCommand(at: path)
        #expect(treeCmd.contains("rm -rf -- \"$1\" && echo __MAXFTP_OK__"))
        #expect(treeCmd.contains("'/var/www/mon fichier/test'\\''file.txt'"))
    }

    @Test func buildsQuotedUploadCommand() {
        let source = RemotePath("/tmp/.maxftp-sudo-123")
        let destination = RemotePath("/etc/nginx/sites-enabled/default")

        let uploadCmd = SFTPFileSystem.sudoUploadCommand(source: source, destination: destination)
        #expect(uploadCmd.contains("cat \"$1\" > \"$2\" && echo __MAXFTP_OK__"))
        #expect(uploadCmd.contains("'/tmp/.maxftp-sudo-123'"))
        #expect(uploadCmd.contains("'/etc/nginx/sites-enabled/default'"))
    }
}
