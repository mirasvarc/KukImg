cask "kuk" do
  version "1.2.0"
  sha256 "4b337ca8852419e09490160a46c0a2bdff69daf25a64fad7bf9fc75b1ba7d4a3"

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
    "~/Library/Containers/msvarc.KukImg",
  ]
end
