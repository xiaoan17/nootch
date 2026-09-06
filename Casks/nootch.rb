cask "nootch" do
  version "1.2.0"
  sha256 "633bab3d00aa386bcf7fc7d94dc3607013a125350507a261d5d4a977d5f78561"

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
