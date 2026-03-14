# frozen_string_literal: true

require "ratatui_ruby"
require "thread"
require_relative "repository"
require_relative "worktree"
require_relative "config"
require_relative "model"
require_relative "view"
require_relative "update"
require_relative "git"

module Wotr
  class App
    POOL_SIZE = 4

    def self.run
      # Discover repository from current directory (works from worktrees too)
      repository = Repository.discover
      unless repository
        puts "Error: Not in a git repository"
        exit 1
      end

      # Change to repo root for consistent paths
      Dir.chdir(repository.root)

      model = Model.new(repository)

      # Initialize Thread Pool
      @worker_queue = Queue.new
      @workers = POOL_SIZE.times.map do
        Thread.new do
          while (task = @worker_queue.pop)
            begin
              case task[:type]
              when :fetch_status
                status = Git.get_status(task[:path])
                task[:result_queue] << {
                  type: :update_status,
                  path: task[:path],
                  status: status,
                  generation: task[:generation]
                }
              end
            rescue StandardError
              # Ignore worker errors
            end
          end
        end
      end

      # Initial Load
      Update.refresh_list(model)

      # Main Event Queue
      main_queue = Queue.new
      start_background_fetch(model, main_queue)

      RatatuiRuby.run do |tui|
        while model.running
          tui.draw do |frame|
            View.draw(model, tui, frame)
          end

          event = tui.poll_event(timeout: 0.1)

          # Process TUI Event
          cmd = nil
          if event.key?
            cmd = Update.handle(model, { type: :key_press, key: event })
          elsif event.mouse?
            cmd = Update.handle_mouse(model, event)
          elsif event.paste?
            cmd = Update.handle(model, { type: :paste, content: event.content })
          elsif event.resize?
            # Layout auto-handles
          elsif event.none?
            cmd = Update.handle(model, { type: :tick })
          end

          handle_command(cmd, model, tui, main_queue) if cmd

          # Process Background Queue
          while !main_queue.empty?
            msg = main_queue.pop(true) rescue nil
            next unless msg
            case msg[:type]
            when :trigger_resource_poll
              model.finish_background_activity
              model.set_message(msg[:message]) if msg[:message]
              start_resource_poll(model, main_queue)
            when :finish_background_activity
              model.finish_background_activity
            when :task_log_line
              model.append_task_log(msg[:line])
            when :task_complete
              model.finish_background_activity
              model.clear_task_log
              model.set_message(msg[:message]) if msg[:message]
              result = msg[:result]
              handle_command(result, model, tui, main_queue) if result
            else
              Update.handle(model, msg)
            end
          end

          # Refresh worktree list on a fast timer
          if model.worktree_poll_due?
            model.mark_worktree_poll_started
            Update.refresh_list(model)
            start_background_fetch(model, main_queue)
          end

          # Poll resources on a slower timer
          if model.has_resources? && model.resource_poll_due?
            start_resource_poll(model, main_queue)
          end
        end
      end

      # After TUI exits, cd into last worktree if one was resumed
      if model.resume_to && model.resume_to.exists?
        Dir.chdir(model.resume_to.path)
        # OSC 7 tells terminal emulators (Ghostty, tmux, iTerm2) the CWD for new panes
        print "\e]7;file://localhost#{model.resume_to.path}\e\\"
        exec ENV.fetch('SHELL', '/bin/zsh')
      end
    end

    def self.handle_command(cmd, model, tui, main_queue)
      return unless cmd

      if cmd == :start_background_fetch
        start_background_fetch(model, main_queue)
        return
      end

      # Cmd is a hash
      case cmd[:type]
      when :quit
        model.quit
      when :delete_worktree
        wt = cmd[:worktree]
        label = wt.branch || wt.name
        force_label = cmd[:force] ? " (force)" : ""

        if model.repository.has_teardown_script?
          # Teardown may be interactive — must suspend TUI
          model.set_message("Deleting #{label}#{force_label}...")
          tui.draw { |frame| View.draw(model, tui, frame) }

          RatatuiRuby.restore_terminal
          disable_mouse_tracking
          puts "\e[H\e[2J"
          puts "\e[1;36m🌊 Deleting #{label}#{force_label} 🌊\e[0m\n\n"
          result = Update.handle(model, cmd)
          RatatuiRuby.init_terminal
          handle_command(result, model, tui, main_queue)
        else
          # No teardown — run inline with log pane
          model.start_task_log("Deleting #{label}#{force_label}")
          model.set_message("Deleting #{label}#{force_label}...")
          model.start_background_activity

          force = cmd[:force] || false
          Thread.new do
            main_queue << { type: :task_log_line, line: "Removing worktree #{wt.path}..." }

            result = wt.delete!(force: force)

            if result[:success]
              if result[:warning]
                main_queue << { type: :task_log_line, line: "Warning: #{result[:warning]}" }
                main_queue << { type: :task_complete,
                                result: nil,
                                message: "Warning: #{result[:warning]}. Use 'D' to force delete." }
              else
                main_queue << { type: :task_log_line, line: "Done." }
                main_queue << { type: :task_complete,
                                result: { type: :refresh_list },
                                message: "Deleted worktree #{label}." }
              end
            else
              main_queue << { type: :task_log_line, line: "Error: #{result[:error]}" }
              main_queue << { type: :task_complete,
                              result: nil,
                              message: "Error deleting: #{result[:error]}. Use 'D' to force delete." }
            end
          rescue StandardError => e
            main_queue << { type: :task_log_line, line: "Error: #{e.message}" }
            main_queue << { type: :task_complete, result: nil }
          end
        end
      when :create_worktree, :refresh_list
        result = Update.handle(model, cmd)
        handle_command(result, model, tui, main_queue)
      when :cd_worktree
        model.resume_to = cmd[:worktree]
        model.quit
      when :switch_worktree
        suspend_tui_and_switch(cmd[:worktree], model, tui)
      when :acquire_resource
        cfg = model.repository.config
        repo_root = File.realpath(model.repository.root)
        env = { 'WOTR_ROOT' => repo_root, 'WOTR_WORKTREE' => cmd[:worktree].path }
        name = cmd[:name]
        wt_label = cmd[:worktree].branch || cmd[:worktree].name
        wt_path = cmd[:worktree].path
        acquire_msg = "Acquiring #{name} for #{wt_label}..."
        model.set_message(acquire_msg)
        model.start_background_activity
        Thread.new do
          cfg.run_acquire_background(name, env: env, chdir: wt_path)
          main_queue << { type: :trigger_resource_poll, message: "#{acquire_msg} done." }
        rescue StandardError
          main_queue << { type: :finish_background_activity }
        end
      when :run_action
        run_action(cmd[:name], cmd[:worktree], model, tui, main_queue)
      when :resume_worktree, :suspend_and_resume
        suspend_tui_and_run(cmd[:worktree], model, tui)
        Update.refresh_list(model)
        start_background_fetch(model, main_queue)
      end
    end

    def self.run_action(name, worktree, model, tui, main_queue)
      cfg = model.repository.config
      action = cfg.action(name)
      return unless action

      repo_root = File.realpath(model.repository.root)
      env = { 'WOTR_ROOT' => repo_root, 'WOTR_WORKTREE' => worktree.path }
      wt_label = worktree.branch || worktree.name
      switch_to_script = action["switch_to"]
      run_script = action["run"]

      if switch_to_script
        # Suspend TUI and switch to the command
        RatatuiRuby.restore_terminal
        disable_mouse_tracking
        puts "\e[H\e[2J"

        if run_script
          puts "\e[1;36m🌊 #{name}: preparing... 🌊\e[0m\n\n"
          cfg.send(:run_script_visible, run_script, env: env, chdir: worktree.path)
          puts
        end

        begin
          Dir.chdir(worktree.path) do
            if defined?(Bundler)
              Bundler.with_unbundled_env { system(env, "/bin/bash", "-c", switch_to_script) }
            else
              system(env, "/bin/bash", "-c", switch_to_script)
            end
          end
        rescue StandardError => e
          puts "Error: #{e.message}"
          print "Press Enter to return..."
          STDIN.gets rescue nil
        ensure
          RatatuiRuby.init_terminal
        end

        Update.refresh_list(model)
        start_background_fetch(model, main_queue)
      elsif run_script
        # Run in background with log pane
        model.start_task_log("#{name} (#{wt_label})")
        model.set_message("Running #{name}...")
        model.start_background_activity

        Thread.new do
          cfg.send(:write_tmpscript, "#!/usr/bin/env bash\n#{run_script}") do |path|
            IO.popen(env.merge("WOTR_LOG" => cfg.log_path || "/dev/null"),
                     [path], chdir: worktree.path, err: [:child, :out]) do |io|
              io.each_line { |line| main_queue << { type: :task_log_line, line: line.chomp } }
            end
          end

          if $?.success?
            main_queue << { type: :task_complete, message: "#{name} completed." }
          else
            main_queue << { type: :task_complete, message: "#{name} failed (exit #{$?.exitstatus})." }
          end
        rescue StandardError => e
          main_queue << { type: :task_log_line, line: "Error: #{e.message}" }
          main_queue << { type: :task_complete, result: nil }
        end
      end
    end

    def self.start_resource_poll(model, main_queue)
      model.mark_resource_poll_started
      model.start_background_activity
      model.set_message("Checking resource status...")

      cfg = model.repository.config
      if cfg.resource_names.empty?
        model.finish_background_activity
        model.set_message("Ready")
        return
      end

      worktrees = model.worktrees.dup
      repo_root = File.realpath(model.repository.root)
      env_base = { "WOTR_ROOT" => repo_root }

      Thread.new do
        begin
          icons_by_path = Hash.new { |h, k| h[k] = [] }

          cfg.resource_names.each do |name|
            icon = cfg.resource(name)&.fetch("icon", "•") || "•"

            if cfg.exclusive?(name)
              # Run per-worktree from its own dir; stop after finding the owner
              worktrees.each do |wt|
                env = env_base.merge("WOTR_WORKTREE" => wt.path)
                result = cfg.run_inquire(name, env: env, chdir: wt.path)
                next unless result[:ran] && result[:success]
                next unless result[:data]["status"] == "owned"

                owner = result[:data]["owner"]
                if owner
                  # Script returned explicit owner — map to the correct worktree
                  owner_real = File.realpath(owner) rescue owner
                  target = worktrees.find do |w|
                    wt_real = File.realpath(w.path) rescue w.path
                    owner_real == wt_real || owner_real.start_with?(wt_real + "/")
                  end
                  icons_by_path[target.path] << icon if target
                else
                  icons_by_path[wt.path] << icon
                end
                break
              end
            else
              # Compatible — run per worktree
              worktrees.each do |wt|
                env = env_base.merge("WOTR_WORKTREE" => wt.path)
                result = cfg.run_inquire(name, env: env, chdir: wt.path)
                next unless result[:ran] && result[:success]
                icons_by_path[wt.path] << icon if result[:data]["status"] == "compatible"
              end
            end
          rescue StandardError
            # Don't let one resource failure abort the rest
          end

          main_queue << {
            type: :update_resource_icons,
            icons_by_path: icons_by_path.transform_values(&:freeze)
          }
        rescue StandardError
          main_queue << { type: :finish_background_activity }
        end
      end
    end

    def self.can_continue_claude?
      # Claude stores conversations in ~/.claude/projects/<encoded-path>/
      # where the path has / replaced with -
      encoded = Dir.pwd.gsub("/", "-")
      project_dir = File.expand_path("~/.claude/projects/#{encoded}")
      return false unless Dir.exist?(project_dir)

      # Check for any conversation files
      Dir.glob(File.join(project_dir, "*.jsonl")).any?
    rescue StandardError
      false
    end

    def self.start_background_fetch(model, main_queue)
      # Increment generation to invalidate old results
      model.increment_generation
      current_gen = model.fetch_generation

      worktrees = model.worktrees

      # Batch fetch commit ages in background thread
      Thread.new do
        shas = worktrees.map(&:sha).compact
        ages = Git.get_commit_ages(shas, git: model.repository.git)

        worktrees.each do |wt|
          if (age = ages[wt.sha])
            main_queue << {
              type: :update_commit_age,
              path: wt.path,
              age: age,
              generation: current_gen
            }
          end
        end
      end

      # Queue Status Checks (Worker Pool)
      worktrees.each do |wt|
        @worker_queue << {
          type: :fetch_status,
          path: wt.path,
          result_queue: main_queue,
          generation: current_gen
        }
      end
    end

    def self.disable_mouse_tracking
      # Disable SGR and X10 mouse tracking that ratatui enables
      print "\e[?1000l\e[?1002l\e[?1003l\e[?1006l"
      $stdout.flush
    end

    def self.suspend_tui_and_switch(worktree, model, tui)
      RatatuiRuby.restore_terminal
      disable_mouse_tracking

      puts "\e[H\e[2J" # Clear screen

      # Run setup if this is a new worktree
      if worktree.needs_setup?
        begin
          worktree.run_setup!(visible: true)
          worktree.mark_setup_complete!
        rescue Interrupt
          puts "\nSetup aborted."
          RatatuiRuby.init_terminal
          return
        end
      end

      # Run switch hook (stop-all + start servers)
      result = worktree.run_switch!

      unless result[:ran]
        puts "No .wotr/switch hook found."
        print "Press Enter to return..."
        begin
          STDIN.gets
        rescue Interrupt
          nil
        end
        RatatuiRuby.init_terminal
        return
      end

      # After switch, cd into the worktree and quit TUI
      model.resume_to = worktree
      model.quit

      RatatuiRuby.init_terminal
    end

    def self.suspend_tui_and_run(worktree, model, tui)
      RatatuiRuby.restore_terminal
      disable_mouse_tracking

      puts "\e[H\e[2J" # Clear screen

      # Run setup if this is a new worktree
      if worktree.needs_setup?
        begin
          worktree.run_setup!(visible: true)
          worktree.mark_setup_complete!
        rescue Interrupt
          puts "\nSetup aborted."
          RatatuiRuby.init_terminal
          return
        end
      end

      worktree.run_switch!

      puts "Launching claude in #{worktree.path}..."
      begin
        Dir.chdir(worktree.path) do
          claude_cmd = can_continue_claude? ? "claude --continue" : "claude"
          if defined?(Bundler)
            Bundler.with_unbundled_env { system(claude_cmd) }
          else
            system(claude_cmd)
          end
        end
        # Track last resumed worktree for exit
        model.resume_to = worktree
      rescue StandardError => e
        puts "Error: #{e.message}"
        print "Press any key to return..."
        STDIN.getc
      ensure
        RatatuiRuby.init_terminal
      end
    end
  end
end
