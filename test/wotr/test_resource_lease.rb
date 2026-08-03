# frozen_string_literal: true

require "test_helper"
require "wotr/resource_lease"
require "wotr/lease"
require "mocha/minitest"
require "tmpdir"
require "fileutils"

module Wotr
  # Exercises the reconcile-lease-against-physical-probe logic with a real
  # LeaseStore and a stubbed repository/config so probe results are controllable.
  class TestResourceLease < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("wotr-rl-")
      @store = LeaseStore.for_dir(@dir)
      @cfg = mock("config")
      @repo = mock("repository")
      @repo.stubs(:config).returns(@cfg)
      @repo.stubs(:lease_store).returns(@store)
      @cfg.stubs(:lease_ttl).returns(100)
      @svc = ResourceLease.new(@repo)
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def wt(path, branch)
      m = mock("wt-#{branch}")
      m.stubs(:path).returns(path)
      m.stubs(:branch).returns(branch)
      m
    end

    def stub_inquire(status:, owner: nil)
      @cfg.stubs(:resource).with("web").returns({ "inquire" => "probe" })
      data = { "status" => status }
      data["owner"] = owner if owner
      @cfg.stubs(:run_inquire).returns({ ran: true, success: true, data: data })
    end

    def test_owned_with_no_lease_adopts
      stub_inquire(status: "owned", owner: "/wt/a")
      @repo.stubs(:worktree_containing).returns(wt("/wt/a", "feat-a"))

      holder = @svc.current_holder("web")

      assert_equal "/wt/a", holder.path
      assert_equal "feat-a", holder.branch
      assert holder.lease.adopted?, "server seen but not acquired by wotr → adopted"
      assert @store.get("web"), "lease persisted"
    end

    def test_owned_with_matching_lease_renews
      @store.acquire("web", holder: "/wt/a", holder_branch: "feat-a", ttl: 100, now: Time.now.to_i - 50)
      stub_inquire(status: "owned", owner: "/wt/a")
      @repo.stubs(:worktree_containing).returns(wt("/wt/a", "feat-a"))

      holder = @svc.current_holder("web")

      refute holder.lease.adopted?
      assert holder.lease.since_renew <= 2, "confirmed ownership should renew the lease"
    end

    def test_owned_by_different_worktree_replaces_stale_lease
      @store.acquire("web", holder: "/wt/a", holder_branch: "feat-a", ttl: 100, now: Time.now.to_i - 10)
      stub_inquire(status: "owned", owner: "/wt/b")
      @repo.stubs(:worktree_containing).returns(wt("/wt/b", "feat-b"))

      holder = @svc.current_holder("web")

      assert_equal "/wt/b", holder.path
      assert_equal "feat-b", holder.branch
      assert_equal "/wt/b", @store.get("web").holder, "lease now points at the physical owner"
    end

    def test_unowned_clears_stale_lease
      @store.acquire("web", holder: "/wt/a", ttl: 100, now: Time.now.to_i)
      stub_inquire(status: "unowned")

      assert_nil @svc.current_holder("web"), "no physical owner → free"
      assert_nil @store.get("web"), "dead server's lease cleared"
    end

    def test_inconclusive_probe_trusts_live_lease
      # No inquire script → probe is inconclusive; a still-live lease stands.
      @cfg.stubs(:resource).with("web").returns({})
      @store.acquire("web", holder: "/wt/a", holder_branch: "feat-a", ttl: 100, now: Time.now.to_i)
      @repo.stubs(:worktree_containing).returns(nil)

      holder = @svc.current_holder("web")

      assert_equal "/wt/a", holder.path
      assert_equal "feat-a", holder.branch
    end

    def test_inconclusive_probe_with_lapsed_lease_is_free
      @cfg.stubs(:resource).with("web").returns({})
      @store.acquire("web", holder: "/wt/a", ttl: 100, now: Time.now.to_i - 500)

      assert_nil @svc.current_holder("web"), "lapsed lease + no probe → treated as free"
    end
  end
end
