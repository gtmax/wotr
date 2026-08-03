# frozen_string_literal: true

require "test_helper"
require "wotr/repository"
require "tmpdir"
require "fileutils"

module Wotr
  # End-to-end coverage of the lease-aware CLI (`acquire` / `release` /
  # `resources`) driven through the real exe as a subprocess.
  #
  # The `demo` resource's inquire reports ownership from a control file; its
  # acquire writes the caller's worktree into that file. So acquiring genuinely
  # makes the resource "owned" by the caller (reconciliation stays consistent),
  # and we can fake a foreign holder by writing the control file directly.
  class TestCLIAcquire < Minitest::Test
    include GitRepoTestHelper

    EXE = File.expand_path("../../exe/wotr", __dir__)

    CONFIG = <<~YAML
      resources:
        demo:
          icon: 🔧
          exclusive: true
          lease_ttl_minutes: 1
          acquire: |
            echo "$WOTR_WORKTREE" > "$WOTR_ROOT/.wotr/demo_owner"
            echo "acquired demo"
          inquire: |
            ctrl="$WOTR_ROOT/.wotr/demo_owner"
            if [ -f "$ctrl" ]; then
              printf '{"status":"owned","owner":"%s"}\\n' "$(cat "$ctrl")"
            else
              printf '{"status":"unowned"}\\n'
            fi
    YAML

    def setup
      create_test_repo
      @default_branch = `git -C #{@tmpdir} symbolic-ref --short HEAD`.strip
      FileUtils.mkdir_p(File.join(@tmpdir, ".wotr"))
      File.write(File.join(@tmpdir, ".wotr", "config"), CONFIG)

      repo = Repository.new(@tmpdir)
      ENV["WOTR_START_POINT"] = @default_branch
      %w[mine other].each { |b| repo.create_worktree(b) }
      ENV.delete("WOTR_START_POINT")
    end

    def teardown
      repo_name = File.basename(@tmpdir)
      parent = File.dirname(@tmpdir)
      FileUtils.rm_rf(File.join(parent, ".worktrees", repo_name))
      wt_parent = File.join(parent, ".worktrees")
      Dir.rmdir(wt_parent) if Dir.exist?(wt_parent) && (Dir.entries(wt_parent) - %w[. ..]).empty?
      cleanup_test_repo
    end

    def worktree_path(name)
      File.join(File.dirname(@tmpdir), ".worktrees", File.basename(@tmpdir), name)
    end

    def leases_path
      File.join(File.dirname(@tmpdir), ".worktrees", File.basename(@tmpdir), ".wotr", "leases.json")
    end

    def control_path
      File.join(@tmpdir, ".wotr", "demo_owner")
    end

    def run_cli(cwd, *args, env: {})
      out = IO.popen(env, [RbConfig.ruby, EXE, *args], chdir: cwd, err: [:child, :out], &:read)
      [out, $?.success?]
    end

    def leases
      JSON.parse(File.read(leases_path))
    end

    def test_acquire_free_resource_records_lease
      out, ok = run_cli(worktree_path("mine"), "acquire", "demo")

      assert ok, "expected success, got: #{out}"
      assert_match(/Acquired demo\./, out)
      assert File.exist?(leases_path), "lease file should be written"
      assert_equal File.realpath(worktree_path("mine")), leases["demo"]["holder"]
      refute leases["demo"]["adopted"]
    end

    def test_resources_shows_holder
      run_cli(worktree_path("mine"), "acquire", "demo")

      out, ok = run_cli(worktree_path("mine"), "resources")

      assert ok
      assert_match(/held by worktree 'mine'/, out)
      assert_match(/acquired .* ago, renewed .* ago/, out)
    end

    def test_resources_shows_free_when_unheld
      out, ok = run_cli(worktree_path("mine"), "resources")

      assert ok
      assert_match(/demo \(exclusive\)/, out)
      assert_match(/free/, out)
    end

    def test_acquire_held_by_other_fails_fast_with_decision
      # Fake a foreign holder without running acquire.
      File.write(control_path, File.realpath(worktree_path("other")))

      out, ok = run_cli(worktree_path("mine"), "acquire", "demo",
                        env: { "WOTR_ACQUIRE_WAIT" => "0" })

      refute ok, "should fail when another worktree holds it"
      assert_match(/demo is held by worktree 'other'/, out)
      assert_match(/wotr acquire demo --force/, out)
      assert_match(/wotr acquire demo --wait/, out)
    end

    def test_force_takes_over_from_other
      File.write(control_path, File.realpath(worktree_path("other")))

      out, ok = run_cli(worktree_path("mine"), "acquire", "demo", "--force")

      assert ok, "force should succeed, got: #{out}"
      assert_match(/Taking demo from worktree 'other' \(--force\)/, out)
      assert_match(/Acquired demo\./, out)
      assert_equal File.realpath(worktree_path("mine")), leases["demo"]["holder"]
    end

    def test_release_removes_lease
      run_cli(worktree_path("mine"), "acquire", "demo")
      assert File.exist?(leases_path)

      out, ok = run_cli(worktree_path("mine"), "release", "demo")

      assert ok
      assert_match(/Released demo\./, out)
      assert_nil leases["demo"], "lease should be gone"
    end

    def test_own_reacquire_is_not_contended
      run_cli(worktree_path("mine"), "acquire", "demo")

      # Re-acquiring my own resource should never hit the contention gate,
      # even with a zero wait budget.
      out, ok = run_cli(worktree_path("mine"), "acquire", "demo",
                        env: { "WOTR_ACQUIRE_WAIT" => "0" })

      assert ok, "re-acquiring own resource should succeed, got: #{out}"
      assert_match(/Acquired demo\./, out)
    end
  end
end
