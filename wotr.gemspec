# frozen_string_literal: true

require_relative 'lib/wotr/version'

Gem::Specification.new do |spec|
  spec.name = 'wotr'
  spec.version = Wotr::VERSION
  spec.authors = ['Ben Garcia']
  spec.email = ['hey@bengarcia.dev']

  spec.summary = 'A TUI tool to manage Git Worktrees for AI coding agents.'
  spec.description = 'Manages git worktrees for Claude Code sessions.'
  spec.homepage = 'https://github.com/gtmax/wotr'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['source_code_uri'] = 'https://github.com/gtmax/wotr'
  spec.metadata['changelog_uri'] = 'https://github.com/gtmax/wotr/blob/main/CHANGELOG.md'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    Dir["{data,exe,lib,sig}/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md", "CODE_OF_CONDUCT.md"]
  end
  spec.bindir = 'exe'
  spec.executables = ['wotr', 'wotr-default-setup', 'wotr-launch-claude', 'wotr-output', 'wotr-rename-tab']
  spec.require_paths = ['lib']

  spec.add_dependency 'git'
  spec.add_dependency 'ratatui_ruby'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
