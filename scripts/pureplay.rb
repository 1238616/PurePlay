cask "pureplay" do
  version "1.4.8"
  sha256 :no_check

  url "https://github.com/REPLACE_OWNER/pureplay/releases/download/v#{version}/PurePlay-#{version}-Installer.dmg"
  name "PurePlay"
  desc "macOS-native bit-perfect Hi-Res music player with Quark Cloud Drive support"
  homepage "https://github.com/REPLACE_OWNER/pureplay"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "PurePlay.app"

  zap trash: [
    "~/Library/Application Support/PurePlay",
    "~/Library/Caches/PurePlay",
    "~/Library/Preferences/com.pureplay.app.plist",
    "~/Library/Saved Application State/com.pureplay.app.savedState",
  ]
end
