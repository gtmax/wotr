# frozen_string_literal: true

require "test_helper"
require "cwt/git"
require "mocha/minitest"

module Cwt
  class TestGit < Minitest::Test
    def test_get_commit_ages_empty_shas
      mock_git = mock('git')
      ages = Git.get_commit_ages([], git: mock_git)
      assert_equal({}, ages)
    end

    def test_get_commit_ages_parses_output
      mock_lib = mock('lib')
      mock_lib.expects(:send)
           .with(:command, '--no-optional-locks', 'show', '-s', '--format=%H|%cr', 'abc123', 'def456')
           .returns("abc123|2 hours ago\ndef456|3 days ago")

      mock_git = mock('git')
      mock_git.stubs(:lib).returns(mock_lib)

      ages = Git.get_commit_ages(["abc123", "def456"], git: mock_git)

      assert_equal "2 hours ago", ages["abc123"]
      assert_equal "3 days ago", ages["def456"]
    end

    def test_get_status_returns_dirty_hash
      path = "/some/path"
      Dir.stubs(:exist?).with(path).returns(true)

      mock_lib = mock('lib')
      mock_lib.expects(:send)
           .with(:command, '--no-optional-locks', 'status', '--porcelain')
           .returns("M file.txt")

      mock_git = mock('git')
      mock_git.stubs(:lib).returns(mock_lib)

      ::Git.expects(:open).with(path).returns(mock_git)

      result = Git.get_status(path)
      assert result[:dirty]
    end

    def test_get_status_returns_clean_hash
      path = "/some/path"
      Dir.stubs(:exist?).with(path).returns(true)

      mock_lib = mock('lib')
      mock_lib.expects(:send)
           .with(:command, '--no-optional-locks', 'status', '--porcelain')
           .returns("")

      mock_git = mock('git')
      mock_git.stubs(:lib).returns(mock_lib)

      ::Git.expects(:open).with(path).returns(mock_git)

      result = Git.get_status(path)
      refute result[:dirty]
    end

    def test_prune_worktrees
      mock_lib = mock('lib')
      mock_lib.expects(:worktree_prune)

      mock_git = mock('git')
      mock_git.stubs(:lib).returns(mock_lib)

      Git.prune_worktrees(git: mock_git)
    end
  end
end
