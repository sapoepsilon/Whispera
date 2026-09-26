import AppKit
import Testing

@testable import Whispera

struct SettingsWindowWidthTests {
	private let english = [
		"General", "Text Insertion", "Storage & Downloads", "File Transcription", "History", "Automation",
		"Benchmark", "Post-Processing", "Debug",
	]
	private let french = [
		"Général", "Insertion de texte", "Stockage et téléchargements", "Transcription de fichiers",
		"Historique", "Automatisation", "Banc d'essai", "Post-traitement", "Débogage",
	]
	private let spanish = [
		"General", "Inserción de texto", "Almacenamiento y descargas", "Transcripción de archivos",
		"Historial", "Automatización", "Pruebas de rendimiento", "Posprocesamiento", "Depuración",
	]

	@Test func englishKeepsTheDefaultWidth() {
		#expect(SettingsWindowWidth.required(forTabTitles: english) == SettingsWindowWidth.minimum)
	}

	/// At 880 pt the French toolbar pushed Debug into the disabled overflow menu.
	@Test func longerLanguagesWidenTheWindow() {
		let frenchWidth = SettingsWindowWidth.required(forTabTitles: french)
		let spanishWidth = SettingsWindowWidth.required(forTabTitles: spanish)
		#expect(frenchWidth > SettingsWindowWidth.minimum)
		#expect(spanishWidth > frenchWidth)
	}

	@Test func widthCoversEveryLabelAndTheSpacingBetweenThem() {
		let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let labels = spanish.reduce(CGFloat(0)) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width }
		let spacing = SettingsWindowWidth.itemSpacing * CGFloat(spanish.count - 1)
		#expect(SettingsWindowWidth.required(forTabTitles: spanish, font: font) >= labels + spacing)
	}
}
