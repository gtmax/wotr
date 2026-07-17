# frozen_string_literal: true

require "test_helper"
require "wotr/worktree"
require "tmpdir"
require "fileutils"

module Wotr
  # Exercises `wotr new` by invoking the real exe as a subprocess. We set
  # WOTR_START_POINT so worktree creation branches from the local default branch
  # instead of fetching origin (the temp repo has no remote).
  #
  # We only cover the default (create-only) path here: `--switch` runs the switch
  # hook and then exec's an interactive shell, which would block a test. Setup and
  # switch hook execution itself is covered in test_config.rb / test_worktree.rb.
  class TestCLINew < Minitest::Test
    include GitRepoTestHelper

    EXE = File.expand_path("../../exe/wotr", __dir__)

    def setup
      create_test_repo
      @default_branch = `git -C #{@tmpdir} symbolic-ref --short HEAD`.strip
    end

    def teardown
      repo_name = File.basename(@tmpdir)
      parent = File.dirname(@tmpdir)
      FileUtils.rm_rf(File.join(parent, ".worktrees", repo_name))
      wt_parent = File.join(parent, ".worktrees")
      Dir.rmdir(wt_parent) if Dir.exist?(wt_parent) && (Dir.entries(wt_parent) - %w[. ..]).empty?
      cleanup_test_repo
    end

    def run_new(*args)
      env = { "WOTR_START_POINT" => @default_branch }
      out = IO.popen(env, [RbConfig.ruby, EXE, "new", *args], chdir: @tmpdir, err: [:child, :out], &:read)
      [out, $?.success?]
    end

    def worktree_path(name)
      File.join(File.dirname(@tmpdir), ".worktrees", File.basename(@tmpdir), name)
    end

    def test_creates_worktree_and_branch
      out, ok = run_new("my-feature")

      assert ok, "expected success, got: #{out}"
      assert Dir.exist?(worktree_path("my-feature")), "worktree dir should exist"

      branches = `git -C #{@tmpdir} branch --list my-feature`.strip
      refute_empty branches, "branch my-feature should exist"
    end

    def test_create_only_defers_setup
      run_new("deferred")

      marker = File.join(worktree_path("deferred"), Worktree::SETUP_MARKER)
      assert File.exist?(marker), "create-only should leave the needs-setup marker (setup deferred to entry)"
    end

    def test_is_idempotent_when_worktree_exists
      run_new("dup")
      out, ok = run_new("dup")

      assert ok, "second invocation should succeed, got: #{out}"
      assert_match(/already exists/, out)
    end

    def test_requires_a_name
      out, ok = run_new

      refute ok, "should fail without a branch name"
      assert_match(/Usage: wotr new/, out)
    end
  end
end
