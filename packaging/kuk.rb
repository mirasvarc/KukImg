cask "kuk" do
  version "1.0.0"
  sha256 "PLACEHOLDER"

  url "https://github.com/mirasvarc/KukImg/releases/download/v#{version}/Kuk-v#{version}.zip"
  name "Kuk"
  desc "Fast, native macOS image viewer"
  homepage "https://github.com/mirasvarc/KukImg"

  depends_on macos: ">= :tahoe"

  app "Kuk.app"

  zap trash: [
    "~/Library/Containers/msvarc.KukImg",
  ]
end
