# Draft cask for homebrew/homebrew-cask or a personal tap.
cask "magicquit" do
  version "2.0.1"
  sha256 :no_check

  url "https://github.com/johnyoonh/magicquit/releases/download/v#{version}/MagicQuit-#{version}.zip"
  name "MagicQuit"
  desc "Automatically quits apps that are idle or whose last window was closed"
  homepage "https://github.com/johnyoonh/magicquit"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "MagicQuit.app"

  zap trash: [
    "~/Library/Preferences/com.MagicQuit.plist",
    "~/Library/Application Support/MagicQuit",
  ]
end
