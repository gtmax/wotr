# frozen_string_literal: true

require "test_helper"
require "wotr/lease"
require "tmpdir"
require "fileutils"

module Wotr
  class TestLeaseStore < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("wotr-lease-")
      @store = LeaseStore.for_dir(@dir)
      # Real directories so realpath normalization has something to resolve.
      @wt_a = File.join(@dir, "wt-a"); FileUtils.mkdir_p(@wt_a)
      @wt_b = File.join(@dir, "wt-b"); FileUtils.mkdir_p(@wt_b)
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def test_acquire_records_holder_and_timestamps
      lease = @store.acquire("web", holder: @wt_a, holder_branch: "feat-a", ttl: 100, now: 1000)

      assert_equal File.realpath(@wt_a), lease.holder
      assert_equal "feat-a", lease.holder_branch
      assert_equal 1000, lease.acquired_at
      assert_equal 1000, lease.renewed_at
      assert_equal 100, lease.ttl
      refute lease.adopted?
    end

    def test_reacquire_same_holder_preserves_acquired_at_and_bumps_renewed
      @store.acquire("web", holder: @wt_a, ttl: 100, now: 1000)
      lease = @store.acquire("web", holder: @wt_a, ttl: 100, now: 1500)

      assert_equal 1000, lease.acquired_at, "acquired_at should be preserved on renewal"
      assert_equal 1500, lease.renewed_at, "renewed_at should advance"
    end

    def test_acquire_by_different_holder_resets_acquired_at
      @store.acquire("web", holder: @wt_a, ttl: 100, now: 1000)
      lease = @store.acquire("web", holder: @wt_b, ttl: 100, now: 1500)

      assert_equal File.realpath(@wt_b), lease.holder
      assert_equal 1500, lease.acquired_at
    end

    def test_renew_only_when_holder_matches
      @store.acquire("web", holder: @wt_a, ttl: 100, now: 1000)

      assert @store.renew("web", holder: @wt_a, now: 1200)
      assert_equal 1200, @store.get("web").renewed_at

      refute @store.renew("web", holder: @wt_b, now: 1300),
        "must not renew a lease held by someone else"
      assert_equal 1200, @store.get("web").renewed_at
    end

    def test_adopt_creates_adopted_lease_and_is_noop_if_present
      assert @store.adopt("web", holder: @wt_a, holder_branch: "feat-a", ttl: 100, now: 1000)
      lease = @store.get("web")
      assert lease.adopted?
      assert_equal 1000, lease.acquired_at

      refute @store.adopt("web", holder: @wt_b, ttl: 100, now: 2000),
        "adopt should not overwrite an existing lease"
      assert_equal File.realpath(@wt_a), @store.get("web").holder
    end

    def test_live_and_lapsed
      lease = @store.acquire("web", holder: @wt_a, ttl: 100, now: 1000)

      assert lease.live?(1050)
      refute lease.live?(1101), "past ttl since renewal → lapsed"
    end

    def test_release_removes_lease
      @store.acquire("web", holder: @wt_a, now: 1000)
      assert @store.release("web")
      assert_nil @store.get("web")
      refute @store.release("web"), "releasing an absent lease returns false"
    end

    def test_release_for_holder_removes_only_that_holders_leases
      @store.acquire("web", holder: @wt_a, now: 1000)
      @store.acquire("test", holder: @wt_b, now: 1000)
      @store.acquire("agents", holder: @wt_a, now: 1000)

      released = @store.release_for_holder(@wt_a)

      assert_equal %w[agents web].sort, released.sort
      assert_nil @store.get("web")
      assert_nil @store.get("agents")
      refute_nil @store.get("test"), "other holder's lease untouched"
    end

    def test_release_for_holder_is_noop_when_no_file
      # Nothing acquired yet — no leases.json exists.
      assert_equal [], @store.release_for_holder(@wt_a)
      refute File.exist?(@store.path), "must not create an empty leases file"
    end

    def test_all_returns_every_lease
      @store.acquire("web", holder: @wt_a, now: 1000)
      @store.acquire("test", holder: @wt_b, now: 1000)

      all = @store.all
      assert_equal %w[test web].sort, all.keys.sort
      assert_instance_of Lease, all["web"]
    end

    def test_survives_corrupt_file
      FileUtils.mkdir_p(@dir)
      File.write(@store.path, "{ not valid json")

      assert_equal({}, @store.all)
      # Recovers by overwriting on next write.
      @store.acquire("web", holder: @wt_a, now: 1000)
      assert_equal File.realpath(@wt_a), @store.get("web").holder
    end
  end

  class TestDuration < Minitest::Test
    def test_human_formats
      assert_equal "0s", Duration.human(0)
      assert_equal "45s", Duration.human(45)
      assert_equal "1m", Duration.human(60)
      assert_equal "12m", Duration.human(12 * 60)
      assert_equal "2h", Duration.human(2 * 3600)
      assert_equal "2h 5m", Duration.human(2 * 3600 + 5 * 60)
      assert_equal "3d", Duration.human(3 * 86_400)
    end
  end
end
