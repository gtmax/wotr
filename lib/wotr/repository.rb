# frozen_string_literal: true

require 'git'
require 'fileutils'
require_relative 'config'

module Wotr
  class Repository
    WORKTREE_DIR = ".worktrees"
    CONFIG_DIR = ".wotr"

    attr_reader :root, :git

    # Find repo root from any path (including from within worktrees)
    def self.discover(start_path = Dir.pwd)
      output = ::Git::Lib.new.send(:command, 'rev-parse',
        '--path-format=absolute', '--git-common-dir', chdir: start_path)
      git_common_dir = output.strip
      return nil if git_common_dir.empty?

      # --git-common-dir returns /path/to/repo/.git, so strip the /.git
      new(git_common_dir.sub(%r{/\.git$}, ''))
    rescue ::Git::Error, Errno::ENOENT
      nil
    end

    def initialize(root)
      @root = File.expand_path(root)
      @git = ::Git.open(@root)
    end

    def worktrees_dir
      repo_name = File.basename(@root)
      parent = File.dirname(@root)
      File.join(parent, WORKTREE_DIR, repo_name)
    end

    def config_dir
      File.join(@root, CONFIG_DIR)
    end

    def user_config_dir
      File.join(Dir.home, '.wotr')
    end

    def user_setup_script_path
      File.join(user_config_dir, "setup")
    end

    def teardown_script_path
      File.join(config_dir, "teardown")
    end

    def has_user_setup_script?
      File.exist?(user_setup_script_path) && File.executable?(user_setup_script_path)
    end

    def has_teardown_script?
      File.exist?(teardown_script_path) && File.executable?(teardown_script_path)
    end

    def config
      @config ||= Config.load(@root)
    end

    # Returns Array<Worktree>
    def worktrees
      require_relative 'worktree'

      output = @git.lib.send(:command, 'worktree', 'list', '--porcelain')

      wts = parse_porcelain(output).map do |data|
        Worktree.new(
          repository: self,
          path: data[:path],
          branch: data[:branch],
          sha: data[:sha]
        )
      end

      # Sort by last commit time, most recent first
      shas = wts.map(&:sha).compact
      unless shas.empty?
        timestamps = {}
        begin
          output = @git.lib.send(:command, 'show', '--no-patch', '--format=%H %ct', *shas)
          output.each_line do |line|
            sha, ts = line.strip.split(' ', 2)
            timestamps[sha] = ts.to_i if sha && ts
          end
        rescue ::Git::Error
          # Fall back to unsorted
        end
        wts.sort_by! { |wt| -(timestamps[wt.sha] || 0) }
      end

      wts
    rescue ::Git::Error
      []
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

      # Ensure parent directories exist (e.g. .worktrees/feat/ for feat/my-feature)
      FileUtils.mkdir_p(File.dirname(path))

      # Create worktree — reuse existing branch, track remote, or create new
      if branch_exists?(safe_name)
        @git.lib.worktree_add(path, safe_name)
      elsif remote_branch_exists?(safe_name)
        # Create local branch tracking the remote branch
        @git.lib.send(:worktree_command,
          'worktree', 'add', '--track', '-b', safe_name, path, "origin/#{safe_name}")
      else
        # Branch from latest origin/default-branch (avoids touching local main)
        base = ENV["WOTR_START_POINT"]
        if base.nil? || base.strip.empty?
          @git.lib.send(:command, 'fetch', '--quiet', 'origin', default_branch)
          base = "origin/#{default_branch}"
        end
        @git.lib.send(:worktree_command,
          'worktree', 'add', '-b', safe_name, path, base)
      end

      # Create worktree object
      worktree = Worktree.new(
        repository: self,
        path: path,
        branch: safe_name,
        sha: nil # Will be populated on next list
      )

      # Mark as needing setup
      worktree.mark_needs_setup!

      { success: true, worktree: worktree }
    rescue ::Git::Error => e
      stderr = e.respond_to?(:result) ? e.result.stderr.strip : e.message
      { success: false, error: stderr }
    end

    private

    def branch_exists?(name)
      @git.lib.rev_parse("refs/heads/#{name}")
      true
    rescue ::Git::Error
      false
    end

    def remote_branch_exists?(name)
      # Fetch latest refs so we don't miss recently pushed branches
      @git.lib.send(:command, 'fetch', '--quiet', 'origin')
      @git.lib.rev_parse("refs/remotes/origin/#{name}")
      true
    rescue ::Git::Error
      false
    end

    def default_branch
      @default_branch ||= begin
        ref = @git.lib.send(:command, 'symbolic-ref', 'refs/remotes/origin/HEAD').strip
        ref.sub('refs/remotes/origin/', '')
      rescue ::Git::Error
        'main'
      end
    end


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
