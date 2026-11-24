import Foundation
import SwiftUI

// MARK: - 日志级别

enum BeansLogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case fatal = "FATAL"

    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case .fatal: return .red
        }
    }
}

// MARK: - 单条日志

struct BeansLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: BeansLogLevel
    let message: String
}

// MARK: - 全局日志中心

/// 全局日志中心：内存环形缓存（供 App 内查看）+ 文件持久化（Documents/BeansLogs/beans-日期.log，可导出分享）。
/// 任意线程可调用 log()，界面更新自动切回主线程。
final class BeansLogger: ObservableObject {
    static let shared = BeansLogger()

    /// 日志内容变动时递增，供日志页面刷新。内容本身通过 `entries` 按需读取，
    /// 不再每写一条就复制并广播整个数组。
    @Published private(set) var revision = 0

    private let maxEntries = 5000
    private let maxLogFileBytes = 10 * 1024 * 1024
    private let lock = NSLock()
    private var recentEntries: [BeansLogEntry] = []
    /// 文件写入统一放到后台串行队列，调用方（常在主线程）不再等待磁盘。
    private let writeQueue = DispatchQueue(label: "Beans.Logger.Write", qos: .utility)
    private var publishScheduled = false
    private var lastPublishAt = Date.distantPast

    /// 当前内存中的日志快照（时间正序）。
    var entries: [BeansLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return recentEntries
    }

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private init() {
        log("Beans Music 启动（版本 \(Self.appVersion)）", level: .info)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func dateString(_ date: Date) -> String {
        lineFormatter.string(from: date)
    }

    /// 记录一条日志（任意线程可调用）
    func log(_ message: String, level: BeansLogLevel = .debug) {
        let entry = BeansLogEntry(date: Date(), level: level, message: message)
        lock.lock()
        recentEntries.append(entry)
        // 超出上限时一次丢掉一批，避免每写一条都整体搬移数组。
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(maxEntries / 10)
        }
        lock.unlock()
        schedulePublish()
        writeQueue.async { [weak self] in
            self?.write(entry.line)
        }
    }

    /// 通知日志页面刷新；日志密集时最多每 0.4 秒发布一次。仅在主线程访问下面两个状态。
    private func schedulePublish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastPublishAt)
            if elapsed >= 0.4 {
                self.lastPublishAt = Date()
                self.revision &+= 1
            } else if !self.publishScheduled {
                self.publishScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.4 - elapsed)) { [weak self] in
                    guard let self else { return }
                    self.publishScheduled = false
                    self.lastPublishAt = Date()
                    self.revision &+= 1
                }
            }
        }
    }

    /// 全部日志文本（按时间正序）
    var fullText: String {
        lock.lock()
        let snapshot = recentEntries
        lock.unlock()
        return snapshot.map(\.line).joined(separator: "\n")
    }

    /// 清空内存日志与日志文件
    func clear() {
        lock.lock()
        recentEntries = []
        lock.unlock()
        // 等排队中的写入完成后再删文件，避免删完又被补写回来。
        writeQueue.sync {}
        try? FileManager.default.removeItem(at: logDirectory)
        DispatchQueue.main.async { [weak self] in
            self?.revision &+= 1
        }
        log("日志已清空", level: .info)
    }

    // MARK: - 文件持久化

    private var logDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var currentFileURL: URL {
        logDirectory.appendingPathComponent("beans-\(Self.fileStampFormatter.string(from: Date())).log")
    }

    /// 导出日志文件（不存在则先生成一份完整日志）
    func exportLogURL() -> URL {
        // 先等后台排队中的写入落盘，导出的文件才是完整的。
        writeQueue.sync {}
        let url = currentFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? fullText.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func write(_ line: String) {
        let url = currentFileURL
        // 单日日志过大时轮转到 .1，避免无限膨胀
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > maxLogFileBytes {
            let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

extension BeansLogEntry {
    var line: String {
        "[\(BeansLogger.dateString(date))] [\(level.rawValue)] \(message)"
    }
}

