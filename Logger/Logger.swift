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
		logger.log("\(message)")
		LogManager.shared.writeLog(category: category, level: .default, message: message)
	}

	func info(_ message: String) {
		logger.info("\(message)")
		LogManager.shared.writeLog(category: category, level: .info, message: message)
	}

	func debug(_ message: String) {
		logger.debug("\(message)")
		LogManager.shared.writeLog(category: category, level: .debug, message: message)
	}

	func error(_ message: String) {
		logger.error("\(message)")
		LogManager.shared.writeLog(category: category, level: .error, message: message)
	}

	func fault(_ message: String) {
		logger.fault("\(message)")
		LogManager.shared.writeLog(category: category, level: .fault, message: message)
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
