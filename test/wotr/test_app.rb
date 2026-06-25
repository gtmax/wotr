# frozen_string_literal: true

require "test_helper"
require "wotr/app"
require "mocha/minitest"

module Wotr
  class TestApp < Minitest::Test
    def make_wt(path, branch: "br")
      wt = mock('worktree')
      wt.stubs(:path).returns(path)
      wt.stubs(:branch).returns(branch)
      wt
    end

    def test_collect_compatible_paths_returns_compatible_worktrees
      wts = [make_wt("/a"), make_wt("/b"), make_wt("/c")]
      run_inquire = lambda do |_name, wt|
        status = wt.path == "/b" ? "incompatible" : "compatible"
        { ran: true, success: true, data: { "status" => status } }
      end

      result = App.collect_compatible_paths("res", wts, run_inquire)

      assert_equal ["/a", "/c"], result.sort
    end

    def test_collect_compatible_paths_skips_failed_inquires
      wts = [make_wt("/a"), make_wt("/b")]
      run_inquire = lambda do |_name, wt|
        if wt.path == "/a"
          { ran: true, success: false, data: {} }
        else
          { ran: true, success: true, data: { "status" => "compatible" } }
        end
      end

      assert_equal ["/b"], App.collect_compatible_paths("res", wts, run_inquire)
    end

    def test_collect_compatible_paths_runs_in_parallel
      wts = (1..5).map { |i| make_wt("/p#{i}") }
      run_inquire = lambda do |_name, _wt|
        sleep 0.2
        { ran: true, success: true, data: { "status" => "compatible" } }
      end

      t0 = Time.now
      result = App.collect_compatible_paths("res", wts, run_inquire)
      elapsed = Time.now - t0

      assert_equal 5, result.size
      # Sequential would be ~1.0s; parallel should be ~0.2s. Generous slack for CI.
      assert elapsed < 0.6, "expected parallel execution, took #{elapsed}s"
    end

    def test_collect_exclusive_owners_stops_at_first_owner
      called = []
      wts = [make_wt("/a"), make_wt("/b"), make_wt("/c")]
      run_inquire = lambda do |_name, wt|
        called << wt.path
        if wt.path == "/b"
          { ran: true, success: true, data: { "status" => "owned", "owner" => nil } }
        else
          { ran: true, success: true, data: { "status" => "unowned" } }
        end
      end

      result = App.collect_exclusive_owners("res", wts, run_inquire)

      assert_equal ["/b"], result
      assert_equal ["/a", "/b"], called, "should break after first owner"
    end

    def test_collect_exclusive_owners_resolves_owner_to_known_worktree
      a = make_wt("/repo/wt-a")
      b = make_wt("/repo/wt-b")
      run_inquire = lambda do |_name, _wt|
        { ran: true, success: true, data: { "status" => "owned", "owner" => "/repo/wt-b" } }
      end

      result = App.collect_exclusive_owners("res", [a, b], run_inquire)

      assert_equal ["/repo/wt-b"], result
    end

    def test_collect_exclusive_owners_returns_empty_when_no_owner
      wts = [make_wt("/a"), make_wt("/b")]
      run_inquire = lambda do |_name, _wt|
        { ran: true, success: true, data: { "status" => "unowned" } }
      end

      assert_equal [], App.collect_exclusive_owners("res", wts, run_inquire)
    end
  end
end
