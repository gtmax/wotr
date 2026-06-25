# frozen_string_literal: true

require "test_helper"
require "wotr/repository"
require "tmpdir"
require "fileutils"

module Wotr
  class TestRepository < Minitest::Test
    include GitRepoTestHelper

    def setup
      create_test_repo
      @default_branch = `git -C #{@tmpdir} symbolic-ref --short HEAD`.strip
    end

    def teardown
      # Clean up sibling .worktrees directory
      repo_name = File.basename(@tmpdir)
      parent = File.dirname(@tmpdir)
      FileUtils.rm_rf(File.join(parent, ".worktrees", repo_name))
      wt_parent = File.join(parent, ".worktrees")
      Dir.rmdir(wt_parent) if Dir.exist?(wt_parent) && (Dir.entries(wt_parent) - %w[. ..]).empty?
      cleanup_test_repo
    end

    def test_discover_finds_repo_root
      repo = Repository.discover(@tmpdir)

      assert_instance_of Repository, repo
      assert_equal File.realpath(@tmpdir), File.realpath(repo.root)
    end

    def test_discover_from_subdir_returns_root
      subdir = File.join(@tmpdir, "subdir", "nested")
      FileUtils.mkdir_p(subdir)

      repo = Repository.discover(subdir)

      assert_instance_of Repository, repo
      assert_equal File.realpath(@tmpdir), File.realpath(repo.root)
    end

    def test_discover_from_worktree_returns_main_root
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("test-wt")
      ENV.delete("WOTR_START_POINT")
      assert result[:success], "Expected worktree creation to succeed: #{result[:error]}"

      discovered = Repository.discover(result[:worktree].path)
      assert_equal File.realpath(@tmpdir), File.realpath(discovered.root)
    end

    def test_discover_returns_nil_outside_git_repo
      Dir.mktmpdir do |non_git_dir|
        repo = Repository.discover(non_git_dir)
        assert_nil repo
      end
    end

    def test_worktrees_returns_worktree_objects
      repo = Repository.new(@tmpdir)
      worktrees = repo.worktrees

      assert_instance_of Array, worktrees
      assert worktrees.all? { |wt| wt.is_a?(Worktree) }
      assert worktrees.size >= 1
    end

    def test_create_worktree_returns_worktree_object
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("test-session")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"
      assert_instance_of Worktree, result[:worktree]
      assert_equal "test-session", result[:worktree].name
      assert_equal "test-session", result[:worktree].branch
    end

    def test_create_worktree_sanitizes_name
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("test session!")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"
      assert_equal "test_session_", result[:worktree].name
    end

    def test_create_worktree_with_slashes
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("feat/implement-foo")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"
      assert_equal "feat/implement-foo", result[:worktree].name
      assert_equal "feat/implement-foo", result[:worktree].branch
      assert Dir.exist?(File.join(repo.worktrees_dir, "feat", "implement-foo"))
    end

    def test_create_worktree_sanitizes_consecutive_slashes
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("feat//double-slash")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"
      assert_equal "feat/double-slash", result[:worktree].name
    end

    def test_find_worktree_by_branch_name
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("feat/find-branch")
      ENV.delete("WOTR_START_POINT")
      assert result[:success], "Expected success: #{result[:error]}"

      found = repo.find_worktree("feat/find-branch")
      assert_instance_of Worktree, found
      assert_equal "feat/find-branch", found.branch
    end

    def test_create_worktree_marks_needs_setup
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("new-wt")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"
      assert result[:worktree].needs_setup?
    end

    def test_paths_are_always_absolute
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("abs-path-test")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"
      assert result[:worktree].path.start_with?("/")
      assert repo.worktrees_dir.start_with?("/")
      assert repo.config_dir.start_with?("/")
    end

    def test_worktrees_dir
      repo = Repository.new(@tmpdir)
      repo_name = File.basename(@tmpdir)
      parent = File.dirname(@tmpdir)
      assert_equal File.join(parent, ".worktrees", repo_name), repo.worktrees_dir
    end

    def test_config_dir
      repo = Repository.new(@tmpdir)
      assert_equal File.join(@tmpdir, ".wotr"), repo.config_dir
    end

    def test_has_teardown_hook
      repo = Repository.new(@tmpdir)

      refute repo.has_teardown_hook?

      FileUtils.mkdir_p(repo.config_dir)
      File.write(File.join(repo.config_dir, "config"), <<~YAML)
        hooks:
          teardown:
            - bg: echo bye
      YAML

      # Config is memoized — re-read for the second assertion
      fresh_repo = Repository.new(@tmpdir)
      assert fresh_repo.has_teardown_hook?
    end

    def test_find_worktree_by_name
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("find-me")
      ENV.delete("WOTR_START_POINT")
      assert result[:success], "Expected success: #{result[:error]}"

      found = repo.find_worktree("find-me")
      assert_instance_of Worktree, found
      assert_equal "find-me", found.name
    end

    def test_find_worktree_by_path
      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      result = repo.create_worktree("path-find")
      ENV.delete("WOTR_START_POINT")
      assert result[:success], "Expected success: #{result[:error]}"

      found = repo.find_worktree(result[:worktree].path)
      assert_instance_of Worktree, found
      assert_equal "path-find", found.name
    end

    def test_find_worktree_returns_nil_when_not_found
      repo = Repository.new(@tmpdir)
      found = repo.find_worktree("nonexistent")
      assert_nil found
    end

    def test_create_worktree_uses_wotr_start_point
      repo = Repository.new(@tmpdir)

      system("git", "-C", @tmpdir, "checkout", "-q", "-b", "side-branch")
      File.write(File.join(@tmpdir, "side.txt"), "side content")
      system("git", "-C", @tmpdir, "add", "side.txt")
      system("git", "-C", @tmpdir, "commit", "-q", "-m", "side commit")
      side_sha = `git -C #{@tmpdir} rev-parse HEAD`.strip

      system("git -C #{@tmpdir} checkout -q master 2>/dev/null || git -C #{@tmpdir} checkout -q main")

      ENV["WOTR_START_POINT"] = "side-branch"
      result = repo.create_worktree("from-side")
      ENV.delete("WOTR_START_POINT")

      assert result[:success], "Expected success: #{result[:error]}"

      wt_sha = `git -C #{result[:worktree].path} rev-parse HEAD`.strip
      assert_equal side_sha, wt_sha
    end

    def test_create_worktree_fails_with_invalid_wotr_start_point
      repo = Repository.new(@tmpdir)

      ENV["WOTR_START_POINT"] = "nonexistent-branch"
      result = repo.create_worktree("bad-base")
      ENV.delete("WOTR_START_POINT")

      refute result[:success]
      assert result[:error]
    end

    def test_create_worktree_reuses_existing_branch
      repo = Repository.new(@tmpdir)

      system("git", "-C", @tmpdir, "checkout", "-q", "-b", "existing-branch")
      File.write(File.join(@tmpdir, "existing.txt"), "existing content")
      system("git", "-C", @tmpdir, "add", "existing.txt")
      system("git", "-C", @tmpdir, "commit", "-q", "-m", "existing commit")
      branch_sha = `git -C #{@tmpdir} rev-parse HEAD`.strip

      system("git -C #{@tmpdir} checkout -q master 2>/dev/null || git -C #{@tmpdir} checkout -q main")

      result = repo.create_worktree("existing-branch")

      assert result[:success], "Expected success: #{result[:error]}"
      assert_equal "existing-branch", result[:worktree].branch

      wt_sha = `git -C #{result[:worktree].path} rev-parse HEAD`.strip
      assert_equal branch_sha, wt_sha
      assert File.exist?(File.join(result[:worktree].path, "existing.txt"))
    end
  end
end
