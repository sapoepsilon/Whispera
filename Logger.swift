//
//  Logger.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import Foundation
import os.log

class AppLogger {
	static let shared = AppLogger()
	private let subsystem = Bundle.main.bundleIdentifier ?? "com.app.whispera"
	
	lazy var ui = Logger(subsystem: subsystem, category: "UI")
	lazy var network = Logger(subsystem: subsystem, category: "Network")
	lazy var database = Logger(subsystem: subsystem, category: "Database")
	lazy var general = Logger(subsystem: subsystem, category: "General")
	lazy var audioManager = Logger(subsystem: subsystem, category: "AudioManager")
	lazy var transcriber = Logger(subsystem: subsystem, category: "WhisperTranscriber")
	lazy var liveTranscriber = Logger(subsystem: subsystem, category: "WhisperLiveTranscriber")
	
	private init() {}
}
