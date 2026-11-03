import Foundation

#if canImport(AuthenticationServices)
	import AuthenticationServices
#endif

/// Shows the provider's sign-in page and returns the URL it redirected to.
/// Throws `AccountError.cancelled` when the user closes it.
public protocol WebAuthenticator: Sendable {
	func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
	/// `ASWebAuthenticationSession`, on iOS and macOS.
	///
	/// Ephemeral by default: no cookies shared with Safari, so signing out of
	/// Whispera really signs out and a second account is never silently reused.
	/// The host supplies the window the sheet hangs off (`UIWindow` on iOS,
	/// `NSWindow` on macOS), read on the main actor when the session starts.
	public final class SystemWebAuthenticator: WebAuthenticator, @unchecked Sendable {
		public typealias AnchorProvider = @MainActor @Sendable () -> ASPresentationAnchor

		public let prefersEphemeralSession: Bool
		private let anchor: AnchorProvider
		// Main actor only: the session must stay alive until it calls back.
		private var session: ASWebAuthenticationSession?
		private var contextProvider: ContextProvider?

		public init(prefersEphemeralSession: Bool = true, anchor: @escaping AnchorProvider) {
			self.prefersEphemeralSession = prefersEphemeralSession
			self.anchor = anchor
		}

		public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
					Task { @MainActor in
						self.start(url: url, callbackScheme: callbackScheme, continuation: continuation)
					}
				}
			} onCancel: {
				Task { @MainActor in self.session?.cancel() }
			}
		}

		@MainActor
		private func start(url: URL, callbackScheme: String, continuation: CheckedContinuation<URL, Error>) {
			let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
				Task { @MainActor in
					self?.session = nil
					self?.contextProvider = nil
				}
				if let callback {
					continuation.resume(returning: callback)
				} else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
					continuation.resume(throwing: AccountError.cancelled)
				} else {
					continuation.resume(throwing: AccountError.transport(error?.localizedDescription ?? "no callback"))
				}
			}
			let provider = ContextProvider(anchor: anchor())
			session.presentationContextProvider = provider
			session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
			self.session = session
			contextProvider = provider
			if !session.start() {
				self.session = nil
				contextProvider = nil
				continuation.resume(throwing: AccountError.transport("the sign-in sheet could not be shown"))
			}
		}

		private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
			let anchor: ASPresentationAnchor

			init(anchor: ASPresentationAnchor) {
				self.anchor = anchor
			}

			func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
				anchor
			}
		}
	}
#endif
