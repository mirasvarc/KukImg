cask "kuk" do
  version "1.8.0"
  sha256 "e365327c8ecc3c1d3a1bb0fb841b7b594dcb2837fdfe3d04b987f118fe684d19"

  url "https://github.com/mirasvarc/KukImg/releases/download/v#{version}/Kuk-v#{version}.zip"
  name "Kuk"
  desc "Fast, native macOS image viewer"
  homepage "https://github.com/mirasvarc/KukImg"

  depends_on macos: ">= :tahoe"

  app "Kuk.app"

  # The app is not notarized — drop the quarantine flag so Gatekeeper
  # doesn't block the first launch (Homebrew 6 removed --no-quarantine).
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Kuk.app"]
  end

  zap trash: [
    "~/Library/Application Support/Kuk",
    "~/Library/Caches/Kuk",
    "~/Library/Caches/msvarc.KukImg",
    "~/Library/Containers/msvarc.KukImg",
    "~/Library/HTTPStorages/msvarc.KukImg",
    "~/Library/Preferences/msvarc.KukImg.plist",
  ]
end
