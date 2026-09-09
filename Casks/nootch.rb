cask "nootch" do
  version "1.3.4"
  sha256 "4ede70a46e5afd4029dd51bfa837ea5d3b2891c4fdbc0a764a8db4820c597737"

  url "https://github.com/xiaoan17/nootch/releases/download/v#{version}/nootch-#{version}.dmg"
  name "nootch"
  desc "Today's AI coding usage overlay, powered by vibecafe.ai (fork of DeepanshuMishraa/nootch)"
  homepage "https://github.com/xiaoan17/nootch"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "nootch.app"

  postflight do
    # This ad-hoc-signed app is not notarized. Only remove its quarantine flag.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/nootch.app"]
  end

  caveats <<~EOS
    nootch is not notarized. This cask removes quarantine from nootch.app,
    bypassing Gatekeeper's downloaded-app check for this app only.
    Gatekeeper remains enabled for other apps. Install only if you trust nootch.
  EOS
end
