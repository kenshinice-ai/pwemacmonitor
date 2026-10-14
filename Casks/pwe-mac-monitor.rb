# Homebrew cask for PWE Monitor (the token stays `pwe-mac-monitor` — it is an address).
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
  version "1.7.2"
  sha256 "c4b05bf21ef9780849a2f5cc1fa5f5e1f3a172782649e52890584e29f447cbe1"

  url "https://github.com/kenshinice-ai/pwemacmonitor/releases/download/v#{version}/PWE-MAC-MONITOR-#{version}.dmg"
  name "PWE Monitor"
  desc "Menu-bar hardware monitor for Apple Silicon Macs"
  homepage "https://github.com/kenshinice-ai/pwemacmonitor"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  # Renamed in 1.4.0. An upgrade from an older cask removes the old bundle, because Homebrew
  # uninstalls using the definition saved at install time — which still names the old app.
  app "PWE Monitor.app"

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
