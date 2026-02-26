# frozen_string_literal: true

require "test_helper"
require "cwt/repository"
require "tmpdir"
require "fileutils"

module Cwt
  class TestRepository < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir("cwt-test-")
      @original_dir = Dir.pwd
      Dir.chdir(@tmpdir)

      # Initialize a git repo with an initial commit
      system("git init -q")
      system("git config user.email 'test@test.com'")
      system("git config user.name 'Test User'")
      File.write("README.md", "# Test Repo")
      system("git add README.md")
      system("git commit -q -m 'Initial commit'")
    end

    def teardown
      Dir.chdir(@original_dir)
      FileUtils.rm_rf(@tmpdir)
    end

    def test_discover_finds_repo_root
      repo = Repository.discover

      assert_instance_of Repository, repo
      # Use realpath for macOS /var -> /private/var symlink
      assert_equal File.realpath(@tmpdir), File.realpath(repo.root)
    end

    def test_discover_from_subdir_returns_root
      FileUtils.mkdir_p("subdir/nested")
      Dir.chdir("subdir/nested")

      repo = Repository.discover

      assert_instance_of Repository, repo
      assert_equal File.realpath(@tmpdir), File.realpath(repo.root)
    end

    def test_discover_from_worktree_returns_main_root
      # Create a worktree
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("test-wt")
      assert result[:success]

      # Discover from inside worktree should return main repo root
      Dir.chdir(result[:worktree].path) do
        discovered = Repository.discover
        assert_equal File.realpath(@tmpdir), File.realpath(discovered.root)
      end
    end

    def test_discover_returns_nil_outside_git_repo
      Dir.mktmpdir do |non_git_dir|
        Dir.chdir(non_git_dir) do
          repo = Repository.discover
          assert_nil repo
        end
      end
    end

    def test_worktrees_returns_worktree_objects
      repo = Repository.new(@tmpdir)
      worktrees = repo.worktrees

      assert_instance_of Array, worktrees
      assert worktrees.all? { |wt| wt.is_a?(Worktree) }
      # Should have at least main worktree
      assert worktrees.size >= 1
    end

    def test_create_worktree_returns_worktree_object
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("test-session")

      assert result[:success]
      assert_instance_of Worktree, result[:worktree]
      assert_equal "test-session", result[:worktree].name
      assert_equal "test-session", result[:worktree].branch
    end

    def test_create_worktree_sanitizes_name
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("test session!")

      assert result[:success]
      assert_equal "test_session_", result[:worktree].name
    end

    def test_create_worktree_with_slashes
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("feat/implement-foo")

      assert result[:success]
      assert_equal "feat/implement-foo", result[:worktree].name
      assert_equal "feat/implement-foo", result[:worktree].branch
      assert Dir.exist?(File.join(@tmpdir, ".worktrees", "feat", "implement-foo"))
    end

    def test_create_worktree_sanitizes_consecutive_slashes
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("feat//double-slash")

      assert result[:success]
      assert_equal "feat/double-slash", result[:worktree].name
    end

    def test_find_worktree_by_branch_name
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("feat/find-branch")
      assert result[:success]

      found = repo.find_worktree("feat/find-branch")
      assert_instance_of Worktree, found
      assert_equal "feat/find-branch", found.branch
    end

    def test_create_worktree_marks_needs_setup
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("new-wt")

      assert result[:success]
      assert result[:worktree].needs_setup?
    end

    def test_paths_are_always_absolute
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("abs-path-test")

      assert result[:success]
      assert result[:worktree].path.start_with?("/")
      assert repo.worktrees_dir.start_with?("/")
      assert repo.config_dir.start_with?("/")
    end

    def test_worktrees_dir
      repo = Repository.new(@tmpdir)
      assert_equal File.join(@tmpdir, ".worktrees"), repo.worktrees_dir
    end

    def test_config_dir
      repo = Repository.new(@tmpdir)
      assert_equal File.join(@tmpdir, ".cwt"), repo.config_dir
    end

    def test_has_setup_script
      repo = Repository.new(@tmpdir)

      refute repo.has_setup_script?

      FileUtils.mkdir_p(repo.config_dir)
      File.write(repo.setup_script_path, "#!/bin/bash\necho hi")
      FileUtils.chmod(0o755, repo.setup_script_path)

      assert repo.has_setup_script?
    end

    def test_has_teardown_script
      repo = Repository.new(@tmpdir)

      refute repo.has_teardown_script?

      FileUtils.mkdir_p(repo.config_dir)
      File.write(repo.teardown_script_path, "#!/bin/bash\necho bye")
      FileUtils.chmod(0o755, repo.teardown_script_path)

      assert repo.has_teardown_script?
    end

    def test_find_worktree_by_name
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("find-me")
      assert result[:success]

      found = repo.find_worktree("find-me")
      assert_instance_of Worktree, found
      assert_equal "find-me", found.name
    end

    def test_find_worktree_by_path
      repo = Repository.new(@tmpdir)
      result = repo.create_worktree("path-find")
      assert result[:success]

      # find_worktree reloads from git, so it should find the newly created worktree
      found = repo.find_worktree(result[:worktree].path)
      assert_instance_of Worktree, found
      assert_equal "path-find", found.name
    end

    def test_find_worktree_returns_nil_when_not_found
      repo = Repository.new(@tmpdir)
      found = repo.find_worktree("nonexistent")
      assert_nil found
    end

    def test_create_worktree_uses_cwt_start_point
      repo = Repository.new(@tmpdir)

      # Create a side branch with a distinct commit
      system("git checkout -q -b side-branch")
      File.write("side.txt", "side content")
      system("git add side.txt && git commit -q -m 'side commit'")
      side_sha = `git rev-parse HEAD`.strip

      # Go back to the default branch so HEAD differs from side-branch
      system("git checkout -q master 2>/dev/null || git checkout -q main")

      ENV["CWT_START_POINT"] = "side-branch"
      result = repo.create_worktree("from-side")
      ENV.delete("CWT_START_POINT")

      assert result[:success], "Expected worktree creation to succeed: #{result[:error]}"

      # The new worktree's HEAD should match side-branch, not the default branch
      wt_sha = `git -C #{result[:worktree].path} rev-parse HEAD`.strip
      assert_equal side_sha, wt_sha
    end

    def test_create_worktree_fails_with_invalid_cwt_start_point
      repo = Repository.new(@tmpdir)

      ENV["CWT_START_POINT"] = "nonexistent-branch"
      result = repo.create_worktree("bad-base")
      ENV.delete("CWT_START_POINT")

      refute result[:success]
      assert result[:error]
    end

    def test_create_worktree_reuses_existing_branch
      repo = Repository.new(@tmpdir)

      # Create a branch with a distinct commit
      system("git checkout -q -b existing-branch")
      File.write("existing.txt", "existing content")
      system("git add existing.txt && git commit -q -m 'existing commit'")
      branch_sha = `git rev-parse HEAD`.strip

      # Go back to the default branch
      system("git checkout -q master 2>/dev/null || git checkout -q main")

      # Create worktree for the already-existing branch
      result = repo.create_worktree("existing-branch")

      assert result[:success], "Expected worktree creation to succeed: #{result[:error]}"
      assert_equal "existing-branch", result[:worktree].branch

      # The worktree should be on the existing branch's commit
      wt_sha = `git -C #{result[:worktree].path} rev-parse HEAD`.strip
      assert_equal branch_sha, wt_sha

      # The file from the existing branch should be present
      assert File.exist?(File.join(result[:worktree].path, "existing.txt"))
    end
  end
end
