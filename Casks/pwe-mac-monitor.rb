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
  version "1.2.0"
  sha256 "b17666b326a2c4fdd0f258d1f74e750ca6c5adaece9fdacbf3ae67842f7740b9"

  url "https://github.com/kenshinice-ai/pwemacmonitor/releases/download/v#{version}/PWE-MAC-MONITOR-#{version}.dmg"
  name "PWE MAC MONITOR"
  desc "Menu-bar hardware monitor for Apple Silicon Macs"
  homepage "https://github.com/kenshinice-ai/pwemacmonitor"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "PWE MAC MONITOR.app"

  # This one lives in the menu bar and is therefore almost always running when an upgrade
  # arrives. Without this, brew replaces the bundle underneath the running process: the old
  # code keeps running, the menu bar keeps showing the old version, and the upgrade looks
  # like it silently did nothing.
  uninstall quit: "au.com.pwe.macmonitor"

  zap trash: [
    "~/Library/Caches/au.com.pwe.macmonitor",
    "~/Library/HTTPStorages/au.com.pwe.macmonitor",
    "~/Library/Preferences/au.com.pwe.macmonitor.plist",
  ]
end
