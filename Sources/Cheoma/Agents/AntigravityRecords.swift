import Foundation
import SQLite3

/// Antigravity CLI(agy)의 대화 기록: ~/.gemini/antigravity-cli/conversation_summaries.db (SQLite).
/// 대화마다 ID · 제목 · 작업 폴더(workspace_uris) · 마지막 시각이 있다. 하위 에이전트 대화(parent_conversation_id)는 뺀다.
/// 이어서 하기는 `agy --conversation <ID>` (agy 1.4.12, 11/2 확인)
enum AntigravityRecords {
    static func databasePath(home: String) -> String {
        home + "/.gemini/antigravity-cli/conversation_summaries.db"
    }

    /// since 뒤에 움직인 대화, 최근 것부터
    static func read(path: String, since: Date) -> [RecordedSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = """
        SELECT conversation_id, title, preview, last_modified_time, workspace_uris, status
        FROM conversation_summaries WHERE parent_conversation_id = '' ORDER BY last_modified_time DESC LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [RecordedSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            guard let date = parseDate(text(3)), date >= since else { continue }
            let title = text(1).isEmpty ? text(2) : text(1)
            result.append(RecordedSession(id: text(0), kind: .antigravity, cwd: workspace(text(4)),
                                          title: title.isEmpty ? nil : title, lastActivity: date, costUSD: nil,
                                          lastMessage: nil, isTurnComplete: text(5).hasSuffix("IDLE")))
        }
        return result
    }

    /// "2026-11-02 02:35:03.772847+00:00"
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd HH:mm:ssxxx"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text), date.timeIntervalSince1970 > 0 { return date }
        }
        return nil
    }

    /// ["file:///Users/me/app"] → "/Users/me/app"
    static func workspace(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
              let first = uris.first, let url = URL(string: first), url.isFileURL else { return nil }
        return url.path
    }
}
