cask "networkporteval" do
  version "REPLACE_ME"

  on_arm do
    sha256 "REPLACE_ARM64_SHA256"
    url "https://github.com/REPLACE_ME/NetworkPortEval/releases/download/v#{version}/NetworkPortEval-arm64.zip"
  end

  on_intel do
    sha256 "REPLACE_X86_64_SHA256"
    url "https://github.com/REPLACE_ME/NetworkPortEval/releases/download/v#{version}/NetworkPortEval-x86_64.zip"
  end

  name "NetworkPortEval"
  desc "Network evaluation utility for Mac devices"
  homepage "https://github.com/REPLACE_ME/NetworkPortEval"

  depends_on macos: ">= :tahoe"

  app "NetworkPortEval.app"
end
