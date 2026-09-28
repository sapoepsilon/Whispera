cask "whispera" do
  version "1.4.0"
  sha256 "15f8989e74652e13b49ecee81c154688a4ec7857d6179d5a5fb49fd4ab5f19d6"

  url "https://github.com/sapoepsilon/Whispera/releases/download/v#{version}/Whispera-#{version}.dmg"
  name "Whispera"
  desc "On-device Whisper dictation and file transcription"
  homepage "https://github.com/sapoepsilon/Whispera"

  livecheck do
    url "https://raw.githubusercontent.com/sapoepsilon/Whispera/main/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Whispera.app"

  uninstall launchctl: "com.macwhisper.app",
            quit:      "com.macwhisper.app"

  zap trash: [
    "~/Library/Application Support/Whispera",
    "~/Library/Caches/com.macwhisper.app",
    "~/Library/HTTPStorages/com.macwhisper.app",
    "~/Library/HTTPStorages/com.macwhisper.app.binarycookies",
    "~/Library/LaunchAgents/com.macwhisper.app.plist",
    "~/Library/Preferences/com.macwhisper.app.plist",
    "~/Library/Saved Application State/com.macwhisper.app.savedState",
  ]

  caveats <<~EOS
    `brew uninstall --zap` leaves the Keychain items Whispera creates: post-processing
    API keys (service "com.macwhisper.app.post-processing") and the insertion script
    approval key (service "com.macwhisper.app.insertion-script"). Remove them in
    Keychain Access if you no longer need them.
  EOS
end
