# frozen_string_literal: true

require "test_helper"
require "wotr/config"
require "tmpdir"

module Wotr
  class TestConfig < Minitest::Test
    def setup
      @cfg = Config.new({})
    end

    def test_run_script_capture_returns_stdout_on_success
      stdout, success = @cfg.send(:run_script_capture, "echo hello")

      assert success
      assert_equal "hello\n", stdout
    end

    def test_run_script_capture_with_timeout_succeeds_for_fast_script
      stdout, success = @cfg.send(:run_script_capture, "echo fast", timeout: 5)

      assert success
      assert_equal "fast\n", stdout
    end

    def test_run_script_capture_kills_hung_script_within_timeout
      t0 = Time.now
      _stdout, success = @cfg.send(:run_script_capture, "sleep 30; echo done", timeout: 1)
      elapsed = Time.now - t0

      refute success, "hung script should have failed"
      assert elapsed < 5, "should have been killed near the 1s timeout, took #{elapsed}s"
    end

    def test_run_script_capture_captures_partial_output_before_timeout
      t0 = Time.now
      stdout, success = @cfg.send(:run_script_capture, "echo before; sleep 30", timeout: 1)
      elapsed = Time.now - t0

      refute success
      assert_includes stdout, "before"
      assert elapsed < 5, "took #{elapsed}s"
    end
  end
end
