cask "kuk" do
  version "1.6.0"
  sha256 "197aedb57cf57efc614699309fc5491cdc4d6c4cc9c5875a88c3689f10848e0f"

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
