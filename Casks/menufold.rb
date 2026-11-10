cask "menufold" do
  version "1.0"
  sha256 "cd58ad1908f5141bf9139af88471a429339a11d5b7a772855efa62741f081027"

  url "https://github.com/ploizides/MenuFold/releases/download/v#{version}/MenuFold.zip"
  name "MenuFold"
  desc "Fold away menu bar icons behind a toggle"
  homepage "https://github.com/ploizides/MenuFold"

  depends_on macos: :sonoma

  app "MenuFold.app"

  # The app isn't notarized by Apple; clear the download flag so it opens without the Gatekeeper prompt.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/MenuFold.app"],
        writable_paths: ["MenuFold.app"],
        writable_base:  :appdir
  end

  uninstall quit: "com.ploizides.menufold"

  zap trash: "~/Library/Preferences/com.ploizides.menufold.plist"
end
