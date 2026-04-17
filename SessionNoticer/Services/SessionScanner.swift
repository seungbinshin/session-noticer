import Foundation

struct SessionPidFile: Codable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Int64
}

class SessionScanner {
    private let sessionsDirectory: URL
    private let ttyCheck: (Int) -> Bool

    init(sessionsDirectory: URL? = nil, ttyCheck: @escaping (Int) -> Bool = TTYCheck.hasControllingTTY) {
        self.sessionsDirectory = sessionsDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        self.ttyCheck = ttyCheck
    }

    func discoverSessions() -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { parseAndValidate($0) }
    }

    private func parseAndValidate(_ file: URL) -> Session? {
        guard let data = try? Data(contentsOf: file),
              let pidFile = try? JSONDecoder().decode(SessionPidFile.self, from: data) else { return nil }
        guard kill(Int32(pidFile.pid), 0) == 0 else { return nil }
        guard ttyCheck(pidFile.pid) else { return nil }

        var session = Session(sessionId: pidFile.sessionId, pid: pidFile.pid, cwd: pidFile.cwd, transcriptPath: "")
        session.state = .running
        session.firstPrompt = extractFirstPrompt(sessionId: pidFile.sessionId, cwd: pidFile.cwd)
        return session
    }

    private func extractFirstPrompt(sessionId: String, cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return "" }

        for dir in projectDirs {
            let transcriptPath = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath) {
                return readFirstUserPrompt(from: transcriptPath)
            }
        }
        return ""
    }

    private func readFirstUserPrompt(from path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return "" }

        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let msg = (json["data"] as? [String: Any])?["message"] as? [String: Any],
               let innerMsg = msg["message"] as? [String: Any],
               let role = innerMsg["role"] as? String, role == "user" {
                if let content = innerMsg["content"] as? String {
                    let truncated = String(content.prefix(60))
                    return content.count > 60 ? truncated + "..." : truncated
                }
                if let contentArray = innerMsg["content"] as? [[String: Any]],
                   let firstText = contentArray.first(where: { $0["type"] as? String == "text" }),
                   let text = firstText["text"] as? String {
                    let truncated = String(text.prefix(60))
                    return text.count > 60 ? truncated + "..." : truncated
                }
            }
        }
        return ""
    }
}
