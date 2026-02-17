class RalphLoop < Formula
  desc "Iterative Codex Ralph loop harness"
  homepage "https://github.com/discordwell/ralph-codex"
  head "https://github.com/discordwell/ralph-codex.git", branch: "main"

  depends_on "ripgrep"

  def install
    bin.install "scripts/ralph-loop.sh" => "ralph-loop"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/ralph-loop --help")
  end
end
