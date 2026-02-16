# frozen_string_literal: true

require "test_helper"
require "cwt/repository"
require "cwt/worktree"
require "tmpdir"
require "fileutils"

module Cwt
  class TestWorktree < Minitest::Test
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

      @repo = Repository.new(@tmpdir)
    end

    def teardown
      Dir.chdir(@original_dir)
      FileUtils.rm_rf(@tmpdir)
    end

    def test_name_returns_relative_path
      result = @repo.create_worktree("my-worktree")
      assert result[:success]

      assert_equal "my-worktree", result[:worktree].name
    end

    def test_name_returns_full_relative_path_with_slashes
      result = @repo.create_worktree("feat/my-feature")
      assert result[:success]

      assert_equal "feat/my-feature", result[:worktree].name
    end

    def test_path_is_absolute
      result = @repo.create_worktree("abs-test")
      assert result[:success]

      assert result[:worktree].path.start_with?("/")
    end

    def test_exists_returns_true_for_existing_worktree
      result = @repo.create_worktree("exists-test")
      assert result[:success]

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

      # New worktree should need setup
      assert wt.needs_setup?

      # Mark complete
      wt.mark_setup_complete!
      refute wt.needs_setup?

      # Mark needs setup again
      wt.mark_needs_setup!
      assert wt.needs_setup?
    end

    def test_run_setup_with_custom_script
      result = @repo.create_worktree("custom-setup")
      wt = result[:worktree]

      # Create custom setup script
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.setup_script_path, "#!/bin/bash\necho 'setup ran' > setup_ran.txt")
      FileUtils.chmod(0o755, @repo.setup_script_path)

      capture_io { wt.run_setup!(visible: true) }

      assert File.exist?(File.join(wt.path, "setup_ran.txt"))
    end

    def test_run_setup_falls_back_to_symlinks
      result = @repo.create_worktree("symlink-setup")
      wt = result[:worktree]

      # Create files to symlink in root
      File.write(File.join(@tmpdir, ".env"), "SECRET=value")
      FileUtils.mkdir_p(File.join(@tmpdir, "node_modules"))

      # No custom script exists
      wt.run_setup!(visible: false)

      assert File.symlink?(File.join(wt.path, ".env"))
      assert File.symlink?(File.join(wt.path, "node_modules"))
    end

    def test_run_teardown_with_script
      result = @repo.create_worktree("teardown-test")
      wt = result[:worktree]

      # Create teardown script
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\necho 'teardown' > \"$CWT_ROOT/teardown.txt\"")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.run_teardown! }

      assert File.exist?(File.join(@tmpdir, "teardown.txt"))
    end

    def test_run_teardown_returns_ran_false_without_script
      result = @repo.create_worktree("no-teardown")
      wt = result[:worktree]

      teardown_result = wt.run_teardown!

      refute teardown_result[:ran]
    end

    def test_delete_removes_worktree_and_branch
      result = @repo.create_worktree("delete-test")
      wt = result[:worktree]
      wt.mark_setup_complete!

      delete_result = wt.delete!(force: true)

      assert delete_result[:success]
      refute Dir.exist?(wt.path)
    end

    def test_delete_runs_teardown
      result = @repo.create_worktree("teardown-delete")
      wt = result[:worktree]
      wt.mark_setup_complete!

      # Create teardown script
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\necho 'ran' > \"$CWT_ROOT/deleted.txt\"")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.delete!(force: true) }

      assert File.exist?(File.join(@tmpdir, "deleted.txt"))
    end

    def test_delete_fails_on_teardown_failure_without_force
      result = @repo.create_worktree("fail-teardown")
      wt = result[:worktree]
      wt.mark_setup_complete!

      # Create failing teardown script
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\nexit 1")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      delete_result = capture_io { wt.delete!(force: false) }.last
      delete_result = wt.delete!(force: false)

      refute delete_result[:success]
      assert Dir.exist?(wt.path)
    end

    def test_fetch_status_updates_dirty_flag
      result = @repo.create_worktree("status-test")
      wt = result[:worktree]

      # Mark setup complete to remove the marker file
      wt.mark_setup_complete!

      # Initially clean (no uncommitted changes)
      wt.fetch_status!
      refute wt.dirty, "Worktree should be clean initially"

      # Create uncommitted file
      File.write(File.join(wt.path, "uncommitted.txt"), "dirty")

      wt.fetch_status!
      assert wt.dirty, "Worktree should be dirty after adding file"
    end

    def test_to_h_returns_hash_representation
      result = @repo.create_worktree("hash-test")
      wt = result[:worktree]
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
      wt.mark_setup_complete!

      parent_dir = File.join(@repo.worktrees_dir, "feat")
      assert Dir.exist?(parent_dir), "Parent dir should exist before delete"

      wt.delete!(force: true)

      refute Dir.exist?(parent_dir), "Empty parent dir should be removed after delete"
    end

    def test_delete_preserves_nonempty_parent_directories
      result1 = @repo.create_worktree("feat/first")
      result2 = @repo.create_worktree("feat/second")
      result1[:worktree].mark_setup_complete!
      result2[:worktree].mark_setup_complete!

      parent_dir = File.join(@repo.worktrees_dir, "feat")
      result1[:worktree].delete!(force: true)

      assert Dir.exist?(parent_dir), "Parent dir should remain when siblings exist"

      result2[:worktree].delete!(force: true)

      refute Dir.exist?(parent_dir), "Parent dir should be removed when empty"
    end

    def test_cwt_root_env_var_is_set_for_setup
      result = @repo.create_worktree("env-test")
      wt = result[:worktree]

      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.setup_script_path, "#!/bin/bash\necho \"$CWT_ROOT\" > cwt_root.txt")
      FileUtils.chmod(0o755, @repo.setup_script_path)

      capture_io { wt.run_setup!(visible: true) }

      root_file = File.join(wt.path, "cwt_root.txt")
      assert File.exist?(root_file)
      assert_equal File.realpath(@tmpdir), File.read(root_file).strip
    end
  end
end
