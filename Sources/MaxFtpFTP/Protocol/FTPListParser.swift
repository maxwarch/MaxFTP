import Foundation
import MaxFtpCore

/// Analyse des listings de répertoire FTP.
///
/// - `MLSD` (RFC 3659) : format machine, privilégié quand le serveur le supporte.
/// - `LIST` : format libre ; on gère le style Unix (`ls -l`) et le style DOS/IIS.
enum FTPListParser {
    // MARK: MLSD

    /// `type=file;size=1024;modify=20240131120000;UNIX.mode=0644; nom du fichier`
    static func parseMLSD(_ text: String, in directory: RemotePath) -> [RemoteItem] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let separator = line.range(of: "; ") ?? line.range(of: " ") else { return nil }
            let name = String(line[separator.upperBound...])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }

            var facts: [String: String] = [:]
            for fact in line[..<separator.lowerBound].split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                facts[pair[0].lowercased()] = String(pair[1])
            }

            let kind: RemoteItem.Kind
            switch facts["type"]?.lowercased() {
            case "cdir", "pdir": return nil
            case "dir": kind = .directory
            case "file": kind = .file
            case let type? where type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink"): kind = .symbolicLink
            default: kind = .other
            }

            return RemoteItem(
                path: directory.appending(name),
                kind: kind,
                size: facts["size"].flatMap { Int64($0) },
                modificationDate: facts["modify"].flatMap(parseMLSDTimestamp),
                permissions: facts["unix.mode"].flatMap { POSIXPermissions(octal: $0) },
                owner: facts["unix.owner"] ?? facts["unix.uid"],
                group: facts["unix.group"] ?? facts["unix.gid"]
            )
        }
    }

    /// `YYYYMMDDHHMMSS[.sss]`, toujours en UTC.
    static func parseMLSDTimestamp(_ value: String) -> Date? {
        let digits = value.prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func field(_ offset: Int, _ length: Int) -> Int {
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return Int(digits[start..<digits.index(start, offsetBy: length)]) ?? 0
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = field(0, 4)
        components.month = field(4, 2)
        components.day = field(6, 2)
        components.hour = field(8, 2)
        components.minute = field(10, 2)
        components.second = field(12, 2)
        return components.date
    }

    // MARK: LIST

    static func parseLIST(_ text: String, in directory: RemotePath, now: Date = Date()) -> [RemoteItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            return parseUnixLine(line, in: directory, now: now) ?? parseDOSLine(line, in: directory)
        }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `drwxr-xr-x  2 user group  4096 Jan 31 12:00 nom` ou `… Jan 31  2023 nom`.
    /// Le groupe peut être absent : on localise la date (mois jour heure|année) plutôt
    /// que de compter les colonnes.
    static func parseUnixLine(_ line: String, in directory: RemotePath, now: Date) -> RemoteItem? {
        guard let typeChar = line.first, "-dlbcps".contains(typeChar) else { return nil }
        let tokens = tokenRanges(line)
        guard tokens.count >= 6 else { return nil }

        // On cherche le mois à partir de la 4e colonne (perms, liens, owner, [group], size, MOIS…).
        guard let monthIndex = (3..<(tokens.count - 2)).first(where: { index in
            months.contains(line[tokens[index]].prefix(3).lowercased())
                && Int(line[tokens[index + 1]]).map { (1...31).contains($0) } == true
        }) else { return nil }

        let month = months.firstIndex(of: line[tokens[monthIndex]].prefix(3).lowercased())! + 1
        let day = Int(line[tokens[monthIndex + 1]])!
        let timeOrYear = String(line[tokens[monthIndex + 2]])
        var name = String(line[tokens[monthIndex + 2].upperBound...].drop(while: \.isWhitespace))
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var linkTarget: String?
        if typeChar == "l", let arrow = name.range(of: " -> ") {
            linkTarget = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }

        let kind: RemoteItem.Kind = switch typeChar {
        case "d": .directory
        case "l": .symbolicLink
        case "-": .file
        default: .other
        }

        let permissionText = String(line[tokens[0]].prefix(10))
        let owner = String(line[tokens[2]])
        let group = monthIndex >= 5 ? String(line[tokens[3]]) : nil

        return RemoteItem(
            path: directory.appending(name),
            kind: kind,
            size: Int64(line[tokens[monthIndex - 1]]),
            modificationDate: unixDate(month: month, day: day, timeOrYear: timeOrYear, now: now),
            permissions: POSIXPermissions(symbolic: permissionText),
            owner: owner,
            group: group,
            symbolicLinkTarget: linkTarget
        )
    }

    static func unixDate(month: Int, day: Int, timeOrYear: String, now: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents(month: month, day: day)
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            components.hour = parts[0]
            components.minute = parts[1]
            // Sans année : date des 6 derniers mois. Si elle tombe dans le futur, c'est l'an passé.
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year! -= 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }

    /// `01-31-24  03:45PM       <DIR>          dossier` / `01-31-2024  15:45   1234 fichier.txt`
    static func parseDOSLine(_ line: String, in directory: RemotePath) -> RemoteItem? {
        let tokens = tokenRanges(line)
        guard tokens.count >= 4 else { return nil }
        let dateParts = line[tokens[0]].split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }

        let sizeOrDir = line[tokens[2]]
        let isDirectory = sizeOrDir.uppercased() == "<DIR>"
        guard isDirectory || Int64(sizeOrDir) != nil else { return nil }
        let name = String(line[tokens[2].upperBound...].drop(while: \.isWhitespace))
        guard !name.isEmpty else { return nil }

        var components = DateComponents()
        components.month = dateParts[0]
        components.day = dateParts[1]
        components.year = dateParts[2] < 100 ? 2000 + dateParts[2] : dateParts[2]
        let time = line[tokens[1]].uppercased()
        let clock = time.filter { $0.isNumber || $0 == ":" }.split(separator: ":").compactMap { Int($0) }
        if clock.count == 2 {
            var hour = clock[0] % 12
            if time.hasSuffix("PM") { hour += 12 } else if !time.hasSuffix("AM") { hour = clock[0] }
            components.hour = hour
            components.minute = clock[1]
        }

        return RemoteItem(
            path: directory.appending(name),
            kind: isDirectory ? .directory : .file,
            size: isDirectory ? nil : Int64(sizeOrDir),
            modificationDate: Calendar(identifier: .gregorian).date(from: components)
        )
    }

    /// Plages des mots séparés par des espaces, pour conserver les espaces dans les noms.
    private static func tokenRanges(_ line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in line.indices {
            if line[index].isWhitespace {
                if let s = start { ranges.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<line.endIndex) }
        return ranges
    }
}
