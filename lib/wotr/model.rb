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
    NAV_KEYS = %w[q j k].freeze

    RESERVED_KEYS = (
      SHORTCUTS[:normal].map { |s| s[:key] } + NAV_KEYS
    ).select { |k| k.length == 1 && k =~ /[a-z]/ }.uniq.freeze

    LOG_PANE_MAX_LINES = 200

    attr_reader :repository, :selection_index, :mode, :input_buffer, :message,
                :running, :fetch_generation, :filter_query,
                :task_log, :task_label
    attr_accessor :resume_to, :mouse_areas
    attr_writer :selection_index

    def initialize(repository)
      @repository = repository
      @worktrees_cache = []
      @selection_index = 0
      @mode = :normal
      @input_buffer = String.new
      @filter_query = String.new
      @message = ""
      @running = true
      @fetch_generation = 0
      @resume_to = nil
      @mouse_areas = {}
      @resource_icons = {}     # { "/path/to/worktree" => ["🌐", "🤖"] }
      @last_resource_poll = nil
      @last_worktree_poll = nil
      @background_activity = 0
      @task_log = []
      @task_label = nil
    end

    def start_task_log(label)
      @task_label = label
      @task_log = []
    end

    def append_task_log(line)
      @task_log << line
      @task_log.shift if @task_log.size > LOG_PANE_MAX_LINES
    end

    def clear_task_log
      @task_log = []
      @task_label = nil
    end

    def task_running?
      !@task_label.nil?
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
      if mode == :creating
        @input_buffer = String.new
        @message = "Enter session name: "
      elsif mode == :filtering
        @message = "Filter: "
      else
        @message = "Ready"
      end
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

    def set_message(msg)
      @message = msg
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
          next unless key && key.length == 1 && key =~ /[a-z]/ && !taken.include?(key)
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
          next unless letter
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
