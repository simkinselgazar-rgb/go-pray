# Homebrew cask for the tap simkinselgazar-rgb/tap.
cask "go-pray" do
  version "0.3.1"
  sha256 "442ad4ac26b5075fceba1166a58f184f907da2d86cb4996e7a64e9e216baf585"

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
