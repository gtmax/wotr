# frozen_string_literal: true

require 'git'

module Wotr
  # Thin wrapper around git commands.
  # Business logic lives in Repository and Worktree classes.
  class Git
    def self.get_commit_ages(shas, git:)
      return {} if shas.empty?

      # Batch fetch commit times
      # %H: full hash, %cr: relative date
      output = git.lib.send(:command, '--no-optional-locks', 'show', '-s', '--format=%H|%cr', *shas)

      ages = {}
      output.each_line do |line|
        parts = line.strip.split('|')
        ages[parts[0]] = parts[1] if parts.size == 2
      end
      ages
    rescue ::Git::Error
      {}
    end

    def self.get_status(path)
      return { dirty: false } unless Dir.exist?(path)

      # Check for uncommitted changes
      # --no-optional-locks: Prevent git from writing to the index (lock contention)
      # --porcelain: stable output
      wt_git = ::Git.open(path)
      output = wt_git.lib.send(:command, '--no-optional-locks', 'status', '--porcelain')
      is_dirty = !output.strip.empty?

      { dirty: is_dirty }
    rescue StandardError
      { dirty: false }
    end

    def self.prune_worktrees(git:)
      git.lib.worktree_prune
    rescue ::Git::Error
      nil
    end
  end
end
