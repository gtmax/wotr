# frozen_string_literal: true

require 'yaml'
require 'tempfile'
require 'fileutils'
require 'open3'
require 'json'

module Wotr
  class Config
    CONFIG_FILE = ".wotr/config"

    CONFIG_LOCAL_FILE = ".wotr/config.local"

    def self.load(root)
      data = {}

      path = File.join(root, CONFIG_FILE)
      if File.exist?(path)
        data = YAML.safe_load(File.read(path)) || {}
      end

      local_path = File.join(root, CONFIG_LOCAL_FILE)
      if File.exist?(local_path)
        local_data = YAML.safe_load(File.read(local_path)) || {}
        data = deep_merge(data, local_data)
      end

      new(data, root: root)
    rescue Psych::SyntaxError => e
      warn "wotr: config parse error: #{e.message}"
      new({}, root: root)
    end

    def self.deep_merge(base, override)
      base.merge(override) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end

    def initialize(data, root: nil)
      @data = data
      @log_path = root ? File.join(File.dirname(root), ".worktrees", File.basename(root), ".wotr", "wotr.log") : nil
    end

    def log_path
      @log_path
    end

    def hook(name)
      (@data["hooks"] || {})[name.to_s]
    end

    # Returns normalized array of { mode: :background|:foreground, script: String }
    def hook_steps(name)
      normalize_steps(hook(name))
    end

    def resource(name)
      (@data["resources"] || {})[name.to_s]
    end

    def resource_names
      (@data["resources"] || {}).keys
    end

    def action(name)
      (@data["actions"] || {})[name.to_s]
    end

    def action_names
      (@data["actions"] || {}).keys
    end

    # Returns normalized array of { mode: :background|:foreground, script: String }
    def action_steps(name)
      act = action(name)
      return [] unless act.is_a?(Hash)

      normalize_steps(act["steps"])
    end

    def exclusive?(name)
      resource(name)&.fetch("exclusive", false) == true
    end

    def empty?
      @data.empty?
    end

    # Run a named hook (new, switch, teardown) via CLI (wotr run <hook>).
    # prompt_on_failure: when true and visible, pause for Enter on failure so the user
    # can read the error before the TUI redraws. Set false for hooks (e.g. teardown) where
    # the caller surfaces failures through its own UI.
    # Returns { ran: Boolean, success: Boolean, ran_foreground: Boolean }
    def run_hook(name, env: {}, chdir: Dir.pwd, visible: false, prompt_on_failure: true)
      steps = hook_steps(name)
      return { ran: false, ran_foreground: false } if steps.empty?

      if visible
        puts "\e[1;36m🌊 Running hook: #{name} 🌊\e[0m\n\n"
      end

      ran_foreground = false
      last_success = true

      steps.each do |step|
        case step[:mode]
        when :background
          last_success = run_script_visible(step[:script], env: env, chdir: chdir)
        when :foreground
          ran_foreground = true
          Dir.chdir(chdir) do
            if defined?(Bundler)
              Bundler.with_unbundled_env { last_success = system(env, "/bin/bash", "-c", step[:script]) }
            else
              last_success = system(env, "/bin/bash", "-c", step[:script])
            end
          end
        end

        break if !last_success && step[:stop_on_failure] != false
      end

      puts if visible

      if visible && !last_success && prompt_on_failure
        puts "\e[1;33mWarning: hook '#{name}' failed\e[0m"
        print "Press Enter to continue or Ctrl+C to abort..."
        begin
          STDIN.gets
        rescue Interrupt
          raise
        end
      end

      { ran: true, success: !!last_success, ran_foreground: ran_foreground }
    end

    # Run the acquire script. Output flows to terminal and log.
    # Returns { ran: Boolean, success: Boolean }
    def run_acquire(name, env: {}, chdir: Dir.pwd)
      script = resource(name)&.fetch("acquire", nil)
      return { ran: false } if script.nil?

      success = run_script_visible(script, env: env, chdir: chdir)
      { ran: true, success: !!success }
    end

    # Run the acquire script in the background (no terminal output; everything logged).
    # Returns { ran: Boolean, success: Boolean }
    def run_acquire_background(name, env: {}, chdir: Dir.pwd)
      script = resource(name)&.fetch("acquire", nil)
      return { ran: false } if script.nil?

      _stdout, success = run_script_capture(script, env: env, chdir: chdir, label: "acquire:#{name}")
      { ran: true, success: success }
    end

    # Run the inquire script. Captures stdout as JSON; stderr goes to log.
    # Exit 0 + JSON on stdout = successful inquiry. Exit non-zero = script error.
    # Returns { ran: Boolean, success: Boolean, data: Hash }
    def run_inquire(name, env: {}, chdir: Dir.pwd)
      script = resource(name)&.fetch("inquire", nil)
      return { ran: false } if script.nil?

      stdout, success = run_script_capture(script, env: env, chdir: chdir, label: "inquire:#{name}", timeout: 15)
      data = parse_json_output(stdout)

      { ran: true, success: !!success, data: data, stdout: stdout }
    end

    private

    # Normalize a step array into [{ mode:, script:, stop_on_failure: }] hashes.
    def normalize_steps(raw)
      return [] if raw.nil?
      return [] unless raw.is_a?(Array)

      raw.filter_map do |step|
        if step.is_a?(Hash)
          stop = step.fetch("stop_on_failure", true)
          if step["fg"]
            { mode: :foreground, script: step["fg"], stop_on_failure: stop }
          elsif step["bg"]
            { mode: :background, script: step["bg"], stop_on_failure: stop }
          end
        end
      end
    end

    # Run a script with output to terminal (tee'd to log as well).
    def run_script_visible(content, env: {}, chdir: Dir.pwd)
      write_tmpscript("#!/usr/bin/env bash\n#{content}") do |path|
        full_env = env.merge("WOTR_LOG" => log_dest)
        system(full_env,
          "/bin/bash", "-c",
          %(mkdir -p "$(dirname "$WOTR_LOG")" 2>/dev/null; { "#{path}"; } 2>&1 | tee -a "$WOTR_LOG"; exit ${PIPESTATUS[0]}),
          chdir: chdir)
      end
    end

    # Run a script capturing stdout; both stdout and stderr are logged.
    # Pass timeout: (seconds) to kill the process if it runs too long.
    def run_script_capture(content, env: {}, chdir: Dir.pwd, label: nil, timeout: nil)
      write_tmpscript("#!/usr/bin/env bash\n#{content}") do |path|
        full_env = env.merge("WOTR_LOG" => log_dest)
        if timeout
          stdout = +""
          stderr = +""
          status = nil
          Open3.popen3(full_env, path, chdir: chdir) do |_in, out, err, wait_thr|
            _in.close
            deadline = Time.now + timeout
            readers = [out, err]
            until readers.empty?
              remaining = deadline - Time.now
              if remaining <= 0
                Process.kill('TERM', wait_thr.pid) rescue nil
                sleep 0.1
                Process.kill('KILL', wait_thr.pid) rescue nil
                stderr << "\nwotr: killed after #{timeout}s timeout"
                break
              end
              ready = IO.select(readers, nil, nil, [remaining, 0.5].min)
              next unless ready

              ready[0].each do |io|
                begin
                  chunk = io.read_nonblock(8192)
                  (io == out ? stdout : stderr) << chunk
                rescue IO::WaitReadable
                  # retry on next select
                rescue EOFError
                  readers.delete(io)
                end
              end
            end
            status = wait_thr.value
          end
          full_label = [label || path, File.basename(chdir)].compact.join(' @ ')
          append_to_log(stdout, stderr, label: full_label)
          [stdout, status&.success? || false]
        else
          stdout, stderr, status = Open3.capture3(full_env, path, chdir: chdir)
          full_label = [label || path, File.basename(chdir)].compact.join(' @ ')
          append_to_log(stdout, stderr, label: full_label)
          [stdout, status.success?]
        end
      end
    end

    LOG_MAX_LINES = 1024

    def append_to_log(stdout, stderr, label: nil)
      return unless @log_path

      FileUtils.mkdir_p(File.dirname(@log_path))

      ts = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      prefix = label ? "[#{ts}] [#{label}]" : "[#{ts}]"
      new_lines = if stdout.strip.empty? && stderr.strip.empty?
                    ["#{prefix} (no output)"]
                  else
                    [].tap do |l|
                      l << "#{prefix} stdout: #{stdout.strip}" unless stdout.strip.empty?
                      l << "#{prefix} stderr: #{stderr.strip}" unless stderr.strip.empty?
                    end
                  end

      existing = File.exist?(@log_path) ? File.readlines(@log_path) : []
      trimmed = (existing + new_lines.map { |l| "#{l}\n" }).last(LOG_MAX_LINES)
      File.write(@log_path, trimmed.join)
    end

    def write_tmpscript(content)
      tmpfile = Tempfile.new(["wotr-", ".sh"])
      begin
        tmpfile.write(content)
        tmpfile.close
        FileUtils.chmod(0755, tmpfile.path)
        yield tmpfile.path
      ensure
        tmpfile.unlink
      end
    end

    def parse_json_output(raw)
      return {} if raw.nil? || raw.strip.empty?
      JSON.parse(raw.strip)
    rescue JSON::ParserError
      {}
    end

    def log_dest
      @log_path || "/dev/null"
    end
  end
end
