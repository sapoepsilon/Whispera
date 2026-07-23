import Foundation
import XCTest

@testable import Whispera

@MainActor
final class FileDropHandlerIntegrationTests: XCTestCase {

	private var dropHandler: FileDropHandler!

	override func setUp() async throws {
		dropHandler = FileDropHandler(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
	}

	override func tearDown() async throws {
		dropHandler = nil
	}

	func testCanAcceptDirectURLProvider() {
		let provider = NSItemProvider(object: NSURL(string: "https://www.youtube.com/watch?v=rE1I2eOC1fk")!)
		let accepted = dropHandler.canAccept(DropInfo(providers: [provider]))
		XCTAssertTrue(accepted)
	}

	func testCanAcceptURLNameProviderFromBrowserDrag() {
		let provider = NSItemProvider(
			item: "https://www.youtube.com/watch?v=rE1I2eOC1fk" as NSString,
			typeIdentifier: "public.url-name"
		)
		let accepted = dropHandler.canAccept(DropInfo(providers: [provider]))
		XCTAssertTrue(accepted)
	}

	func testCanAcceptPlainTextURLProvider() {
		let provider = NSItemProvider(
			item: "https://www.youtube.com/watch?v=rE1I2eOC1fk" as NSString,
			typeIdentifier: "public.plain-text"
		)
		let accepted = dropHandler.canAccept(DropInfo(providers: [provider]))
		XCTAssertTrue(accepted)
	}
}
