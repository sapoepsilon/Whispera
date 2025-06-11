//
//  LlamaState.swift
//  Whispera
//
//  Created by Varkhuman Mac on 6/7/25.
//

import Foundation
import SwiftUI

struct Model: Identifiable {
	var id = UUID()
	var name: String
	var url: String
	var filename: String
	var status: String?
}

struct CommandResult: Identifiable {
	var id = UUID()
	var userRequest: String
	var generatedCommand: String
	var output: String
	var error: String?
	var executionTime: Date
	var success: Bool
}

@MainActor
@Observable class LlamaState {
	static let shared = LlamaState()
	var messageLog = ""
	var cacheCleared = false
	var downloadedModels: [Model] = []
	var undownloadedModels: [Model] = []
	var currentlyLoadedModel: String? = nil
	let NS_PER_S = 1_000_000_000.0
	
	// Model persistence
	@ObservationIgnored
	@AppStorage("selectedLLMModel") private var selectedLLMModel: String = ""
	
	// Auto-execution setting
	@ObservationIgnored
	@AppStorage("autoExecuteCommands") private var autoExecuteCommands: Bool = false
	
	// Command execution tracking
	var commandHistory: [CommandResult] = []
	var lastGeneratedCommand: String? = nil
	var isExecutingCommand = false
	
	// Command approval state
	var showCommandApproval = false
	var pendingCommand: String? = nil
	var pendingUserRequest: String? = nil
	
	private var llamaContext: LlamaContext?
	private var defaultModelUrl: URL? {
		Bundle.main.url(forResource: "ggml-model", withExtension: "gguf", subdirectory: "models")
		// Bundle.main.url(forResource: "llama-2-7b-chat", withExtension: "Q2_K.gguf", subdirectory: "models")
	}
	
	private init() {
		loadModelsFromDisk()
		loadDefaultModels()
		// Auto-load the saved model if available
		loadSavedModel()
	}
	
	private func loadModelsFromDisk() {
		do {
			let documentsURL = getDocumentsDirectory()
			let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
			
			// Filter to only include .gguf files
			let ggufModelURLs = modelURLs.filter { $0.pathExtension.lowercased() == "gguf" }
			
			for modelURL in ggufModelURLs {
				let modelName = modelURL.deletingPathExtension().lastPathComponent
				downloadedModels.append(Model(name: modelName, url: "", filename: modelURL.lastPathComponent, status: "downloaded"))
			}
		} catch {
			print("Error loading models from disk: \(error)")
		}
	}
	
	private func loadDefaultModels() {
		do {
			try loadModel(modelUrl: defaultModelUrl)
		} catch {
			messageLog += "Error!\n"
		}
		
		for model in defaultModels {
			let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
			if FileManager.default.fileExists(atPath: fileURL.path) {
				
			} else {
				var undownloadedModel = model
				undownloadedModel.status = "download"
				undownloadedModels.append(undownloadedModel)
			}
		}
	}
	
	func getDocumentsDirectory() -> URL {
		let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
		return paths[0]
	}
	private let defaultModels: [Model] = [
		Model(name: "TinyLlama-1.1B (Q4_0, 0.6 GiB)",url: "https://huggingface.co/TheBloke/TinyLlama-1.1B-1T-OpenOrca-GGUF/resolve/main/tinyllama-1.1b-1t-openorca.Q4_0.gguf?download=true",filename: "tinyllama-1.1b-1t-openorca.Q4_0.gguf", status: "download"),
		Model(
			name: "TinyLlama-1.1B Chat (Q8_0, 1.1 GiB)",
			url: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf?download=true",
			filename: "tinyllama-1.1b-chat-v1.0.Q8_0.gguf", status: "download"
		),
		
		Model(
			name: "TinyLlama-1.1B (F16, 2.2 GiB)",
			url: "https://huggingface.co/ggml-org/models/resolve/main/tinyllama-1.1b/ggml-model-f16.gguf?download=true",
			filename: "tinyllama-1.1b-f16.gguf", status: "download"
		),
		
		Model(
			name: "Phi-2.7B (Q4_0, 1.6 GiB)",
			url: "https://huggingface.co/ggml-org/models/resolve/main/phi-2/ggml-model-q4_0.gguf?download=true",
			filename: "phi-2-q4_0.gguf", status: "download"
		),
		
		Model(
			name: "Phi-2.7B (Q8_0, 2.8 GiB)",
			url: "https://huggingface.co/ggml-org/models/resolve/main/phi-2/ggml-model-q8_0.gguf?download=true",
			filename: "phi-2-q8_0.gguf", status: "download"
		),
		
		Model(
			name: "Mistral-7B-v0.1 (Q4_0, 3.8 GiB)",
			url: "https://huggingface.co/TheBloke/Mistral-7B-v0.1-GGUF/resolve/main/mistral-7b-v0.1.Q4_0.gguf?download=true",
			filename: "mistral-7b-v0.1.Q4_0.gguf", status: "download"
		),
		Model(
			name: "OpenHermes-2.5-Mistral-7B (Q3_K_M, 3.52 GiB)",
			url: "https://huggingface.co/TheBloke/OpenHermes-2.5-Mistral-7B-GGUF/resolve/main/openhermes-2.5-mistral-7b.Q3_K_M.gguf?download=true",
			filename: "openhermes-2.5-mistral-7b.Q3_K_M.gguf", status: "download"
		)
	]
	func loadModel(modelUrl: URL?) throws {
		if let modelUrl {
			messageLog += "Loading model...\n"
			llamaContext = try LlamaContext.create_context(path: modelUrl.path())
			messageLog += "Loaded model \(modelUrl.lastPathComponent)\n"
			currentlyLoadedModel = modelUrl.lastPathComponent
			
			// Save the loaded model for persistence
			selectedLLMModel = modelUrl.lastPathComponent
			
			// Assuming that the model is successfully loaded, update the downloaded models
			updateDownloadedModels(modelName: modelUrl.lastPathComponent, status: "downloaded")
		} else {
			messageLog += "Load a model from the list below\n"
			currentlyLoadedModel = nil
		}
	}
	
	
	private func updateDownloadedModels(modelName: String, status: String) {
		undownloadedModels.removeAll { $0.name == modelName }
	}
	
	
	func complete(text: String) async {
		guard let llamaContext else {
			messageLog += "Error: No model loaded. Please load a model first.\n"
			return
		}
		
		let t_start = DispatchTime.now().uptimeNanoseconds
		await llamaContext.completion_init(text: text)
		let t_heat_end = DispatchTime.now().uptimeNanoseconds
		let t_heat = Double(t_heat_end - t_start) / NS_PER_S
		
		messageLog += "\(text)"
		
		Task.detached {
			while await !llamaContext.is_done {
				let result = await llamaContext.completion_loop()
				await MainActor.run {
					self.messageLog += "\(result)"
				}
			}
			
			let t_end = DispatchTime.now().uptimeNanoseconds
			let t_generation = Double(t_end - t_heat_end) / self.NS_PER_S
			let tokens_per_second = Double(await llamaContext.n_len) / t_generation
			
			// Don't clear context - keep it for future completions
			// await llamaContext.clear()
			
			await MainActor.run {
				self.messageLog += """
					\n
					Done
					Heat up took \(t_heat)s
					Generated \(tokens_per_second) t/s\n
					"""
			}
		}
	}
	
	func bench() async {
		guard let llamaContext else {
			return
		}
		
		messageLog += "\n"
		messageLog += "Running benchmark...\n"
		messageLog += "Model info: "
		messageLog += await llamaContext.model_info() + "\n"
		
		let t_start = DispatchTime.now().uptimeNanoseconds
		let _ = await llamaContext.bench(pp: 8, tg: 4, pl: 1) // heat up
		let t_end = DispatchTime.now().uptimeNanoseconds
		
		let t_heat = Double(t_end - t_start) / NS_PER_S
		messageLog += "Heat up time: \(t_heat) seconds, please wait...\n"
		
		// if more than 5 seconds, then we're probably running on a slow device
		if t_heat > 5.0 {
			messageLog += "Heat up time is too long, aborting benchmark\n"
			return
		}
		
		let result = await llamaContext.bench(pp: 512, tg: 128, pl: 1, nr: 3)
		
		messageLog += "\(result)"
		messageLog += "\n"
	}
	
	func clear() async {
		guard let llamaContext else {
			return
		}
		
		await llamaContext.clear()
		messageLog = ""
	}
	
	/// Complete text with system prompt using chat template
	func completeWithSystemPrompt(systemMessage: String, userMessage: String) async {
		guard let llamaContext else {
			messageLog += "Error: No model loaded\n"
			return
		}
		
		// Only show user message for cleaner log
		messageLog += "\n💬 \(userMessage)\n"
		
		let t_start = DispatchTime.now().uptimeNanoseconds
		let response = await llamaContext.completeWithSystemPrompt(
			systemMessage: systemMessage, 
			userMessage: userMessage
		)
		let t_end = DispatchTime.now().uptimeNanoseconds
		
		let _ = Double(t_end - t_start) / NS_PER_S
		
		messageLog += response
		messageLog += "\n"
	}
	
	/// Generate bash command from user request
	func generateBashCommand(userRequest: String) async -> String? {
		guard let llamaContext else {
			messageLog += "Error: No model loaded\n"
			return nil
		}
		
		let systemPrompt = """
		You are a bash command generator for macOS. Your role is to output ONLY the bash command that accomplishes the user's request.
		Rules:
		1. Output ONLY the command, no explanations or markdown
		2. If unclear, output a clarifying question starting with "CLARIFY:"
		3. For dangerous operations, output "DANGEROUS:" followed by the command
		4. Use macOS-specific commands when appropriate
		5. Never output multiple commands unless using && or ;
		"""
		
		// Log the request in a cleaner format
		messageLog += "\n💬 \(userRequest)\n"
		
		let response = await llamaContext.completeWithSystemPrompt(
			systemMessage: systemPrompt,
			userMessage: userRequest
		)
		
		// Clean up the response - remove common LLM tokens and artifacts
		var cleanedCommand = response.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Remove common LLM end tokens
		let tokensToRemove = ["<|im_end|>", "<|im_start|>", "<|end|>", "<|assistant|>", "<|user|>", "<|system|>"]
		for token in tokensToRemove {
			cleanedCommand = cleanedCommand.replacingOccurrences(of: token, with: "")
		}
		
		// Remove any remaining angle bracket artifacts
		if let range = cleanedCommand.range(of: "<|") {
			cleanedCommand = String(cleanedCommand[..<range.lowerBound])
		}
		
		// Final trim
		cleanedCommand = cleanedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Store the generated command
		lastGeneratedCommand = cleanedCommand
		
		messageLog += "→ \(cleanedCommand)\n"
		
		return cleanedCommand
	}
	
	/// Execute a bash command safely
	func executeCommand(_ command: String) async -> CommandResult {
		isExecutingCommand = true
		defer { isExecutingCommand = false }
		
		// Log execution start with cleaner format
		messageLog += "⚡ Executing: \(command)\n"
		
		let process = Process()
		let pipe = Pipe()
		
		process.standardOutput = pipe
		process.standardError = pipe
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = ["-c", command]
		
		var output = ""
		var errorOutput = ""
		var success = false
		
		do {
			try process.run()
			
			// Set a timeout
			let timeoutQueue = DispatchQueue(label: "command.timeout")
			let timeoutItem = DispatchWorkItem {
				if process.isRunning {
					process.terminate()
					errorOutput = "Command timed out after 30 seconds"
				}
			}
			timeoutQueue.asyncAfter(deadline: .now() + 30, execute: timeoutItem)
			
			process.waitUntilExit()
			timeoutItem.cancel()
			
			// Read output
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			if let outputString = String(data: data, encoding: .utf8) {
				output = outputString
			}
			
			success = process.terminationStatus == 0
			
			if !success {
				errorOutput = "Command exited with status: \(process.terminationStatus)"
			}
			
		} catch {
			errorOutput = "Failed to execute command: \(error.localizedDescription)"
		}
		
		let result = CommandResult(
			userRequest: lastGeneratedCommand ?? command,
			generatedCommand: command,
			output: output,
			error: errorOutput.isEmpty ? nil : errorOutput,
			executionTime: Date(),
			success: success
		)
		
		// Add to history
		commandHistory.append(result)
		
		// Update message log with cleaner format
		if !output.isEmpty {
			messageLog += "📤 \(output)"
			if !output.hasSuffix("\n") {
				messageLog += "\n"
			}
		}
		if !errorOutput.isEmpty {
			messageLog += "❌ \(errorOutput)\n"
		}
		messageLog += success ? "✅ Done\n" : "❌ Failed\n"
		
		return result
	}
	
	/// Generate and execute bash command from user request
	func generateAndExecuteBashCommand(userRequest: String) async -> CommandResult? {
		guard let command = await generateBashCommand(userRequest: userRequest) else {
			return nil
		}
		
		// Check for clarification needed
		if command.hasPrefix("CLARIFY:") {
			let clarification = String(command.dropFirst(8)).trimmingCharacters(in: .whitespaces)
			messageLog += "❓ \(clarification)\n"
			return nil
		}
		
		// Check for dangerous command
		if command.hasPrefix("DANGEROUS:") {
			let actualCommand = String(command.dropFirst(10)).trimmingCharacters(in: .whitespaces)
			messageLog += "⚠️ Potentially dangerous: \(actualCommand)\n"
			// Always require approval for dangerous commands
			pendingCommand = actualCommand
			pendingUserRequest = userRequest
			showCommandApproval = true
			return nil
		}
		
		// Check auto-execution setting
		if autoExecuteCommands {
			// Execute immediately without approval
			return await executeCommand(command)
		} else {
			// Show approval dialog
			pendingCommand = command
			pendingUserRequest = userRequest
			showCommandApproval = true
			return nil
		}
	}
	
	/// Execute the pending command after approval
	func executeApprovedCommand() async -> CommandResult? {
		guard let command = pendingCommand else { return nil }
		
		// Clear approval state
		showCommandApproval = false
		let _ = pendingUserRequest ?? ""
		pendingCommand = nil
		pendingUserRequest = nil
		
		// Execute the command
		return await executeCommand(command)
	}
	
	/// Cancel the pending command
	func cancelPendingCommand() {
		showCommandApproval = false
		pendingCommand = nil
		pendingUserRequest = nil
	}
	
	/// Auto-load the previously saved model on startup
	private func loadSavedModel() {
		guard !selectedLLMModel.isEmpty else {
			print("📱 No saved LLM model to load")
			return
		}
		
		let savedModelURL = getDocumentsDirectory().appendingPathComponent(selectedLLMModel)
		
		if FileManager.default.fileExists(atPath: savedModelURL.path) {
			do {
				try loadModel(modelUrl: savedModelURL)
				print("✅ Auto-loaded saved model: \(selectedLLMModel)")
			} catch {
				print("❌ Failed to auto-load saved model \(selectedLLMModel): \(error.localizedDescription)")
				// Clear the invalid saved model
				selectedLLMModel = ""
			}
		} else {
			print("⚠️ Saved model file not found: \(selectedLLMModel)")
			// Clear the invalid saved model
			selectedLLMModel = ""
		}
	}
}
