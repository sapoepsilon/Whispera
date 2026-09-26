cask "whispera" do
  version "1.3.2"
  sha256 "29a9f8d26f86a854d2e70d1716f5f1ac47be3d9ef5efa3473130843424fd0385"

  url "https://github.com/sapoepsilon/Whispera/releases/download/v#{version}/Whispera-#{version}.dmg"
  name "Whispera"
  desc "On-device Whisper dictation and file transcription"
  homepage "https://github.com/sapoepsilon/Whispera"

  livecheck do
    url "https://raw.githubusercontent.com/sapoepsilon/Whispera/main/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Whispera.app"

  uninstall quit: "com.macwhisper.app"

  zap trash: [
    "~/Library/Application Support/Whispera",
    "~/Library/Caches/com.macwhisper.app",
    "~/Library/HTTPStorages/com.macwhisper.app",
    "~/Library/HTTPStorages/com.macwhisper.app.binarycookies",
    "~/Library/Preferences/com.macwhisper.app.plist",
    "~/Library/Saved Application State/com.macwhisper.app.savedState",
  ]
end
