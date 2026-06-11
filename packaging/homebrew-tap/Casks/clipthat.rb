cask "clipthat" do
  version "0.1.0"
  sha256 "fce2d0c99e87ec6984ffe9e247a96afda41c94f2fe36a6a4492700cbe31fb867"

  url "https://github.com/Bhavyaapple24-ai/clipthat/releases/download/v#{version}/ClipThat.zip"
  name "ClipThat"
  desc "Instant-replay game clipper for macOS — save the last 30s with a hotkey"
  homepage "https://github.com/Bhavyaapple24-ai/clipthat"

  # Build min is macOS 15 (Package.swift .macOS(.v15) + Info.plist LSMinimumSystemVersion 15.0).
  # NOTE: the README/site currently say 14.2+ — reconcile those before launch.
  depends_on macos: ">= :sequoia"

  app "ClipThat.app"

  # ClipThat ships un-notarized (no $99 Apple Developer membership yet). macOS quarantines
  # anything downloaded, which triggers the "app is damaged / can't be opened" wall. Stripping
  # the quarantine flag on the installed app makes it open cleanly. This postflight is only
  # permitted in a third-party tap like this one — never in homebrew-core.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ClipThat.app"]
  end

  zap trash: [
    "~/Library/Application Support/ClipThat",
    "~/Movies/ClipThat",
  ]
end
