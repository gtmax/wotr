# frozen_string_literal: true

require 'open3'
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

    # Run setup script or default symlinks
    # visible: true shows output to user, false runs silently
    def run_setup!(visible: true)
      if @repository.has_setup_script?
        run_custom_setup(visible: visible)
      else
        setup_default_symlinks
      end
    end

    # Run teardown script if it exists
    # Returns { ran: Boolean, success: Boolean }
    def run_teardown!
      return { ran: false } unless @repository.has_teardown_script?

      puts "\e[1;36m=== Running .cwt/teardown ===\e[0m"
      puts

      success = Dir.chdir(@path) do
        system({ "CWT_ROOT" => File.realpath(@repository.root) }, @repository.teardown_script_path)
      end

      puts

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
        wt_cmd = ["git", "-C", @repository.root, "worktree", "remove", @path]
        wt_cmd << "--force" if force

        _stdout, stderr, status = Open3.capture3(*wt_cmd)

        unless status.success?
          return { success: false, error: stderr.strip }
        end
      end

      # Step 3: Clean up empty parent directories under .worktrees/
      cleanup_empty_parents

      # Step 4: Delete Branch
      delete_branch(force: force)
    end

    # Fetch status (dirty flag) from git
    def fetch_status!
      stdout, status = Open3.capture2(
        "git", "--no-optional-locks", "-C", @path, "status", "--porcelain"
      )
      @dirty = status.success? && !stdout.strip.empty?
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

    def run_custom_setup(visible: true)
      if visible
        puts "\e[1;36m=== Running .cwt/setup ===\e[0m"
        puts
      end

      success = Dir.chdir(@path) do
        system({ "CWT_ROOT" => File.realpath(@repository.root) }, @repository.setup_script_path)
      end

      puts if visible

      unless success
        if visible
          puts "\e[1;33mWarning: .cwt/setup failed (exit code: #{$?.exitstatus})\e[0m"
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
      branch_flag = force ? "-D" : "-d"
      _stdout, stderr, status = Open3.capture3(
        "git", "-C", @repository.root, "branch", branch_flag, @branch
      )

      if status.success?
        { success: true }
      elsif force
        # Force delete failed - maybe branch doesn't exist
        if stderr.include?("not found")
          { success: true }
        else
          { success: false, error: "Worktree removed, but branch delete failed: #{stderr.strip}" }
        end
      else
        # Safe delete failed (unmerged commits) - worktree gone but branch kept
        { success: true, warning: "Worktree removed, but branch kept (unmerged). Use 'D' to force." }
      end
    end
  end
end
