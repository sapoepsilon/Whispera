import SwiftUI
import llama
import Hub
import MarkdownUI

// MARK: - LLM Step
struct LlamaViewForOnboarding: View {
	var llamaState = LlamaState.shared
	@State private var multiLineText = ""
	@State private var showingHelp = false
	@State private var showCommandApproval = false
	@State private var pendingCommand: String? = nil
	
	var body: some View {
		VStack(spacing: 20) {
			// Title
//			VStack(spacing: 16) {
//				Image(systemName: "brain.head.profile.fill")
//					.font(.system(size: 48))
//					.foregroundColor(.purple)
//				
//				Text("Local LLM (Optional)")
//					.font(.system(.title, design: .rounded, weight: .semibold))
//				
//				Text("Test the local language model or skip this step.")
//					.font(.body)
//					.foregroundColor(.secondary)
//					.multilineTextAlignment(.center)
//			}
//			
			// Message log
			ScrollView {
				Markdown(llamaState.messageLog)
					.font(.system(size: 12))
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding()
			}
			.frame(height: 150)
			.background(Color.gray.opacity(0.1))
			.cornerRadius(8)
			
			// Input area
			VStack(alignment: .leading, spacing: 8) {
				TextEditor(text: $multiLineText)
					.frame(height: 80)
					.padding(8)
					.background(Color.gray.opacity(0.1))
					.cornerRadius(8)
					.overlay(
						RoundedRectangle(cornerRadius: 8)
							.stroke(Color.gray.opacity(0.3), lineWidth: 1)
					)
				
				// Example commands
				HStack(spacing: 8) {
					Text("Examples:")
						.font(.caption)
						.foregroundColor(.secondary)
					
					ForEach(["Open Developer folder", "Show system info", "List downloads"], id: \.self) { example in
						Button(example) {
							multiLineText = example
						}
						.font(.caption)
						.buttonStyle(.plain)
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(Color.blue.opacity(0.1))
						.cornerRadius(4)
					}
					
					Spacer()
				}
			}
			
			// Buttons
			HStack(spacing: 12) {
				Button("Send") {
					sendText()
				}
				.buttonStyle(PrimaryButtonStyle(isRecording: false))
				
				Button("Generate Command") {
					generateCommand()
				}
				.buttonStyle(SecondaryButtonStyle())
				.disabled(multiLineText.isEmpty)
				
				Button("Clear") {
					clear()
				}
				.buttonStyle(SecondaryButtonStyle())
			}
			
			// Command approval section
			if showCommandApproval, let command = pendingCommand {
				VStack(spacing: 12) {
					Divider()
					
					VStack(alignment: .leading, spacing: 8) {
						Text("Generated Command:")
							.font(.caption)
							.foregroundColor(.secondary)
						
						Text(command)
							.font(.system(.body, design: .monospaced))
							.padding()
							.background(Color.blue.opacity(0.1))
							.cornerRadius(8)
							.textSelection(.enabled)
					}
					
					HStack(spacing: 12) {
						Button("Execute") {
							executeCommand(command)
						}
						.buttonStyle(PrimaryButtonStyle(isRecording: false))
						
						Button("Cancel") {
							showCommandApproval = false
							pendingCommand = nil
						}
						.buttonStyle(SecondaryButtonStyle())
					}
				}
				.padding()
				.background(Color.orange.opacity(0.1))
				.cornerRadius(10)
			}
			
			// Execution status
			if llamaState.isExecutingCommand {
				HStack(spacing: 8) {
					ProgressView()
						.scaleEffect(0.8)
					Text("Executing command...")
						.font(.caption)
						.foregroundColor(.blue)
				}
				.padding()
				.background(Color.blue.opacity(0.1))
				.cornerRadius(8)
			}
			
			// Downloaded models section
			if !llamaState.downloadedModels.isEmpty {
				VStack(spacing: 12) {
					Divider()
					Text("Downloaded Models")
						.font(.headline)
					
					ForEach(llamaState.downloadedModels) { model in
						HStack {
							VStack(alignment: .leading, spacing: 4) {
								Text(model.name)
									.font(.subheadline)
									.lineLimit(1)
								
								Text(getModelSize(filename: model.filename))
									.font(.caption)
									.foregroundColor(.secondary)
							}
							
							Spacer()
							
							if isModelLoaded(model: model) {
								HStack(spacing: 8) {
									Image(systemName: "checkmark.circle.fill")
										.foregroundColor(.green)
									Text("Loaded")
										.font(.caption)
										.foregroundColor(.green)
								}
							} else {
								Button("Load") {
									loadModel(model)
								}
								.buttonStyle(SecondaryButtonStyle())
								.controlSize(.small)
							}
						}
						.padding(.vertical, 4)
					}
				}
				.padding(.top, 12)
			}
			
			// Download custom model section
			VStack(spacing: 12) {
				Divider()
				Text("Download Custom Model")
					.font(.headline)
				
				Text("To download from Hugging Face:")
					.font(.caption)
					.foregroundColor(.secondary)
				
				Text("1. Go to model page → Files tab")
					.font(.caption)
					.foregroundColor(.secondary)
				
				Text("2. Click on any .gguf file name")
					.font(.caption)
					.foregroundColor(.secondary)
				
				Text("3. Copy URL from address bar (blob URLs work!)")
					.font(.caption)
					.foregroundColor(.secondary)
				
				InputButton(llamaState: llamaState)
			}
			.padding(.top, 12)
			
			// Command History section
			if !llamaState.commandHistory.isEmpty {
				VStack(spacing: 12) {
					Divider()
					Text("Command History")
						.font(.headline)
					
					ScrollView {
						VStack(alignment: .leading, spacing: 8) {
							ForEach(llamaState.commandHistory.suffix(5)) { result in
								VStack(alignment: .leading, spacing: 4) {
									HStack {
										Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
											.foregroundColor(result.success ? .green : .red)
										Text(result.generatedCommand)
											.font(.system(.caption, design: .monospaced))
											.lineLimit(1)
									}
									if !result.output.isEmpty {
										Text(result.output)
											.font(.caption2)
											.foregroundColor(.secondary)
											.lineLimit(2)
									}
								}
								.padding(8)
								.background(Color.gray.opacity(0.1))
								.cornerRadius(6)
							}
						}
					}
					.frame(maxHeight: 100)
				}
				.padding(.top, 12)
			}
			
			Spacer()
		}
		.padding()
	}
	
	func sendText() {
		Task {
			// For general conversation, use the standard completion
			await llamaState.complete(text: multiLineText)
			multiLineText = ""
		}
	}
	
	func clear() {
		Task {
			await llamaState.clear()
		}
	}
	
	func testSystemPrompt() {
		Task {
			await llamaState.completeWithSystemPrompt(
				systemMessage: "You are a helpful AI assistant. Be concise and friendly.",
				userMessage: "What is the capital of France?"
			)
		}
	}
	
	func generateCommand() {
		Task {
			// Generate the bash command
			if let command = await llamaState.generateBashCommand(userRequest: multiLineText) {
				// Check if it's a clarification or dangerous command
				if command.hasPrefix("CLARIFY:") || command.hasPrefix("DANGEROUS:") {
					// These are handled in the LlamaState, just wait for user to see the message
					return
				}
				
				// Show command for approval
				pendingCommand = command
				showCommandApproval = true
			}
		}
	}
	
	func executeCommand(_ command: String) {
		showCommandApproval = false
		Task {
			let _ = await llamaState.executeCommand(command)
			pendingCommand = nil
		}
	}
	
	private func loadModel(_ model: Model) {
		Task {
			do {
				let fileURL = InputButton.getFileURL(filename: model.filename)
				try llamaState.loadModel(modelUrl: fileURL)
			} catch {
				print("Error loading model: \(error.localizedDescription)")
			}
		}
	}
	
	private func isModelLoaded(model: Model) -> Bool {
		return llamaState.currentlyLoadedModel == model.filename
	}
	
	private func getModelSize(filename: String) -> String {
		let fileURL = InputButton.getFileURL(filename: filename)
		
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
			if let fileSize = attributes[FileAttributeKey.size] as? Int64 {
				return formatFileSize(fileSize)
			}
		} catch {
			print("Error getting file size: \(error)")
		}
		
		return "Unknown size"
	}
	
	private func formatFileSize(_ bytes: Int64) -> String {
		let formatter = ByteCountFormatter()
		formatter.allowedUnits = [.useMB, .useGB]
		formatter.countStyle = .file
		return formatter.string(fromByteCount: bytes)
	}
}

struct InputButton: View {
    var llamaState: LlamaState
    @State private var inputLink: String = ""
    @State private var status: String = "download"
    @State private var filename: String = ""

    @State private var downloadTask: Task<Void, Never>?
    @State private var progress = 0.0

    private static func parseHuggingFaceURL(from link: String) -> (repoId: String, filename: String)? {
        // Convert blob URLs to resolve URLs and extract repo info
        let cleanLink = link.replacingOccurrences(of: "/blob/", with: "/resolve/")
        
        guard let url = URL(string: cleanLink),
              url.host?.contains("huggingface.co") == true else {
            return nil
        }
        
        let pathComponents = url.pathComponents
        // Expected format: /repoOwner/repoName/resolve/main/filename.gguf
        guard pathComponents.count >= 5,
              let repoOwnerIndex = pathComponents.firstIndex(where: { !$0.isEmpty && $0 != "/" }),
              repoOwnerIndex + 4 < pathComponents.count else {
            return nil
        }
        
        let repoOwner = pathComponents[repoOwnerIndex]
        let repoName = pathComponents[repoOwnerIndex + 1]
        let filename = pathComponents.last ?? ""
        
        guard filename.hasSuffix(".gguf") else {
            return nil
        }
        
        let repoId = "\(repoOwner)/\(repoName)"
        return (repoId, filename)
    }

    static func getFileURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    private func download() {
        guard let (repoId, filename) = InputButton.parseHuggingFaceURL(from: inputLink) else {
            status = "error"
            return
        }

        self.filename = filename
        let modelName = String(filename.dropLast(5)) // Remove .gguf extension
        let fileURL = InputButton.getFileURL(filename: filename)

        status = "downloading"
        print("Downloading model \(modelName) from \(repoId)/\(filename)")

        downloadTask = Task {
            do {
                let repo = Hub.Repo(id: repoId)
                let filesToDownload = [filename]
                
                let modelDirectory = try await Hub.snapshot(
                    from: repo,
                    matching: filesToDownload,
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.progress = progress.fractionCompleted
                        }
                    }
                )
                
                // Move the downloaded file to our desired location
                let downloadedFile = modelDirectory.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: downloadedFile.path) {
                    try FileManager.default.copyItem(at: downloadedFile, to: fileURL)
                }
                
                Task { @MainActor in
                    print("Writing to \(filename) completed")
                    llamaState.cacheCleared = false
                    
                    let model = Model(name: modelName, url: inputLink, filename: filename, status: "downloaded")
                    llamaState.downloadedModels.append(model)
                    status = "downloaded"
                }
                
            } catch {
                Task { @MainActor in
                    print("Download error: \(error.localizedDescription)")
                    status = "error"
                }
            }
        }
    }

    var body: some View {
        VStack {
            HStack {
                TextField("Paste direct .gguf file URL", text: $inputLink)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button(action: {
                    downloadTask?.cancel()
                    status = "download"
                }) {
                    Text("Cancel")
                }
            }

            if status == "download" {
                Button(action: download) {
                    Text("Download Custom Model")
                }
            } else if status == "downloading" {
                Button(action: {
                    downloadTask?.cancel()
                    status = "download"
                }) {
                    Text("Downloading \(Int(progress * 100))%")
                }
            } else if status == "downloaded" {
                Button(action: {
                    let fileURL = InputButton.getFileURL(filename: self.filename)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        download()
                        return
                    }
                    Task {
                        do {
                            try await llamaState.loadModel(modelUrl: fileURL)
                        } catch let err {
                            print("Error: \(err.localizedDescription)")
                        }
                    }
                }) {
                    Text("Load Custom Model")
                }
            } else if status == "error" {
                VStack {
                    Text("Invalid URL - must be direct link to .gguf file")
                        .foregroundColor(.red)
                        .font(.caption)
                    Button("Try Again") {
                        status = "download"
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("Unknown status")
            }
        }
        .onDisappear() {
            downloadTask?.cancel()
        }
        .onChange(of: llamaState.cacheCleared) { _, newValue in
            if newValue {
                downloadTask?.cancel()
                let fileURL = InputButton.getFileURL(filename: self.filename)
                status = FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download"
            }
        }
    }
}
