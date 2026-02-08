class Easy < Formula
  desc "Claude Code voice interface — hands-free coding via iPhone + AirPods"
  homepage "https://github.com/dancinlife/easy"
  url "https://registry.npmjs.org/easy-server/-/easy-server-2.0.0.tgz"
  license "MIT"

  depends_on "node"

  def install
    system "npm", "install", *std_npm_args
    bin.install_symlink Dir["#{libexec}/bin/*"]
  end

  def caveats
    <<~EOS
      1. 최초 실행 시 OpenAI API 키를 입력하라는 프롬프트가 표시됩니다:
         easy

      2. 또는 환경변수로 설정:
         export OPENAI_API_KEY=sk-...

      3. QR 코드가 표시되면 iPhone Easy 앱으로 스캔하세요.

      설정 재입력: easy --setup
      새 페어링:   easy --new
    EOS
  end

  test do
    assert_match "Easy", shell_output("#{bin}/easy --help")
  end
end
