# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "wotr"

require "minitest/autorun"

module GitRepoTestHelper
  def create_test_repo
    @tmpdir = Dir.mktmpdir("wotr-test-")
    system("git", "init", "-q", @tmpdir)
    system("git", "-C", @tmpdir, "config", "user.email", "test@test.com")
    system("git", "-C", @tmpdir, "config", "user.name", "Test User")
    File.write(File.join(@tmpdir, "README.md"), "# Test Repo")
    system("git", "-C", @tmpdir, "add", "README.md")
    system("git", "-C", @tmpdir, "commit", "-q", "-m", "Initial commit")
  end

  def cleanup_test_repo
    FileUtils.rm_rf(@tmpdir)
  end

  # Writes a .wotr/config containing only a teardown hook with the given bash body.
  # Resets @repo's memoized config so the hook is picked up immediately.
  def write_teardown_hook(body)
    FileUtils.mkdir_p(@repo.config_dir)
    indented_body = body.each_line.map { |l| "        #{l}" }.join
    File.write(File.join(@repo.config_dir, "config"),
      "hooks:\n  teardown:\n    - bg: |\n#{indented_body}")
    @repo.instance_variable_set(:@config, nil)
  end
end
