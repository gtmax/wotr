# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "claude/worktree"

require "minitest/autorun"

module GitRepoTestHelper
  def create_test_repo
    @tmpdir = Dir.mktmpdir("cwt-test-")
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
end
