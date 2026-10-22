# Homebrew cask for the tap simkinselgazar-rgb/tap.
cask "go-pray" do
  version "0.1.1"
  sha256 "3475834c3fb1ccb60ef290832fa05636b2f8c4bb22c6db82d11ab72565108f23"

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
