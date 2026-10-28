# Homebrew cask for the tap simkinselgazar-rgb/tap.
cask "go-pray" do
  version "0.3.3"
  sha256 "cb35d8463c178d5590f11c22b7a5021df6196ba32419b8430b10d55955baf491"

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
