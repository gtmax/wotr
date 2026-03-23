# frozen_string_literal: true

require "ratatui_ruby"
require "thread"
require "pty"
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
      launch_dir = Dir.pwd
      repository = Repository.discover
      unless repository
        warn "wotr: not a git repository (or any parent). Run wotr from a git repo root."
        exit 1
      end

      # Require .wotr/config
      config_path = File.join(repository.root, Config::CONFIG_FILE)
      unless File.exist?(config_path)
        warn "wotr: no config found at #{config_path}"
        warn "Run 'wotr init' in this repo first."
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
      model.select_worktree_by_path(launch_dir)

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
              if msg[:status]
                model.log_status(msg[:line])
              else
                model.append_task_log(msg[:line])
              end
            when :task_complete
              model.finish_background_activity
              if msg[:message]
                failed = msg[:message].downcase.include?("fail")
                model.finish_task_log(failed ? "failed" : "done")
                model.log_status(msg[:message], style: failed ? :error : :dim)
                if failed
                  # Auto-switch to verbose and pin scroll to error
                  model.toggle_verbose unless model.verbose
                  model.pin_scroll_to_error
                end
              else
                model.finish_task_log
              end
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

          # Poll resources on a slower timer (skip while a task is running)
          if model.has_resources? && model.resource_poll_due? && !model.task_running?
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
      when :copy_log
        text = model.log_text
        if text.empty?
          model.log_status("Nothing to copy.")
        else
          IO.popen('pbcopy', 'w') { |io| io.write(text) }
          model.log_status("Log copied to clipboard.")
        end
      when :toggle_verbose
        model.toggle_verbose
      when :copy_log_path
        path = model.repository.config.log_path
        if path
          IO.popen('pbcopy', 'w') { |io| io.write(path) }
          model.log_status("Full log path #{path} copied to clipboard.")
        else
          model.log_status("No log path configured.")
        end
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
      when :create_worktree
        name = cmd[:name]
        model.set_mode(:normal)
        model.start_task_log("Creating #{name}")
        model.start_background_activity

        Thread.new do
          main_queue << { type: :task_log_line, line: "Creating worktree #{name}...", status: true }
          result = model.repository.create_worktree(name)

          if result[:success]
            main_queue << { type: :task_log_line, line: "Created. Running setup...", status: true }
            main_queue << { type: :task_complete,
                            result: { type: :post_create_worktree, worktree: result[:worktree], name: name } }
          else
            main_queue << { type: :task_log_line, line: "Error: #{result[:error]}" }
            main_queue << { type: :task_complete, message: "Failed to create #{name}: #{result[:error]}" }
          end
        rescue StandardError => e
          main_queue << { type: :task_log_line, line: "Error: #{e.message}" }
          main_queue << { type: :task_complete, result: nil }
        end
      when :post_create_worktree
        Update.refresh_list(model)
        start_background_fetch(model, main_queue)
        model.select_worktree_by_path(cmd[:worktree].path)
        handle_command({ type: :resume_worktree, worktree: cmd[:worktree] }, model, tui, main_queue)
      when :refresh_list
        model.start_task_log(nil)  # clear log without setting a label
        result = Update.handle(model, cmd)
        handle_command(result, model, tui, main_queue)
        start_resource_poll(model, main_queue) if model.has_resources?
      when :cd_worktree
        model.resume_to = cmd[:worktree]
        model.quit
      when :acquire_resource
        cfg = model.repository.config
        repo_root = File.realpath(model.repository.root)
        env = { 'WOTR_ROOT' => repo_root, 'WOTR_WORKTREE' => cmd[:worktree].path }
        name = cmd[:name]
        wt_label = cmd[:worktree].branch || cmd[:worktree].name
        wt_path = cmd[:worktree].path
        model.start_task_log("Acquiring #{name} for #{wt_label}")
        model.log_status("Acquiring #{name} for #{wt_label}...")
        model.start_background_activity

        Thread.new do
          script = cfg.resource(name)&.fetch("acquire", nil)
          success = true
          if script
            # Stream acquire output to log pane
            cfg.send(:write_tmpscript, "#!/usr/bin/env bash\n#{script}") do |path|
              IO.popen(env.merge("WOTR_LOG" => cfg.log_path || "/dev/null"),
                       [path], chdir: wt_path, err: [:child, :out]) do |io|
                io.each_line { |line| main_queue << { type: :task_log_line, line: line.chomp } }
              end
            end
            success = $?.success?
          end
          if success
            main_queue << { type: :task_complete,
                            result: { type: :refresh_after_acquire },
                            message: "Acquired #{name}." }
          else
            main_queue << { type: :task_complete,
                            message: "Failed to acquire #{name} (exit #{$?.exitstatus})." }
          end
        rescue StandardError => e
          main_queue << { type: :task_log_line, line: "Error: #{e.message}", status: true }
          main_queue << { type: :task_complete, message: "Failed to acquire #{name}." }
        end
      when :refresh_after_acquire
        # Continuation of acquire — don't clear log
        start_resource_poll(model, main_queue)
      when :run_action
        run_action(cmd[:name], cmd[:worktree], model, tui, main_queue)
      when :run_fg_steps
        run_fg_steps(cmd[:steps], cmd[:name], cmd[:env],
                     cmd[:worktree], model, tui, main_queue,
                     on_complete: cmd[:on_complete])
      when :resume_worktree
        resume_worktree(cmd[:worktree], model, tui, main_queue)
      when :run_hook_chain
        run_hook_chain(cmd[:hook], cmd[:worktree], model, tui, main_queue)
      end
    end

    def self.run_action(name, worktree, model, tui, main_queue)
      cfg = model.repository.config
      steps = cfg.action_steps(name)
      return if steps.empty?

      repo_root = File.realpath(model.repository.root)
      env = { 'WOTR_ROOT' => repo_root, 'WOTR_WORKTREE' => worktree.path }
      wt_label = worktree.branch || worktree.name

      # Split at first foreground step: bg runs in log pane, fg suspends TUI
      first_fg = steps.index { |s| s[:mode] == :foreground }
      bg_steps = first_fg ? steps[0...first_fg] : steps
      fg_steps = first_fg ? steps[first_fg..] : []

      if bg_steps.any?
        model.start_task_log("#{name} (#{wt_label})")
        model.log_status("Running #{name} action...")
        model.start_background_activity

        Thread.new do
          success = run_bg_steps_in_thread(bg_steps, env, worktree.path, cfg, main_queue)

          if success && fg_steps.any?
            main_queue << { type: :task_complete,
                            result: { type: :run_fg_steps, steps: fg_steps,
                                      name: name, worktree: worktree, env: env } }
          elsif success
            main_queue << { type: :task_complete, message: "#{name} completed." }
          end
        rescue StandardError => e
          main_queue << { type: :task_log_line, line: "Error: #{e.message}" }
          main_queue << { type: :task_complete, result: nil }
        end
      elsif fg_steps.any?
        # Starts with foreground — suspend TUI immediately
        run_fg_steps(fg_steps, name, env, worktree, model, tui, main_queue)
      end
    end

    # Run background steps in a thread, streaming output to the log pane.
    # Returns true if all steps succeeded (or failures were non-fatal).
    def self.run_bg_steps_in_thread(steps, env, chdir, cfg, main_queue)
      steps.each do |step|
        success = cfg.send(:write_tmpscript, "#!/usr/bin/env bash\n#{step[:script]}") do |path|
          run_bg_with_pty(path, env.merge("WOTR_LOG" => cfg.log_path || "/dev/null"), chdir, main_queue)
        end

        unless success
          if step[:stop_on_failure] != false
            main_queue << { type: :task_complete, message: "Failed." }
            return false
          else
            main_queue << { type: :task_log_line, line: "Step failed (continuing)" }
          end
        end
      end
      true
    end

    # Run a command in a PTY so it thinks it has a terminal (enabling line-buffered output).
    # Streams each line to main_queue and returns true/false for success.
    def self.run_bg_with_pty(path, env, chdir, main_queue)
      exit_status = nil
      Dir.chdir(chdir) do
        PTY.spawn(env, path) do |reader, _writer, pid|
          reader.each_line { |line| main_queue << { type: :task_log_line, line: line.chomp } }
        rescue Errno::EIO
          # Expected when child exits — PTY master gets EIO
        ensure
          _, status = Process.wait2(pid)
          exit_status = status
        end
      end
      exit_status&.success? || false
    end

    # Suspend TUI and run foreground steps sequentially.
    # on_complete: optional command hash to chain after fg steps finish.
    def self.run_fg_steps(steps, name, env, worktree, model, tui, main_queue, on_complete: nil)
      cfg = model.repository.config

      RatatuiRuby.restore_terminal
      disable_mouse_tracking
      puts "\e[H\e[2J"

      begin
        steps.each do |step|
          case step[:mode]
          when :background
            cfg.send(:run_script_visible, step[:script], env: env, chdir: worktree.path)
          when :foreground
            Dir.chdir(worktree.path) do
              if defined?(Bundler)
                Bundler.with_unbundled_env { system(env, "/bin/bash", "-c", step[:script]) }
              else
                system(env, "/bin/bash", "-c", step[:script])
              end
            end
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
      handle_command(on_complete, model, tui, main_queue) if on_complete
    end

    def self.start_resource_poll(model, main_queue)
      model.mark_resource_poll_started
      model.start_background_activity
      model.log_status("Refreshing resource status...")

      cfg = model.repository.config
      if cfg.resource_names.empty?
        model.finish_background_activity
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

            run_inquire = lambda do |wt|
              env = env_base.merge("WOTR_WORKTREE" => wt.path)
              main_queue << { type: :task_log_line, line: "inquire #{name} @ #{wt.branch || File.basename(wt.path)}" }
              result = cfg.run_inquire(name, env: env, chdir: wt.path)
              # Stream captured output for verbose mode
              if result[:stdout] && !result[:stdout].strip.empty?
                result[:stdout].each_line { |l| main_queue << { type: :task_log_line, line: l.chomp } }
              end
              result
            end

            if cfg.exclusive?(name)
              worktrees.each do |wt|
                result = run_inquire.call(wt)
                next unless result[:ran] && result[:success]
                next unless result[:data]["status"] == "owned"

                owner = result[:data]["owner"]
                if owner
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
              worktrees.each do |wt|
                result = run_inquire.call(wt)
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

    # Resume a worktree: run new hook (if first time) then chain to switch hook.
    def self.resume_worktree(worktree, model, tui, main_queue)
      cfg = model.repository.config
      env = { "WOTR_ROOT" => File.realpath(model.repository.root), "WOTR_WORKTREE" => worktree.path }

      if worktree.needs_setup?
        # Chain: run new hook → switch hook
        steps = cfg.hook_steps("new")
        model.log_status("No 'new' hook configured in .wotr/config") if steps.empty?
        on_complete = { type: :run_hook_chain, hook: "switch", worktree: worktree }

        run_hook_steps(steps, "new", env, worktree, model, tui, main_queue, on_complete: on_complete) do
          worktree.mark_setup_complete!
        end
      else
        steps = cfg.hook_steps("switch")
        if steps.empty?
          model.log_status("No 'switch' hook configured in .wotr/config")
        else
          run_hook_steps(steps, "switch", env, worktree, model, tui, main_queue)
        end
      end
    end

    # Run a hook by name (used by :run_hook_chain command for chaining new→switch).
    def self.run_hook_chain(hook_name, worktree, model, tui, main_queue)
      cfg = model.repository.config
      steps = cfg.hook_steps(hook_name)
      model.log_status("No '#{hook_name}' hook configured in .wotr/config") if steps.empty?
      env = { "WOTR_ROOT" => File.realpath(model.repository.root), "WOTR_WORKTREE" => worktree.path }
      run_hook_steps(steps, hook_name, env, worktree, model, tui, main_queue, clear_log: false)
    end

    # Unified hook/step execution: bg steps in log pane, fg steps suspend TUI.
    # on_complete: optional command hash to chain after all steps finish.
    # clear_log: whether to clear the log pane (false for chained hooks).
    # block: optional callback invoked after bg steps complete (e.g. mark_setup_complete!).
    def self.run_hook_steps(steps, label, env, worktree, model, tui, main_queue, on_complete: nil, clear_log: true, &after_bg)
      if steps.empty?
        after_bg&.call
        return handle_command(on_complete, model, tui, main_queue) if on_complete
        return
      end

      wt_label = worktree.branch || worktree.name
      cfg = model.repository.config

      # Split at first foreground step
      first_fg = steps.index { |s| s[:mode] == :foreground }
      bg_steps = first_fg ? steps[0...first_fg] : steps
      fg_steps = first_fg ? steps[first_fg..] : []

      if bg_steps.any?
        model.start_task_log("#{label} (#{wt_label})", clear: clear_log)
        model.log_status("Running #{label} hook...")
        model.start_background_activity

        Thread.new do
          success = run_bg_steps_in_thread(bg_steps, env, worktree.path, cfg, main_queue)
          after_bg&.call

          if success && fg_steps.any?
            main_queue << { type: :task_complete,
                            result: { type: :run_fg_steps, steps: fg_steps,
                                      name: label, worktree: worktree, env: env,
                                      on_complete: on_complete } }
          elsif success && on_complete
            main_queue << { type: :task_complete, result: on_complete }
          elsif success
            main_queue << { type: :task_complete, message: "#{label} completed." }
          else
            main_queue << { type: :task_complete, message: "#{label} failed." }
          end
        rescue StandardError => e
          main_queue << { type: :task_log_line, line: "Error: #{e.message}" }
          main_queue << { type: :task_complete, result: nil }
        end
      elsif fg_steps.any?
        after_bg&.call
        run_fg_steps(fg_steps, label, env, worktree, model, tui, main_queue, on_complete: on_complete)
      end
    end

    def self.disable_mouse_tracking
      # Disable SGR and X10 mouse tracking that ratatui enables
      print "\e[?1000l\e[?1002l\e[?1003l\e[?1006l"
      $stdout.flush
    end
  end
end
