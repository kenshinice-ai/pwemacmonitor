# Homebrew cask for PWE MAC MONITOR.
#
# This file is ready to publish as a personal tap. To set one up:
#
#   gh repo create kenshinice-ai/homebrew-tap --public --clone
#   mkdir -p homebrew-tap/Casks && cp Casks/pwe-mac-monitor.rb homebrew-tap/Casks/
#   cd homebrew-tap && git add -A && git commit -m "Add pwe-mac-monitor" && git push
#
# People then install with:
#
#   brew install --cask kenshinice-ai/tap/pwe-mac-monitor
#
# Remember to update version and sha256 on every release.

cask "pwe-mac-monitor" do
  version "1.0.0"
  sha256 "5229307edd5b28880d353bf8fcb2b1e10dafa52d745837029fa51e4e26dce7f0"

  url "https://github.com/kenshinice-ai/pwemacbar/releases/download/v#{version}/PWE-MAC-MONITOR-#{version}.dmg"
  name "PWE MAC MONITOR"
  desc "Menu-bar hardware monitor for Apple Silicon Macs"
  homepage "https://github.com/kenshinice-ai/pwemacbar"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "PWE MAC MONITOR.app"

  zap trash: [
    "~/Library/Preferences/au.com.pwe.macmonitor.plist",
  ]
end
