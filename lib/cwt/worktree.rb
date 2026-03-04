# frozen_string_literal: true

require 'git'
require 'fileutils'

module Cwt
  class Worktree
    SETUP_MARKER = ".cwt_needs_setup"
    DEFAULT_SYMLINKS = [".env", "node_modules"].freeze

    attr_reader :repository, :path, :branch, :sha
    attr_accessor :dirty, :last_commit

    def initialize(repository:, path:, branch:, sha:)
      @repository = repository
      @path = File.expand_path(path)
      @branch = branch
      @sha = sha
      @dirty = nil
      @last_commit = nil
    end

    def name
      resolve = ->(p) { File.realpath(p) rescue File.expand_path(p) }
      resolve.call(@path).delete_prefix("#{resolve.call(@repository.worktrees_dir)}/")
    end

    def exists?
      Dir.exist?(@path)
    end

    def needs_setup?
      File.exist?(setup_marker_path)
    end

    def mark_needs_setup!
      FileUtils.touch(setup_marker_path)
    end

    def mark_setup_complete!
      File.delete(setup_marker_path) if File.exist?(setup_marker_path)
    end

    # Run setup scripts or default symlinks.
    # Execution order:
    #   1. ~/.cwt/setup  (user-level, if exists)
    #   2. .cwt/setup    (repo-level, if exists)
    #   3. defaults      (only if neither script exists)
    # Scripts can call `cwt-defaults` to opt into default behaviour explicitly.
    def run_setup!(visible: true)
      has_user = @repository.has_user_setup_script?
      has_repo = @repository.has_setup_script?

      if has_user || has_repo
        run_hook(@repository.user_setup_script_path, label: "~/.cwt/setup", visible: visible) if has_user
        run_hook(@repository.setup_script_path, label: ".cwt/setup", visible: visible) if has_repo
      else
        setup_default_symlinks
      end
    end

    # Run switch script if it exists (fires on every worktree jump)
    # Returns { ran: Boolean, success: Boolean }
    def run_switch!
      return { ran: false } unless @repository.has_switch_script?

      success = system(
        { "CWT_ROOT" => File.realpath(@repository.root), "CWT_WORKTREE" => @path },
        @repository.switch_script_path,
        chdir: @path
      )

      { ran: true, success: success }
    end

    # Run teardown script if it exists
    # Returns { ran: Boolean, success: Boolean }
    def run_teardown!
      return { ran: false } unless @repository.has_teardown_script?

      success = run_hook(@repository.teardown_script_path, label: ".cwt/teardown")
      { ran: true, success: success }
    end

    # Delete this worktree and its branch
    # force: true to force delete even with uncommitted changes
    # Returns { success: Boolean, error: String?, warning: String? }
    def delete!(force: false)
      # Step 0: Run teardown script if directory exists
      if exists?
        result = run_teardown!
        if result[:ran] && !result[:success] && !force
          return { success: false, error: "Teardown script failed. Use 'D' to force delete." }
        end
      end

      # Step 1: Cleanup symlinks/copies (Best effort)
      cleanup_symlinks

      # Step 2: Remove Worktree
      if exists?
        begin
          if force
            @repository.git.lib.send(:worktree_command, 'worktree', 'remove', @path, '--force')
          else
            @repository.git.lib.worktree_remove(@path)
          end
        rescue ::Git::Error => e
          stderr = e.respond_to?(:result) ? e.result.stderr.strip : e.message
          return { success: false, error: stderr }
        end
      end

      # Step 3: Clean up empty parent directories under .worktrees/
      cleanup_empty_parents

      # Step 4: Delete Branch
      delete_branch(force: force)
    end

    # Fetch status (dirty flag) from git
    def fetch_status!
      wt_git = ::Git.open(@path)
      output = wt_git.lib.send(:command, '--no-optional-locks', 'status', '--porcelain')
      @dirty = !output.strip.empty?
      @dirty
    rescue StandardError
      @dirty = false
    end

    # Hash representation for compatibility
    def to_h
      {
        path: @path,
        branch: @branch,
        sha: @sha,
        dirty: @dirty,
        last_commit: @last_commit
      }
    end

    private

    def setup_marker_path
      File.join(@path, SETUP_MARKER)
    end

    def run_hook(script_path, label:, visible: true)
      if visible
        puts "\e[1;36m=== Running #{label} ===\e[0m"
        puts
      end

      success = system(
        { "CWT_ROOT" => File.realpath(@repository.root) },
        script_path,
        chdir: @path
      )

      puts if visible

      unless success
        if visible
          puts "\e[1;33mWarning: #{label} failed (exit code: #{$?.exitstatus})\e[0m"
          print "Press Enter to continue or Ctrl+C to abort..."
          begin
            STDIN.gets
          rescue Interrupt
            raise
          end
        end
      end

      success
    end

    def setup_default_symlinks
      DEFAULT_SYMLINKS.each do |file|
        source = File.join(@repository.root, file)
        target = File.join(@path, file)

        if File.exist?(source) && !File.exist?(target)
          FileUtils.ln_s(source, target)
        end
      end
    end

    def cleanup_symlinks
      DEFAULT_SYMLINKS.each do |file|
        target_path = File.join(@path, file)
        File.delete(target_path) if File.exist?(target_path)
      rescue StandardError
        nil
      end
    end

    def cleanup_empty_parents
      worktrees_dir = @repository.worktrees_dir
      dir = File.dirname(@path)
      while dir != worktrees_dir && dir.start_with?(worktrees_dir)
        break unless Dir.exist?(dir) && (Dir.entries(dir) - %w[. ..]).empty?
        Dir.rmdir(dir)
        dir = File.dirname(dir)
      end
    end

    def delete_branch(force: false)
      if force
        @repository.git.lib.branch_delete(@branch)
      else
        @repository.git.lib.send(:command, 'branch', '-d', @branch)
      end
      { success: true }
    rescue ::Git::Error => e
      stderr = e.respond_to?(:result) ? e.result.stderr.strip : e.message

      if force
        if stderr.include?("not found")
          { success: true }
        else
          { success: false, error: "Worktree removed, but branch delete failed: #{stderr}" }
        end
      else
        # Safe delete failed (unmerged commits) - worktree gone but branch kept
        { success: true, warning: "Worktree removed, but branch kept (unmerged). Use 'D' to force." }
      end
    end
  end
end
