//
//  Logger.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import Foundation
import SwiftUI
import os.log

struct ExtendedLogger {
	let logger: Logger
	let category: String

	func log(_ message: String) {
		let message = LogRedactor.redact(message)
		logger.log("\(message)")
		LogManager.shared.writeLog(category: category, level: .default, message: message)
	}

	func info(_ message: String) {
		let message = LogRedactor.redact(message)
		logger.info("\(message)")
		LogManager.shared.writeLog(category: category, level: .info, message: message)
	}

	func debug(_ message: String) {
		let message = LogRedactor.redact(message)
		logger.debug("\(message)")
		LogManager.shared.writeLog(category: category, level: .debug, message: message)
	}

	func error(_ message: String) {
		let message = LogRedactor.redact(message)
		logger.error("\(message)")
		LogManager.shared.writeLog(category: category, level: .error, message: message)
	}

	func fault(_ message: String) {
		let message = LogRedactor.redact(message)
		logger.fault("\(message)")
		LogManager.shared.writeLog(category: category, level: .fault, message: message)
	}
}

/// Defensively scrubs provider API keys from anything we log. A BYOK key should
/// never reach a log file, but a careless string interpolation elsewhere
/// shouldn't be able to leak one either. See WHI-40.
enum LogRedactor {
	private static let pattern = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9-_]{20,}")

	static func redact(_ message: String) -> String {
		guard let pattern else { return message }
		let range = NSRange(message.startIndex..., in: message)
		return pattern.stringByReplacingMatches(
			in: message, range: range, withTemplate: "sk-***REDACTED***")
	}
}

class AppLogger {
	static let shared = AppLogger()
	private let subsystem = Bundle.main.bundleIdentifier ?? "com.app.whispera"

	lazy var ui = ExtendedLogger(logger: Logger(subsystem: subsystem, category: "UI"), category: "UI")
	lazy var network = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "Network"), category: "Network")
	lazy var database = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "Database"), category: "Database")
	lazy var general = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "General"), category: "General")
	lazy var audioManager = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "AudioManager"), category: "AudioManager")
	lazy var transcriber = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "WhisperTranscriber"),
		category: "WhisperTranscriber")
	lazy var liveTranscriber = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "WhisperLiveTranscriber"),
		category: "WhisperLiveTranscriber")
	lazy var fileTranscriber = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "WhisperFileTranscriber"),
		category: "WhisperFileTranscriber")
	lazy var youtubeTranscriber = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "WhisperYouTubeTranscriber"),
		category: "WhisperYouTubeTranscriber")
	lazy var deviceManager = ExtendedLogger(
		logger: Logger(subsystem: subsystem, category: "AudioDeviceManager"),
		category: "AudioDeviceManager")

	private init() {
		let defaults = UserDefaults.standard
		if defaults.object(forKey: "enableExtendedLogging") == nil {
			defaults.set(true, forKey: "enableExtendedLogging")
		}
		if defaults.object(forKey: "enableDebugLogging") == nil {
			defaults.set(false, forKey: "enableDebugLogging")
		}
	}
}
