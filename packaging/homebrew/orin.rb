# Homebrew formula template for Orin. Do not edit the placeholders by hand:
# tools/render_homebrew.py fills @VERSION@ and the @SHA256_<platform>@ values from a release's SHA256SUMS
# (the release.yml "homebrew" job does that and pushes the result to HenrySchwerdt/homebrew-orin).
# See docs/install.md "Homebrew".
class Orin < Formula
  desc "Self-hosted language that compiles to C (experimental pre-release)"
  homepage "https://github.com/HenrySchwerdt/orin"
  version "@VERSION@"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/HenrySchwerdt/orin/releases/download/v#{version}/orin-#{version}-macos-arm64.tar.gz"
      sha256 "@SHA256_MACOS_ARM64@"
    end
    on_intel do
      url "https://github.com/HenrySchwerdt/orin/releases/download/v#{version}/orin-#{version}-macos-x86_64.tar.gz"
      sha256 "@SHA256_MACOS_X86_64@"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/HenrySchwerdt/orin/releases/download/v#{version}/orin-#{version}-linux-aarch64.tar.gz"
      sha256 "@SHA256_LINUX_AARCH64@"
    end
    on_intel do
      url "https://github.com/HenrySchwerdt/orin/releases/download/v#{version}/orin-#{version}-linux-x86_64.tar.gz"
      sha256 "@SHA256_LINUX_X86_64@"
    end
    # Orin compiles to C and calls `cc`. On macOS the Xcode command line tools provide it
    # (Homebrew itself requires them); on Linux there is no guaranteed compiler, so depend on gcc.
    depends_on "gcc"
  end

  def install
    # The tarball has one top-level directory; Homebrew strips it. Keep the whole package
    # (bin/ libexec/ lib/ share/ examples/ VERSION) together in libexec: bin/orin finds the
    # compiler and runtime relative to its own real path (it follows symlinks).
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/orin"
  end

  def caveats
    <<~EOS
      Orin compiles to C and needs a C compiler at run time.
      On macOS run `xcode-select --install` if you have not. Check the setup with:
        orin doctor
      Examples: #{opt_libexec}/examples
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/orin --version")
    (testpath/"hello.or").write <<~EOS
      function main(): void {
        console.log("Hello from Orin!");
      }
    EOS
    # On Linux use the gcc this formula depends on; on macOS the normal compiler shim.
    if OS.linux?
      gcc = Formula["gcc"]
      ENV["CC"] = (gcc.opt_bin/"gcc-#{gcc.version.major}").to_s
    end
    assert_equal "Hello from Orin!\n", shell_output("#{bin}/orin run #{testpath}/hello.or")
  end
end
