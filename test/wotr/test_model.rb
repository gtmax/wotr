# frozen_string_literal: true

require "test_helper"
require "wotr/model"
require "wotr/update"
require "wotr/repository"
require "wotr/worktree"
require "mocha/minitest"

module Wotr
  class TestModel < Minitest::Test
    def setup
      @mock_repo = mock('repository')
      @mock_repo.stubs(:root).returns("/fake/repo")
      @mock_repo.stubs(:worktrees).returns([])
      @model = Model.new(@mock_repo)
    end

    def test_initialization
      assert_equal [], @model.worktrees
      assert_equal 0, @model.selection_index
      assert_equal :normal, @model.mode
      assert @model.running
      assert_nil @model.resume_to
      assert_equal @mock_repo, @model.repository
    end

    def test_resume_to_accessor
      mock_wt = mock('worktree')
      assert_nil @model.resume_to
      @model.resume_to = mock_wt
      assert_equal mock_wt, @model.resume_to
    end

    def test_refresh_worktrees_loads_from_repository
      mock_wt = mock('worktree')
      mock_wt.stubs(:path).returns("/fake/path")
      mock_wt.stubs(:branch).returns("main")
      @mock_repo.expects(:worktrees).returns([mock_wt])

      @model.refresh_worktrees!

      assert_equal [mock_wt], @model.worktrees
    end

    def test_find_worktree_by_path
      mock_wt = mock('worktree')
      mock_wt.stubs(:path).returns("/fake/repo/.worktrees/test")
      mock_wt.stubs(:branch).returns("test")

      @model.update_worktrees([mock_wt])

      found = @model.find_worktree_by_path("/fake/repo/.worktrees/test")
      assert_equal mock_wt, found
    end

    def test_find_worktree_by_path_returns_nil_when_not_found
      found = @model.find_worktree_by_path("/nonexistent")
      assert_nil found
    end

    def test_update_worktrees
      mock_wt = mock('worktree')
      mock_wt.stubs(:path).returns("/a")
      mock_wt.stubs(:branch).returns("a")
      list = [mock_wt]
      @model.update_worktrees(list)
      assert_equal list, @model.worktrees
    end

    def test_move_selection
      wt1 = mock('wt1')
      wt1.stubs(:path).returns("/a")
      wt1.stubs(:branch).returns("a")
      wt2 = mock('wt2')
      wt2.stubs(:path).returns("/b")
      wt2.stubs(:branch).returns("b")
      wt3 = mock('wt3')
      wt3.stubs(:path).returns("/c")
      wt3.stubs(:branch).returns("c")

      @model.update_worktrees([wt1, wt2, wt3])
      @model.move_selection(1)
      assert_equal 1, @model.selection_index
      @model.move_selection(1)
      assert_equal 2, @model.selection_index
      @model.move_selection(1) # Boundary
      assert_equal 2, @model.selection_index
      @model.move_selection(-1)
      assert_equal 1, @model.selection_index
    end

    def test_input_handling
      @model.set_mode(:creating)
      @model.input_append("a")
      @model.input_append("b")
      assert_equal "ab", @model.input_buffer
      @model.input_backspace
      assert_equal "a", @model.input_buffer
    end

    def test_visible_worktrees_with_filter
      wt1 = mock('wt1')
      wt1.stubs(:path).returns("/repo/.worktrees/feature-auth")
      wt1.stubs(:branch).returns("feature-auth")
      wt2 = mock('wt2')
      wt2.stubs(:path).returns("/repo/.worktrees/bugfix-login")
      wt2.stubs(:branch).returns("bugfix-login")

      @model.update_worktrees([wt1, wt2])
      @model.set_filter("auth")

      visible = @model.visible_worktrees
      assert_equal 1, visible.size
      assert_equal wt1, visible.first
    end

    def test_selected_worktree
      wt1 = mock('wt1')
      wt1.stubs(:path).returns("/a")
      wt1.stubs(:branch).returns("a")
      wt2 = mock('wt2')
      wt2.stubs(:path).returns("/b")
      wt2.stubs(:branch).returns("b")

      @model.update_worktrees([wt1, wt2])
      assert_equal wt1, @model.selected_worktree

      @model.move_selection(1)
      assert_equal wt2, @model.selected_worktree
    end

    def test_paste_appends_to_input_buffer_in_creating_mode
      @model.set_mode(:creating)

      Update.handle_paste(@model, "my-branch-name")

      assert_equal "my-branch-name", @model.input_buffer
    end

    def test_paste_appends_to_filter_in_filtering_mode
      @model.set_mode(:filtering)

      Update.handle_paste(@model, "feature")

      assert_equal "feature", @model.filter_query
    end

    def test_paste_uses_first_line_only
      @model.set_mode(:creating)

      Update.handle_paste(@model, "first-line\nsecond-line\nthird-line")

      assert_equal "first-line", @model.input_buffer
    end

    def test_paste_strips_whitespace
      @model.set_mode(:creating)

      Update.handle_paste(@model, "  my-branch  ")

      assert_equal "my-branch", @model.input_buffer
    end

    def test_paste_ignored_in_normal_mode
      @model.set_mode(:normal)

      Update.handle_paste(@model, "some-text")

      assert_equal "", @model.input_buffer
      assert_equal "", @model.filter_query
    end

    def test_paste_appends_to_existing_input
      @model.set_mode(:creating)
      @model.input_append("prefix-")

      Update.handle_paste(@model, "suffix")

      assert_equal "prefix-suffix", @model.input_buffer
    end

    # ========== Unified Log Buffer Tests ==========

    def test_log_message_appends_to_entries
      @model.log_message("hello")
      @model.log_message("world")

      assert_equal 2, @model.log_entries.size
      assert_equal "hello", @model.log_entries[0][:text]
      assert_equal "world", @model.log_entries[1][:text]
    end

    def test_log_message_default_style_is_dim
      @model.log_message("test")
      assert_equal :dim, @model.log_entries.last[:style]
    end

    def test_log_message_with_error_style
      @model.log_message("bad thing", style: :error)
      assert_equal :error, @model.log_entries.last[:style]
    end

    def test_message_returns_last_log_entry
      @model.log_message("first")
      @model.log_message("second")
      assert_equal "second", @model.message
    end

    def test_message_returns_empty_when_no_entries
      assert_equal "", @model.message
    end

    def test_set_message_delegates_to_log_message
      @model.set_message("hello via set_message")
      assert_equal 1, @model.log_entries.size
      assert_equal "hello via set_message", @model.log_entries.last[:text]
    end

    def test_append_task_log_delegates_to_log_message
      @model.append_task_log("log line")
      assert_equal 1, @model.log_entries.size
      assert_equal "log line", @model.log_entries.last[:text]
    end

    def test_start_task_log_clears_log_entries
      @model.log_message("old stuff")
      @model.start_task_log("my task")

      assert_equal 0, @model.log_entries.size
      assert_equal "my task", @model.task_label
    end

    def test_finish_task_log_preserves_entries_and_updates_label
      @model.start_task_log("my task")
      @model.log_message("line 1")
      @model.log_message("line 2")
      @model.finish_task_log("done")

      assert_equal "my task — done", @model.task_label
      refute @model.task_running?
      assert_equal 2, @model.log_entries.size
    end

    def test_clear_task_log_removes_label
      @model.start_task_log("my task")
      @model.clear_task_log

      assert_nil @model.task_label
      refute @model.task_running?
    end

    def test_log_buffer_max_size
      201.times { |i| @model.log_message("line #{i}") }
      assert_equal 200, @model.log_entries.size
      # First entry should have been shifted out
      assert_equal "line 1", @model.log_entries.first[:text]
      assert_equal "line 200", @model.log_entries.last[:text]
    end

    def test_log_scroll_up
      10.times { |i| @model.log_status("line #{i}") }
      @model.log_scroll_up(3)
      assert_equal 3, @model.log_scroll_offset
    end

    def test_log_scroll_down
      10.times { |i| @model.log_status("line #{i}") }
      @model.log_scroll_up(5)
      @model.log_scroll_down(2)
      assert_equal 3, @model.log_scroll_offset
    end

    def test_log_scroll_cannot_go_negative
      @model.log_status("one")
      @model.log_scroll_down(10)
      assert_equal 0, @model.log_scroll_offset
    end

    def test_log_scroll_capped_at_buffer_size
      3.times { |i| @model.log_status("line #{i}") }
      @model.log_scroll_up(100)
      assert_equal 2, @model.log_scroll_offset  # max is visible_entries.size - 1
    end

    def test_log_scroll_resets_on_new_message
      10.times { |i| @model.log_status("line #{i}") }
      @model.log_scroll_up(5)
      assert_equal 5, @model.log_scroll_offset

      @model.log_message("new message")
      assert_equal 0, @model.log_scroll_offset
    end

    def test_start_task_log_sets_label
      @model.start_task_log("installing deps")
      assert_equal "installing deps", @model.task_label
      assert @model.task_running?
    end

    def test_task_running_reflects_active_state
      refute @model.task_running?
      @model.start_task_log("task")
      assert @model.task_running?
      @model.finish_task_log
      refute @model.task_running?
      assert_equal "task — done", @model.task_label  # label persists
    end

    def test_set_mode_does_not_log
      @model.set_mode(:creating)
      assert_equal 0, @model.log_entries.size

      @model.set_mode(:filtering)
      assert_equal 0, @model.log_entries.size

      @model.set_mode(:normal)
      assert_equal 0, @model.log_entries.size
    end

    def test_log_replace_last
      @model.log_message("Checking...")
      @model.log_replace_last("Checking... done.")

      assert_equal 1, @model.log_entries.size
      assert_equal "Checking... done.", @model.message
    end

    def test_log_replace_last_on_empty_buffer
      @model.log_replace_last("first entry")

      assert_equal 1, @model.log_entries.size
      assert_equal "first entry", @model.message
    end

    # ========== Verbose / Status Tests ==========

    def test_log_message_defaults_to_non_status
      @model.log_message("script output")
      refute @model.log_entries.last[:status]
    end

    def test_log_status_marks_as_status
      @model.log_status("Running hook...")
      assert @model.log_entries.last[:status]
    end

    def test_set_message_marks_as_status
      @model.set_message("hello")
      assert @model.log_entries.last[:status]
    end

    def test_visible_log_entries_regular_mode
      @model.log_status("status line")
      @model.log_message("output line")
      @model.log_status("another status")

      refute @model.verbose
      visible = @model.visible_log_entries
      assert_equal 2, visible.size
      assert_equal "status line", visible[0][:text]
      assert_equal "another status", visible[1][:text]
    end

    def test_visible_log_entries_verbose_mode
      @model.log_status("status line")
      @model.log_message("output line")

      @model.toggle_verbose
      assert @model.verbose
      assert_equal 2, @model.visible_log_entries.size
    end

    def test_toggle_verbose
      refute @model.verbose
      @model.toggle_verbose
      assert @model.verbose
      @model.toggle_verbose
      refute @model.verbose
    end

    def test_output_count_tracked_per_status_entry
      @model.log_status("first status")
      @model.log_message("output 1")
      @model.log_message("output 2")
      @model.log_status("second status")
      @model.log_message("output 3")

      entries = @model.log_entries.select { |e| e[:status] }
      assert_equal 2, entries[0][:output_count]
      assert_equal "output 2", entries[0][:last_output]
      assert_equal 1, entries[1][:output_count]
      assert_equal "output 3", entries[1][:last_output]
    end

    def test_log_scroll_uses_visible_entries
      @model.log_status("s1")
      @model.log_message("o1")
      @model.log_message("o2")
      @model.log_status("s2")

      # Regular mode: 2 visible (s1, s2)
      @model.log_scroll_up(100)
      assert_equal 1, @model.log_scroll_offset  # max is 2 - 1 = 1

      # Verbose mode: 4 visible
      @model.toggle_verbose
      @model.log_scroll_up(100)
      assert_equal 3, @model.log_scroll_offset  # max is 4 - 1 = 3
    end

    def test_log_text_always_copies_full_log
      @model.log_status("status")
      @model.log_message("output")

      # Always includes all entries regardless of mode
      assert_equal "status\noutput", @model.log_text

      @model.toggle_verbose
      assert_equal "status\noutput", @model.log_text
    end

    # ========== Clear Behavior Tests ==========

    def test_user_action_clears_log
      @model.log_status("old status")
      @model.log_message("old output")
      assert_equal 2, @model.log_entries.size

      # Simulates user-initiated action (clear: true is default)
      @model.start_task_log("new action")
      assert_equal 0, @model.log_entries.size
    end

    def test_chained_hook_does_not_clear_log
      @model.start_task_log("new hook")
      @model.log_status("setup output")
      @model.log_message("install output")

      # Simulates chained hook (clear: false)
      @model.start_task_log("switch hook", clear: false)
      assert_equal 2, @model.log_entries.size
      assert_equal "switch hook", @model.task_label
    end

    def test_status_messages_have_no_output_count
      @model.log_status("status 1")
      @model.log_status("status 2")

      @model.log_entries.each do |e|
        assert_nil e[:output_count]
      end
    end

    def test_log_replace_last_with_status
      @model.log_status("Refreshing...")
      @model.log_replace_last("Refreshing... done.", status: true)

      assert_equal 1, @model.log_entries.size
      assert @model.log_entries.last[:status]
      assert_equal "Refreshing... done.", @model.log_entries.last[:text]
    end

    def test_finish_task_log_stops_running_but_keeps_label
      @model.start_task_log("delete (feat)")
      assert @model.task_running?

      @model.finish_task_log("done")
      refute @model.task_running?
      assert_equal "delete (feat) — done", @model.task_label
    end

    def test_finish_task_log_with_failure
      @model.start_task_log("hook (feat)")
      @model.finish_task_log("failed")

      assert_equal "hook (feat) — failed", @model.task_label
      refute @model.task_running?
    end

    def test_next_user_action_clears_persisted_label
      @model.start_task_log("old task")
      @model.finish_task_log("done")
      assert_equal "old task — done", @model.task_label

      @model.start_task_log("new task")
      assert_equal "new task", @model.task_label
      assert @model.task_running?
    end

    def test_output_count_persists_after_finish
      @model.start_task_log("task")
      @model.log_status("running...")
      5.times { |i| @model.log_message("line #{i}") }
      @model.finish_task_log

      status_entry = @model.log_entries.find { |e| e[:status] }
      assert_equal 5, status_entry[:output_count]
      assert_equal "line 4", status_entry[:last_output]
    end

    # ========== Chord Mode Tests ==========

    def test_log_command_mode
      @model.set_mode(:log_command)
      assert_equal :log_command, @model.mode

      @model.set_mode(:normal)
      assert_equal :normal, @model.mode
    end
  end
end
