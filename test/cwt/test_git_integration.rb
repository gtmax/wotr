# frozen_string_literal: true

require "test_helper"
require "cwt/repository"
require "cwt/worktree"
require "cwt/git"
require "tmpdir"
require "fileutils"

module Cwt
  class TestGitIntegration < Minitest::Test
    include GitRepoTestHelper

    parallelize_me!

    def setup
      create_test_repo
      @repo = Repository.new(@tmpdir)
    end

    def teardown
      cleanup_test_repo
    end

    # ========== Setup Marker Tests ==========

    def test_create_worktree_creates_setup_marker
      result = @repo.create_worktree("test-session")

      assert result[:success], "Worktree should be created"
      assert result[:worktree].needs_setup?,
             "Setup marker should exist in new worktree"
    end

    def test_mark_setup_complete_removes_marker
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      assert wt.needs_setup?, "Should need setup initially"

      wt.mark_setup_complete!

      refute wt.needs_setup?, "Should not need setup after marking complete"
    end

    # ========== Setup Execution Tests ==========

    def test_run_setup_executes_custom_script
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create .cwt/setup script
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.setup_script_path, "#!/bin/bash\necho 'setup ran' > setup_ran.txt")
      FileUtils.chmod(0o755, @repo.setup_script_path)

      # Capture output
      output = capture_io { wt.run_setup!(visible: true) }.join

      assert File.exist?(File.join(wt.path, "setup_ran.txt")),
             "Setup script should have created file in worktree"
      assert_match(/Running .cwt\/setup/, output,
             "Should show setup header")
    end

    def test_run_setup_falls_back_to_symlinks
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create files to symlink in root
      File.write(File.join(@tmpdir, ".env"), "SECRET=value")
      FileUtils.mkdir_p(File.join(@tmpdir, "node_modules"))
      File.write(File.join(@tmpdir, "node_modules", ".keep"), "")

      # No .cwt/setup script exists
      wt.run_setup!(visible: false)

      # Check symlinks were created
      assert File.symlink?(File.join(wt.path, ".env")),
             ".env should be symlinked"
      assert File.symlink?(File.join(wt.path, "node_modules")),
             "node_modules should be symlinked"
    end

    def test_run_setup_does_not_symlink_when_script_exists
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create files to symlink in root
      File.write(File.join(@tmpdir, ".env"), "SECRET=value")

      # Create .cwt/setup script (does nothing)
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.setup_script_path, "#!/bin/bash\n# do nothing")
      FileUtils.chmod(0o755, @repo.setup_script_path)

      capture_io { wt.run_setup!(visible: true) }

      refute File.exist?(File.join(wt.path, ".env")),
             ".env should NOT be symlinked when custom script exists"
    end

    def test_cwt_root_env_var_is_set_for_setup
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create .cwt/setup script that writes CWT_ROOT to a file
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.setup_script_path, "#!/bin/bash\necho \"$CWT_ROOT\" > cwt_root.txt")
      FileUtils.chmod(0o755, @repo.setup_script_path)

      capture_io { wt.run_setup!(visible: true) }

      root_file = File.join(wt.path, "cwt_root.txt")
      assert File.exist?(root_file), "Script should have created cwt_root.txt"
      # Use realpath to handle macOS /var -> /private/var symlink
      assert_equal File.realpath(@tmpdir), File.read(root_file).strip,
             "CWT_ROOT should be set to the repo root"
    end

    # ========== Teardown Tests ==========

    def test_run_teardown_executes_script
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create .cwt/teardown script using CWT_ROOT env var
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\necho 'teardown ran' > \"$CWT_ROOT/teardown_ran.txt\"")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      output = capture_io { wt.run_teardown! }.join

      assert File.exist?(File.join(@tmpdir, "teardown_ran.txt")),
             "Teardown script should have created file"
      assert_match(/Running .cwt\/teardown/, output,
             "Should show teardown header")
    end

    def test_run_teardown_returns_ran_false_when_no_script
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      teardown_result = wt.run_teardown!

      refute teardown_result[:ran], "Should return ran: false when no script"
    end

    def test_run_teardown_returns_success_status
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create .cwt/teardown script that succeeds
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\nexit 0")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.run_teardown! }
      teardown_result = wt.run_teardown!

      assert teardown_result[:ran], "Should return ran: true"
      assert teardown_result[:success], "Should return success: true"
    end

    def test_run_teardown_returns_failure_status
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]

      # Create .cwt/teardown script that fails
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\nexit 1")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.run_teardown! }
      teardown_result = wt.run_teardown!

      assert teardown_result[:ran], "Should return ran: true"
      refute teardown_result[:success], "Should return success: false"
    end

    # ========== Delete Worktree with Teardown Tests ==========

    def test_delete_runs_teardown
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]
      wt.mark_setup_complete!

      # Create .cwt/teardown script using CWT_ROOT env var
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\necho 'teardown ran' > \"$CWT_ROOT/teardown_evidence.txt\"")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.delete!(force: true) }

      assert File.exist?(File.join(@tmpdir, "teardown_evidence.txt")),
             "Teardown should have run before removal"
    end

    def test_delete_fails_on_teardown_failure_without_force
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]
      wt.mark_setup_complete!

      # Create .cwt/teardown script that fails
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\nexit 1")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.delete!(force: false) }
      delete_result = wt.delete!(force: false)

      refute delete_result[:success], "Should fail when teardown fails"
      assert_match(/teardown.*failed/i, delete_result[:error])
      assert wt.exists?, "Worktree should still exist"
    end

    def test_delete_succeeds_on_teardown_failure_with_force
      result = @repo.create_worktree("test-session")
      wt = result[:worktree]
      wt.mark_setup_complete!

      # Create .cwt/teardown script that fails
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.teardown_script_path, "#!/bin/bash\nexit 1")
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      capture_io { wt.delete!(force: true) }
      delete_result = wt.delete!(force: true)

      assert delete_result[:success], "Should succeed with force: true"
      refute wt.exists?, "Worktree should be removed"
    end

    # ========== Full Workflow Tests ==========

    def test_full_workflow_create_setup_teardown_delete
      # 1. Create worktree
      result = @repo.create_worktree("full-workflow")
      wt = result[:worktree]
      assert result[:success]
      assert wt.needs_setup?

      # 2. Create setup and teardown scripts using CWT_ROOT env var
      FileUtils.mkdir_p(@repo.config_dir)
      File.write(@repo.setup_script_path, "#!/bin/bash\necho 'setup' > setup.log")
      File.write(@repo.teardown_script_path, "#!/bin/bash\necho 'teardown' > \"$CWT_ROOT/teardown.log\"")
      FileUtils.chmod(0o755, @repo.setup_script_path)
      FileUtils.chmod(0o755, @repo.teardown_script_path)

      # 3. Run setup (simulating first resume)
      capture_io { wt.run_setup!(visible: true) }
      wt.mark_setup_complete!
      assert File.exist?(File.join(wt.path, "setup.log"))
      refute wt.needs_setup?

      # 4. Second resume should NOT run setup
      refute wt.needs_setup?, "Setup should not run again"

      # 5. Delete worktree (runs teardown)
      # Force needed because setup.log is an untracked file
      capture_io { wt.delete!(force: true) }
      assert File.exist?(File.join(@tmpdir, "teardown.log"))
      refute wt.exists?
    end

    # ========== Git Status Tests ==========

    def test_get_status_detects_dirty_worktree
      result = @repo.create_worktree("status-test")
      wt = result[:worktree]

      # Mark setup complete to remove the marker file
      wt.mark_setup_complete!

      # Initially clean (no uncommitted changes)
      status = Git.get_status(wt.path)
      refute status[:dirty], "Worktree should be clean initially"

      # Create uncommitted file
      File.write(File.join(wt.path, "uncommitted.txt"), "dirty")

      status = Git.get_status(wt.path)
      assert status[:dirty], "Worktree should be dirty after adding file"
    end

    # ========== Repository Discovery Tests ==========

    def test_discover_works_from_worktree
      result = @repo.create_worktree("discover-test")
      wt = result[:worktree]

      discovered = Repository.discover(wt.path)
      assert_equal File.realpath(@tmpdir), File.realpath(discovered.root)
    end
  end
end
