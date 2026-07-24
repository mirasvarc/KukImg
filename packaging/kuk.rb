cask "kuk" do
  version "1.4.0"
  sha256 "ec86b5630a051dba907dc8f0071e594398569e8b607c9fe7c657fb128017aae0"

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
