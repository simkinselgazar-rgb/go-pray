# Homebrew cask for the tap simkinselgazar-rgb/tap.
cask "go-pray" do
  version "0.2.1"
  sha256 "81754fff66cb375cd46aa4cc116dd92d6e871c1e78e9a0fc174062ff0832c343"

  url "https://github.com/simkinselgazar-rgb/go-pray/releases/download/v#{version}/GoPray-#{version}.dmg"
  name "Go Pray"
  desc "Pauses your Mac at each Athan until you have taken a real break"
  homepage "https://github.com/simkinselgazar-rgb/go-pray"

  depends_on macos: ">= :sonoma"

  app "Go Pray.app"

  # Stop the app and remove its login agent (SMAppService job), so nothing relaunches it.
  uninstall quit:      "com.ahmedelgazar.gopray",
            launchctl: "com.ahmedelgazar.gopray.agent"

  zap trash: [
    "~/Library/Application Support/GoPray",
    "~/Library/Caches/com.ahmedelgazar.gopray",
    "~/Library/Preferences/com.ahmedelgazar.gopray.plist",
  ]
end
