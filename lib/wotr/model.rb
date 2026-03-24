# frozen_string_literal: true

module Wotr
  class Model
    RESOURCE_POLL_INTERVAL = 60 # seconds
    WORKTREE_POLL_INTERVAL = 15 # seconds

    SHORTCUTS = {
      normal: [
        { key: 'n',     desc: 'New'    },
        { key: '/',     desc: 'Filter' },
        { key: 'Enter', desc: 'Resume' },
        { key: 's',     desc: 'Shell'  },
        { key: 'd',     desc: 'Delete' },
        { key: 'Esc',   desc: 'Quit'   }
      ].freeze,
      creating: [
        { key: 'Enter', desc: 'Confirm' },
        { key: 'Esc',   desc: 'Cancel'  }
      ].freeze,
      filtering: [
        { key: 'Type',  desc: 'Search' },
        { key: 'Enter', desc: 'Resume' },
        { key: 'Esc',   desc: 'Reset'  }
      ].freeze
    }.freeze

    # Navigation keys not shown in footer but still reserved for resource shortcuts
    NAV_KEYS = %w[q j k l].freeze

    RESERVED_KEYS = (
      SHORTCUTS[:normal].map { |s| s[:key] } + NAV_KEYS
    ).select { |k| k.length == 1 && k =~ /[a-z]/ }.uniq.freeze

    LOG_PANE_MAX_LINES = 400

    attr_reader :repository, :selection_index, :mode, :input_buffer,
                :running, :fetch_generation, :filter_query,
                :log_entries, :log_scroll_offset, :task_label,
                :verbose
    attr_accessor :resume_to, :mouse_areas
    attr_writer :selection_index

    def initialize(repository)
      @repository = repository
      @worktrees_cache = []
      @selection_index = 0
      @mode = :normal
      @input_buffer = String.new
      @filter_query = String.new
      @running = true
      @fetch_generation = 0
      @resume_to = nil
      @mouse_areas = {}
      @resource_icons = {}     # { "/path/to/worktree" => ["🌐", "🤖"] }
      @last_resource_poll = nil
      @last_worktree_poll = nil
      @background_activity = 0
      @log_entries = []        # unified log buffer: [{ text:, style:, status:, output_count:, last_output: }]
      @log_scroll_offset = 0
      @log_scroll_pinned = false  # when true, new entries don't auto-scroll
      @task_label = nil
      @verbose = false
    end

    # Unified log: all feedback (status messages, task output) goes here.
    # status: true marks high-level messages shown in regular mode.
    # status: false (default) marks script output shown only in verbose mode.
    # Status entries track output_count and last_output for their following output lines.

    def log_message(text, style: :dim, status: false)
      @log_entries << { text: text, style: style, status: status }
      @log_entries.shift if @log_entries.size > LOG_PANE_MAX_LINES
      if @log_scroll_pinned
        recalculate_pinned_offset
      else
        @log_scroll_offset = 0
      end

      unless status
        # Increment count on the most recent status entry
        last_status = @log_entries.rindex { |e| e[:status] }
        if last_status
          @log_entries[last_status][:output_count] = (@log_entries[last_status][:output_count] || 0) + 1
          @log_entries[last_status][:last_output] = text
        end
      end
    end

    def log_status(text, style: :dim)
      log_message(text, style: style, status: true)
    end

    def log_text
      @log_entries.map { |e| e[:text] }.join("\n")
    end

    def log_replace_last(text, style: :dim, status: false)
      if @log_entries.empty?
        log_message(text, style: style, status: status)
      else
        @log_entries[-1] = { text: text, style: style, status: status }
      end
    end

    def visible_log_entries
      if @verbose
        @log_entries
      else
        @log_entries.select { |e| e[:status] }
      end
    end

    def message
      @log_entries.last&.dig(:text) || ""
    end

    def set_message(msg)
      log_status(msg)
    end

    def start_task_log(label, clear: true)
      @task_label = label
      @task_active = true
      @log_scroll_pinned = false
      if clear
        @log_entries.clear
        @log_scroll_offset = 0
      end
    end

    def append_task_log(line)
      log_message(line)
    end

    def finish_task_log(suffix = "done")
      @task_label = "#{@task_label} — #{suffix}" if @task_label
      @task_active = false
    end

    def clear_task_log
      @task_label = nil
      @task_active = false
    end

    def task_running?
      @task_active == true
    end

    def pin_scroll_to_error
      # Pin to the error entry — recalculate offset on each render
      @log_scroll_pinned = true
      @pinned_entry_id = @log_entries.rindex { |e| e[:style] == :error }
      recalculate_pinned_offset
    end

    def recalculate_pinned_offset
      return unless @log_scroll_pinned && @pinned_entry_id

      # Find where the pinned entry sits in visible_log_entries
      visible = visible_log_entries
      # Map absolute index to visible index
      visible_idx = 0
      @log_entries.each_with_index do |entry, i|
        break if i == @pinned_entry_id
        visible_idx += 1 if @verbose || entry[:status]
      end
      entries_after = [visible.size - 1 - visible_idx, 0].max
      @log_scroll_offset = entries_after
    end

    def toggle_verbose
      @verbose = !@verbose
      @log_scroll_offset = 0
    end

    def log_scroll_up(n = 1)
      @log_scroll_pinned = false
      max = [visible_log_entries.size - 1, 0].max
      @log_scroll_offset = [@log_scroll_offset + n, max].min
    end

    def log_scroll_down(n = 1)
      @log_scroll_pinned = false
      @log_scroll_offset = [@log_scroll_offset - n, 0].max
    end

    def worktrees
      @worktrees_cache
    end

    def refresh_worktrees!
      @worktrees_cache = @repository.worktrees
      clamp_selection
      @worktrees_cache
    end

    def update_worktrees(list)
      @worktrees_cache = list
      clamp_selection
    end

    def find_worktree_by_path(path)
      normalized = begin
        File.realpath(path)
      rescue Errno::ENOENT
        File.expand_path(path)
      end
      @worktrees_cache.find { |wt| wt.path == normalized }
    end

    def visible_worktrees
      if @filter_query.empty?
        @worktrees_cache
      else
        @worktrees_cache.select do |wt|
          wt.path.include?(@filter_query) || (wt.branch && wt.branch.include?(@filter_query))
        end
      end
    end

    def increment_generation
      @fetch_generation += 1
    end

    def select_worktree_by_path(path)
      normalized = begin
        File.realpath(path)
      rescue Errno::ENOENT
        File.expand_path(path)
      end
      list = visible_worktrees
      idx = list.index { |wt| wt.path == normalized }
      @selection_index = idx if idx
    end

    def move_selection(delta)
      list = visible_worktrees
      return if list.empty?

      new_index = @selection_index + delta
      if new_index >= 0 && new_index < list.size
        @selection_index = new_index
      end
    end

    def set_mode(mode)
      @mode = mode
      @input_buffer = String.new if mode == :creating
    end

    def set_filter(query)
      @filter_query = query
      @selection_index = 0
    end

    def input_append(char)
      if @mode == :filtering
        @filter_query << char
        @selection_index = 0
      else
        @input_buffer << char
      end
    end

    def input_backspace
      if @mode == :filtering
        @filter_query.chop!
        @selection_index = 0
      else
        @input_buffer.chop!
      end
    end

    def selected_worktree
      visible_worktrees[@selection_index]
    end

    def quit
      @running = false
    end

    def current_shortcuts
      SHORTCUTS[mode] || SHORTCUTS[:normal]
    end

    # Resource icons

    def action_shortcuts
      @action_shortcuts ||= begin
        taken = RESERVED_KEYS.dup
        @repository.config.action_names.each_with_object({}) do |name, result|
          cfg = @repository.config.action(name)
          key = cfg&.fetch("key", nil)
          next unless key && key.length == 1 && key =~ /[a-z]/
          if taken.include?(key)
            owner = result[key] || "a built-in shortcut"
            log_status("shortcut collision: action '#{name}' wants key '#{key}' already used by #{owner}", style: :warn)
            next
          end
          result[key] = name
          taken << key
        end
      end
    end

    def has_actions?
      @repository.config.action_names.any?
    end

    def resource_shortcuts
      @resource_shortcuts ||= begin
        taken = RESERVED_KEYS.dup + action_shortcuts.keys
        @repository.config.resource_names.each_with_object({}) do |name, result|
          letter = name.chars.find { |c| c =~ /[a-z]/ && !taken.include?(c) }
          unless letter
            log_status("shortcut collision: resource '#{name}' has no available letter for a shortcut", style: :warn)
            next
          end
          result[letter] = name
          taken << letter
        end
      end
    end

    def has_resources?
      @repository.config.resource_names.any?
    end

    def resource_icons_for(path)
      @resource_icons[path] || []
    end

    def update_resource_icons(by_path)
      @resource_icons = by_path
    end

    def start_background_activity
      @background_activity += 1
    end

    def finish_background_activity
      @background_activity = [@background_activity - 1, 0].max
    end

    def background_activity?
      @background_activity > 0
    end

    def worktree_poll_due?
      @last_worktree_poll.nil? ||
        (Time.now - @last_worktree_poll) >= WORKTREE_POLL_INTERVAL
    end

    def mark_worktree_poll_started
      @last_worktree_poll = Time.now
    end

    def resource_poll_due?
      @last_resource_poll.nil? ||
        (Time.now - @last_resource_poll) >= RESOURCE_POLL_INTERVAL
    end

    def mark_resource_poll_started
      @last_resource_poll = Time.now
    end

    private

    def clamp_selection
      list = visible_worktrees
      if list.empty?
        @selection_index = 0
      elsif @selection_index >= list.size
        @selection_index = list.size - 1
      end
    end
  end
end
