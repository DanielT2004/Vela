import Foundation
import os

/// Verbose, categorized logging for the MVP. Every pipeline step prints so we can watch
/// retrieval → compression → Gemini → response live in the Xcode console, and also lands in
/// the unified log (Console.app) via `os.Logger`.
enum Log {
    private static let subsystem = "com.vela.foodeditor"

    enum Category: String {
        case app      = "🍳 app"
        case video    = "🎞️ video"
        case compress = "🗜️ compress"
        case upload    = "📤 upload"
        case poll     = "⏳ poll"
        case gemini   = "🤖 gemini"
        case assembly = "🎬 assembly"
        case notif    = "🔔 notif"
    }

    static func log(_ category: Category, _ message: String) {
        print("[\(category.rawValue)] \(message)")
        os.Logger(subsystem: subsystem, category: category.rawValue)
            .log("\(message, privacy: .public)")
    }

    static func app(_ m: String)      { log(.app, m) }
    static func video(_ m: String)    { log(.video, m) }
    static func compress(_ m: String) { log(.compress, m) }
    static func upload(_ m: String)   { log(.upload, m) }
    static func poll(_ m: String)     { log(.poll, m) }
    static func gemini(_ m: String)   { log(.gemini, m) }
    static func assembly(_ m: String) { log(.assembly, m) }
    static func notif(_ m: String)    { log(.notif, m) }

    /// Pretty-print a large blob (e.g. the raw Gemini response) with clear fences so it's easy
    /// to spot in a busy console.
    static func blob(_ category: Category, _ title: String, _ body: String) {
        let fence = String(repeating: "─", count: 8)
        print("[\(category.rawValue)] \(fence) \(title) \(fence)")
        print(body)
        print("[\(category.rawValue)] \(fence) end \(title) \(fence)")
    }
}
