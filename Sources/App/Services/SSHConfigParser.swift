import Foundation

/// ~/.ssh/config 의 Host 항목 하나 (가져오기용)
struct SSHConfigEntry: Hashable, Identifiable {
    var alias: String
    var hostname: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?

    var id: String { alias }

    /// 가져올 때 만들 호스트. 접속은 `ssh <별칭>` 이므로 나머지 값은 표시용이다.
    func makeHost(group: String?) -> SSHHost {
        var host = SSHHost()
        host.sshConfigAlias = alias
        host.hostname = hostname ?? alias
        host.user = user
        host.port = port
        host.identityFile = identityFile
        host.jumpHost = proxyJump
        host.group = group
        return host
    }
}

/// OpenSSH 클라이언트 설정 파일에서 Host 별칭과 주요 값을 읽는다.
///
/// - `Host a b` 처럼 여러 별칭이 있으면 각각 항목이 된다. `*`, `?`, `!` 가 들어간 패턴은 건너뛴다.
/// - `키 값` 과 `키=값` 을 모두 읽고, 키는 대소문자를 가리지 않는다. 같은 키는 처음 값이 이긴다 (ssh 와 같음).
/// - `Include` 는 ~/.ssh 기준 상대 경로와 와일드카드를 지원한다. `Match` 블록은 건너뛴다.
enum SSHConfigParser {
    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// 파일을 읽어 항목을 돌려준다. 파일이 없으면 빈 배열.
    static func parseFile(at url: URL = defaultConfigURL) -> [SSHConfigEntry] {
        var seen = Set<String>()
        return parseFile(at: url, depth: 0, seenFiles: &seen)
    }

    static func parse(_ text: String, baseDirectory: URL? = nil) -> [SSHConfigEntry] {
        var seen = Set<String>()
        return parse(text, baseDirectory: baseDirectory ?? defaultConfigURL.deletingLastPathComponent(), depth: 0, seenFiles: &seen)
    }

    // MARK: - 내부

    private static func parseFile(at url: URL, depth: Int, seenFiles: inout Set<String>) -> [SSHConfigEntry] {
        let path = url.standardizedFileURL.path
        guard depth < 8, !seenFiles.contains(path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        seenFiles.insert(path)
        return parse(text, baseDirectory: defaultConfigURL.deletingLastPathComponent(), depth: depth, seenFiles: &seenFiles)
    }

    private static func parse(
        _ text: String,
        baseDirectory: URL,
        depth: Int,
        seenFiles: inout Set<String>
    ) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        /// 지금 읽고 있는 Host 블록의 항목 위치들 (Match 블록이면 nil)
        var current: [Int]? = []
        var inMatch = false

        for rawLine in text.components(separatedBy: .newlines) {
            guard let (key, value) = splitLine(rawLine) else { continue }

            switch key {
            case "host":
                inMatch = false
                current = []
                for pattern in words(value) where isPlainAlias(pattern) {
                    if let existing = entries.firstIndex(where: { $0.alias == pattern }) {
                        current?.append(existing)
                    } else {
                        entries.append(SSHConfigEntry(alias: pattern))
                        current?.append(entries.count - 1)
                    }
                }

            case "match":
                inMatch = true
                current = nil

            case "include":
                // Include 는 현재 위치에 파일 내용을 끼워 넣는 것과 같다. 여기서는 그 파일의 Host 항목을 더한다.
                guard !inMatch else { continue }
                for pattern in words(value) {
                    for url in expandInclude(pattern, baseDirectory: baseDirectory) {
                        for entry in parseFile(at: url, depth: depth + 1, seenFiles: &seenFiles)
                        where !entries.contains(where: { $0.alias == entry.alias }) {
                            entries.append(entry)
                        }
                    }
                }

            default:
                guard let indices = current, !indices.isEmpty else { continue }
                let first = words(value).first ?? value
                for index in indices {
                    apply(key: key, value: first, to: &entries[index])
                }
            }
        }
        return entries
    }

    /// 같은 키는 처음 값이 이긴다.
    private static func apply(key: String, value: String, to entry: inout SSHConfigEntry) {
        switch key {
        case "hostname" where entry.hostname == nil: entry.hostname = value
        case "user" where entry.user == nil: entry.user = value
        case "port" where entry.port == nil: entry.port = Int(value)
        case "identityfile" where entry.identityFile == nil: entry.identityFile = value
        case "proxyjump" where entry.proxyJump == nil: entry.proxyJump = value
        default: break
        }
    }

    /// "Key value", "Key=value", "Key = value" → (소문자 키, 값). 주석·빈 줄은 nil.
    private static func splitLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        let key = trimmed[..<separator].lowercased()
        var rest = trimmed[separator...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        let value = String(rest).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (key, value)
    }

    /// 공백으로 나누되 큰따옴표로 묶인 부분은 하나로 본다.
    private static func words(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for char in value {
            if char == "\"" {
                quoted.toggle()
            } else if (char == " " || char == "\t") && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func isPlainAlias(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
    }

    private static func expandInclude(_ pattern: String, baseDirectory: URL) -> [URL] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = baseDirectory.appendingPathComponent(path).path }

        guard path.contains("*") || path.contains("?") else { return [URL(fileURLWithPath: path)] }

        // 와일드카드는 마지막 경로 요소에서만 지원한다 (예: config.d/*)
        let directory = (path as NSString).deletingLastPathComponent
        let namePattern = (path as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let predicate = NSPredicate(format: "SELF LIKE %@", namePattern)
        return names.filter { predicate.evaluate(with: $0) }.sorted()
            .map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
    }
}
