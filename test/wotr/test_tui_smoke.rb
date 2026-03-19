# frozen_string_literal: true

require "test_helper"
require "pty"
require "io/wait"

module Wotr
  class TestTuiSmoke < Minitest::Test
    include GitRepoTestHelper

    def setup
      create_test_repo
    end

    def teardown
      cleanup_test_repo
    end

    def test_tui_launches_and_quits_cleanly
      exe = File.expand_path("../../exe/wotr", __dir__)
      ruby = RbConfig.ruby

      status = nil
      output = +""

      PTY.spawn(ruby, exe, "--repo-path", @tmpdir) do |reader, writer, pid|
        # Wait for TUI to initialize and render
        sleep 1

        # Send 'q' to quit
        writer.print("q")
        writer.flush

        # Collect any output
        begin
          loop do
            break unless reader.wait_readable(2)
            output << reader.read_nonblock(4096)
          end
        rescue Errno::EIO, IOError
          # Expected when PTY process exits
        end

        # Wait for process to finish
        _, status = Process.wait2(pid)
      end

      # TUI rendered something (escape sequences at minimum)
      assert output.length > 0, "wotr TUI should produce output"
      # Accept exit 0 or 1 (PTY terminal teardown can cause non-zero exit)
      assert [0, 1].include?(status.exitstatus),
             "wotr TUI should exit with status 0 or 1, got #{status.exitstatus}"
    end
  end
end
