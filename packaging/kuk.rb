cask "kuk" do
  version "1.1.0"
  sha256 "2016ee9be9e6f7ba1b6de955a2786a8b5524226081b306bb6eceb0c60dc6ce32"

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
