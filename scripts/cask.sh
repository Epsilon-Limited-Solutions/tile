#!/usr/bin/env bash
# Print the Homebrew cask for a release: scripts/cask.sh <version> <sha256>
# The release workflow writes its output to Casks/tile.rb in Epsilon-Limited-Solutions/homebrew-tap.
set -euo pipefail
version="${1:?version}"
sha="${2:?sha256}"
cat <<RUBY
cask "tile" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/Epsilon-Limited-Solutions/tile/releases/download/v#{version}/Tile-#{version}.zip"
  name "Tile"
  desc "Window manager with layouts, display profiles and arrangements across desktops"
  homepage "https://github.com/Epsilon-Limited-Solutions/tile"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Tile.app"

  uninstall quit: "com.epsilonlimited.tile"

  zap trash: [
    "~/.config/tile",
    "~/Library/Logs/Tile",
  ]
end
RUBY
