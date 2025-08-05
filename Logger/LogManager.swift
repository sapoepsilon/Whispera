//
//  LogManager.swift
//  Whispera
//
//  Created on 8/1/25.
//
import Foundation
import os.log

class LogManager {
    static let shared = LogManager()
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    private let fileManager = FileManager.default
    private let maxLogFileSize: Int64 = 10 * 1024 * 1024 // 10MB
    
    private var logFileHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "com.whispera.logging", qos: .utility)
    
    var logsDirectory: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Whispera/Logs")
    }
    
    var currentLogFile: URL? {
        guard let logsDir = logsDirectory else { return nil }
        let fileName = "whispera-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).log"
        return logsDir.appendingPathComponent(fileName)
    }
    
    private init() {
        setupLogsDirectory()
        rotateLogsIfNeeded()
        setupCrashHandlers()
    }
    
    private func setupLogsDirectory() {
        guard let logsDir = logsDirectory else { return }
        
        do {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create logs directory: \(error)")
        }
    }
    
    private func rotateLogsIfNeeded() {
        guard let logFile = currentLogFile else { return }
        
        do {
            if fileManager.fileExists(atPath: logFile.path) {
                let attributes = try fileManager.attributesOfItem(atPath: logFile.path)
                if let fileSize = attributes[.size] as? Int64, fileSize > maxLogFileSize {
                    // Archive the current log file
                    let archiveName = logFile.deletingPathExtension().lastPathComponent + "-\(Date().timeIntervalSince1970).log"
                    let archiveURL = logFile.deletingLastPathComponent().appendingPathComponent(archiveName)
                    try fileManager.moveItem(at: logFile, to: archiveURL)
                }
            }
        } catch {
            print("Failed to rotate logs: \(error)")
        }
    }
    
    func writeLog(category: String, level: OSLogType, message: String) {
        guard UserDefaults.standard.bool(forKey: "enableExtendedLogging") else {
            return
        }
        
        // Check if we should log based on level
        let debugMode = UserDefaults.standard.bool(forKey: "enableDebugLogging")
        if !debugMode && level == .debug {
            return // Skip debug logs when debug mode is off
        }
        
        logQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.rotateLogsIfNeeded()
            
            let timestamp = self.dateFormatter.string(from: Date())
            let levelString = self.logLevelString(for: level)
            let logEntry = "[\(timestamp)] [\(levelString)] [\(category)] \(message)\n"
            
            guard let logFile = self.currentLogFile,
                  let data = logEntry.data(using: .utf8) else { return }
            
            do {
                if !self.fileManager.fileExists(atPath: logFile.path) {
                    self.fileManager.createFile(atPath: logFile.path, contents: nil)
                }
                
                if self.logFileHandle == nil {
                    self.logFileHandle = try FileHandle(forWritingTo: logFile)
                    self.logFileHandle?.seekToEndOfFile()
                }
                
                self.logFileHandle?.write(data)
                
                #if DEBUG
                // Force flush in debug mode for immediate visibility
                self.logFileHandle?.synchronizeFile()
                #endif
            } catch {
                print("Failed to write log: \(error)")
                self.logFileHandle = nil
            }
        }
    }
    
    private func logLevelString(for level: OSLogType) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "DEFAULT"
        }
    }
    
    func closeLogFile() {
        logQueue.sync {
            logFileHandle?.closeFile()
            logFileHandle = nil
        }
    }
    
    func getLogFiles() -> [URL] {
        guard let logsDir = logsDirectory else { return [] }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.fileSizeKey])
            return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            return []
        }
    }
    
    func calculateLogsSize() -> Int64 {
        guard let logsDir = logsDirectory else { return 0 }
        
        var totalSize: Int64 = 0
        
        do {
            let files = try fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.fileSizeKey])
            
            for file in files where file.pathExtension == "log" {
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = attributes.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        } catch {
            print("Failed to calculate logs size: \(error)")
        }
        
        return totalSize
    }
    
    func clearAllLogs() throws {
        closeLogFile()
        
        guard let logsDir = logsDirectory else { return }
        
        let files = try fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "log" {
            try fileManager.removeItem(at: file)
        }
    }
    
    private func setupCrashHandlers() {
        // Set up exception handler for uncaught exceptions (Objective-C style)
        NSSetUncaughtExceptionHandler { exception in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let crashInfo = """
            === EXCEPTION CRASH REPORT ===
            Timestamp: \(timestamp)
            Exception Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "Unknown")
            
            Call Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            
            User Info:
            \(exception.userInfo ?? [:])
            ===================
            """
            
            LogManager.writeCrashLog(crashInfo)
        }
        
        // Set up signal handlers for lower-level crashes
        let crashHandler: @convention(c) (Int32) -> Void = { signal in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let signalName: String
            switch signal {
            case SIGABRT: signalName = "SIGABRT (Abort)"
            case SIGSEGV: signalName = "SIGSEGV (Segmentation fault)"
            case SIGBUS: signalName = "SIGBUS (Bus error)"
            case SIGILL: signalName = "SIGILL (Illegal instruction)"
            case SIGFPE: signalName = "SIGFPE (Floating point exception)"
            case SIGTRAP: signalName = "SIGTRAP (Trace trap)"
            default: signalName = "Signal \(signal)"
            }
            
            let crashInfo = """
            === SIGNAL CRASH REPORT ===
            Timestamp: \(timestamp)
            Signal: \(signalName)
            
            Note: Stack trace not available for signal crashes.
            Check system crash reports at:
            ~/Library/Logs/DiagnosticReports/
            /Library/Logs/DiagnosticReports/
            ===================
            """
            
            LogManager.writeCrashLog(crashInfo)
        }
        
        signal(SIGABRT, crashHandler)
        signal(SIGSEGV, crashHandler)
        signal(SIGBUS, crashHandler)
        signal(SIGILL, crashHandler)
        signal(SIGFPE, crashHandler)
        signal(SIGTRAP, crashHandler)
    }
    
    // Static method to write crash logs safely from signal handlers
    private static func writeCrashLog(_ crashInfo: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] [ERROR] [CrashHandler] 💥 CRASH: \(crashInfo)\n"
        
        if let logFile = LogManager.shared.currentLogFile,
           let data = logEntry.data(using: .utf8) {
            do {
                if !FileManager.default.fileExists(atPath: logFile.path) {
                    FileManager.default.createFile(atPath: logFile.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logFile)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } catch {
                // Last resort - write to stderr
                fputs(logEntry, stderr)
                fflush(stderr)
            }
        }
    }
    
    deinit {
        closeLogFile()
    }
}