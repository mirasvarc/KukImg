cask "kuk" do
  version "1.3.0"
  sha256 "d38a963e422494a14b74b294b435af116345c0023e85a887f883916591707fbe"

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
