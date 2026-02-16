# frozen_string_literal: true

require 'open3'
require 'fileutils'

module Cwt
  class Repository
    WORKTREE_DIR = ".worktrees"
    CONFIG_DIR = ".cwt"

    attr_reader :root

    # Find repo root from any path (including from within worktrees)
    def self.discover(start_path = Dir.pwd)
      Dir.chdir(start_path) do
        stdout, status = Open3.capture2("git", "rev-parse", "--path-format=absolute", "--git-common-dir")
        return nil unless status.success?

        git_common_dir = stdout.strip
        return nil if git_common_dir.empty?

        # --git-common-dir returns /path/to/repo/.git, so strip the /.git
        new(git_common_dir.sub(%r{/\.git$}, ''))
      end
    rescue Errno::ENOENT
      nil
    end

    def initialize(root)
      @root = File.expand_path(root)
    end

    def worktrees_dir
      File.join(@root, WORKTREE_DIR)
    end

    def config_dir
      File.join(@root, CONFIG_DIR)
    end

    def setup_script_path
      File.join(config_dir, "setup")
    end

    def teardown_script_path
      File.join(config_dir, "teardown")
    end

    def has_setup_script?
      File.exist?(setup_script_path) && File.executable?(setup_script_path)
    end

    def has_teardown_script?
      File.exist?(teardown_script_path) && File.executable?(teardown_script_path)
    end

    # Returns Array<Worktree>
    def worktrees
      require_relative 'worktree'

      stdout, status = Open3.capture2("git", "-C", @root, "worktree", "list", "--porcelain")
      return [] unless status.success?

      parse_porcelain(stdout).map do |data|
        Worktree.new(
          repository: self,
          path: data[:path],
          branch: data[:branch],
          sha: data[:sha]
        )
      end
    end

    def find_worktree(name_or_path)
      # Normalize path for comparison (handles macOS /var -> /private/var symlinks)
      normalized_path = begin
        File.realpath(name_or_path)
      rescue Errno::ENOENT
        File.expand_path(name_or_path)
      end

      worktrees.find do |wt|
        wt.name == name_or_path || wt.branch == name_or_path || wt.path == normalized_path
      end
    end

    # Create a new worktree with the given name
    # Returns { success: true, worktree: Worktree } or { success: false, error: String }
    def create_worktree(name)
      require_relative 'worktree'

      # Sanitize name (allow / for branch name hierarchy)
      safe_name = name.strip
                      .gsub(%r{[^a-zA-Z0-9_\-/]}, '_')
                      .gsub(%r{/+}, '/')
                      .gsub(%r{^/|/$}, '')
      path = File.join(worktrees_dir, safe_name)
      absolute_path = File.join(@root, WORKTREE_DIR, safe_name)

      # Ensure parent directories exist (e.g. .worktrees/feat/ for feat/my-feature)
      FileUtils.mkdir_p(File.dirname(path))

      # Create worktree with new branch
      cmd = ["git", "-C", @root, "worktree", "add", "-b", safe_name, path]
      _stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        return { success: false, error: stderr }
      end

      # Create worktree object
      worktree = Worktree.new(
        repository: self,
        path: absolute_path,
        branch: safe_name,
        sha: nil # Will be populated on next list
      )

      # Mark as needing setup
      worktree.mark_needs_setup!

      { success: true, worktree: worktree }
    end

    private

    def parse_porcelain(output)
      worktrees = []
      current = {}

      output.each_line do |line|
        if line.start_with?("worktree ")
          if current.any?
            worktrees << current
            current = {}
          end
          current[:path] = line.sub("worktree ", "").strip
        elsif line.start_with?("HEAD ")
          current[:sha] = line.sub("HEAD ", "").strip
        elsif line.start_with?("branch ")
          current[:branch] = line.sub("branch ", "").strip.sub("refs/heads/", "")
        end
      end
      worktrees << current if current.any?
      worktrees
    end
  end
end
