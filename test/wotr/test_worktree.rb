# frozen_string_literal: true

require "test_helper"
require "wotr/repository"
require "wotr/worktree"
require "tmpdir"
require "fileutils"

module Wotr
  class TestWorktree < Minitest::Test
    include GitRepoTestHelper

    # Cannot parallelize — tests share ENV for HOME and WOTR_START_POINT

    def setup
      create_test_repo
      @repo = Repository.new(@tmpdir)
      @default_branch = `git -C #{@tmpdir} rev-parse --abbrev-ref HEAD`.strip
      ENV["WOTR_START_POINT"] = @default_branch
    end

    def teardown
      ENV.delete("WOTR_START_POINT")
      FileUtils.rm_rf(@repo.worktrees_dir) if @repo
      cleanup_test_repo
    end

    def test_name_returns_relative_path
      result = @repo.create_worktree("my-worktree")
      assert result[:success], "Expected success: #{result[:error]}"

      assert_equal "my-worktree", result[:worktree].name
    end

    def test_name_returns_full_relative_path_with_slashes
      result = @repo.create_worktree("feat/my-feature")
      assert result[:success], "Expected success: #{result[:error]}"

      assert_equal "feat/my-feature", result[:worktree].name
    end

    def test_path_is_absolute
      result = @repo.create_worktree("abs-test")
      assert result[:success], "Expected success: #{result[:error]}"

      assert result[:worktree].path.start_with?("/")
    end

    def test_exists_returns_true_for_existing_worktree
      result = @repo.create_worktree("exists-test")
      assert result[:success], "Expected success: #{result[:error]}"

      assert result[:worktree].exists?
    end

    def test_exists_returns_false_for_nonexistent_path
      wt = Worktree.new(
        repository: @repo,
        path: "/nonexistent/path",
        branch: "fake",
        sha: nil
      )

      refute wt.exists?
    end

    def test_needs_setup_lifecycle
      result = @repo.create_worktree("setup-test")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"

      assert wt.needs_setup?

      wt.mark_setup_complete!
      refute wt.needs_setup?

      wt.mark_needs_setup!
      assert wt.needs_setup?
    end

    def test_run_setup_falls_back_to_symlinks
      result = @repo.create_worktree("symlink-setup")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"

      # Create files to symlink in root
      File.write(File.join(@tmpdir, ".env"), "SECRET=value")
      FileUtils.mkdir_p(File.join(@tmpdir, "node_modules"))

      # No user script or config hooks — falls back to symlinks
      wt.run_setup!(visible: false)

      assert File.symlink?(File.join(wt.path, ".env"))
      assert File.symlink?(File.join(wt.path, "node_modules"))
    end

    def test_run_teardown_with_hook
      result = @repo.create_worktree("teardown-test")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"

      write_teardown_hook(<<~SH)
        echo "teardown" > "$WOTR_ROOT/teardown.txt"
      SH

      capture_io { wt.run_teardown! }

      assert File.exist?(File.join(@tmpdir, "teardown.txt"))
    end

    def test_run_teardown_returns_ran_false_without_hook
      result = @repo.create_worktree("no-teardown")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"

      teardown_result = wt.run_teardown!

      refute teardown_result[:ran]
    end

    def test_delete_removes_worktree_and_branch
      result = @repo.create_worktree("delete-test")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"
      wt.mark_setup_complete!

      delete_result = wt.delete!(force: true)

      assert delete_result[:success]
      refute Dir.exist?(wt.path)
    end

    def test_delete_runs_teardown
      result = @repo.create_worktree("teardown-delete")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"
      wt.mark_setup_complete!

      write_teardown_hook(<<~SH)
        echo "ran" > "$WOTR_ROOT/deleted.txt"
      SH

      capture_io { wt.delete!(force: true) }

      assert File.exist?(File.join(@tmpdir, "deleted.txt"))
    end

    def test_delete_fails_on_teardown_failure_without_force
      result = @repo.create_worktree("fail-teardown")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"
      wt.mark_setup_complete!

      write_teardown_hook("exit 1")

      capture_io { wt.delete!(force: false) }
      delete_result = wt.delete!(force: false)

      refute delete_result[:success]
      assert Dir.exist?(wt.path)
    end

    def test_fetch_status_updates_dirty_flag
      result = @repo.create_worktree("status-test")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"
      wt.mark_setup_complete!

      wt.fetch_status!
      refute wt.dirty, "Worktree should be clean initially"

      File.write(File.join(wt.path, "uncommitted.txt"), "dirty")

      wt.fetch_status!
      assert wt.dirty, "Worktree should be dirty after adding file"
    end

    def test_to_h_returns_hash_representation
      result = @repo.create_worktree("hash-test")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"
      wt.dirty = true
      wt.last_commit = "2 hours ago"

      hash = wt.to_h

      assert_equal wt.path, hash[:path]
      assert_equal "hash-test", hash[:branch]
      assert_equal true, hash[:dirty]
      assert_equal "2 hours ago", hash[:last_commit]
    end

    def test_delete_cleans_up_empty_parent_directories
      result = @repo.create_worktree("feat/cleanup-test")
      wt = result[:worktree]
      assert result[:success], "Expected success: #{result[:error]}"
      wt.mark_setup_complete!

      parent_dir = File.join(@repo.worktrees_dir, "feat")
      assert Dir.exist?(parent_dir), "Parent dir should exist before delete"

      wt.delete!(force: true)

      refute Dir.exist?(parent_dir), "Empty parent dir should be removed after delete"
    end

    def test_delete_preserves_nonempty_parent_directories
      result1 = @repo.create_worktree("feat/first")
      result2 = @repo.create_worktree("feat/second")
      assert result1[:success], "Expected success: #{result1[:error]}"
      assert result2[:success], "Expected success: #{result2[:error]}"
      result1[:worktree].mark_setup_complete!
      result2[:worktree].mark_setup_complete!

      parent_dir = File.join(@repo.worktrees_dir, "feat")
      result1[:worktree].delete!(force: true)

      assert Dir.exist?(parent_dir), "Parent dir should remain when siblings exist"

      result2[:worktree].delete!(force: true)

      refute Dir.exist?(parent_dir), "Parent dir should be removed when empty"
    end
  end
end
