# frozen_string_literal: true

require 'json'

module Wotr
  class CLI
    INIT_TEMPLATE = <<~YAML
      # .wotr/config — wotr configuration
      # See: https://github.com/gtmax/wotr
      #
      # Hooks are arrays of steps. Each step is either:
      #   - bg: <script>   # runs in TUI log pane (non-interactive)
      #   - fg: <script>   # suspends TUI, takes the terminal (interactive)

      # hooks:
      #   new:
      #     - bg: wotr-default-setup && pnpm install --frozen-lockfile
      #   switch:
      #     - fg: wotr-launch-claude

      # actions:
      #   lint:
      #     key: l
      #     steps:
      #       - bg: pnpm lint
      #   test:
      #     key: t
      #     steps:
      #       - bg: pnpm test

      # resources:
      #   web-server:
      #     icon: 💻
      #     exclusive: true
      #     description: Web development server
      #     acquire: |
      #       bin/dev stop-all
      #       bin/dev start
      #     inquire: |
      #       pid=$(lsof -ti :3333 -sTCP:LISTEN 2>/dev/null | head -1)
      #       if [ -z "$pid" ]; then
      #         wotr-output status=unowned
      #         exit 0
      #       fi
      #       cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')
      #       root="$cwd"
      #       while [ "$root" != "/" ] && [ ! -e "$root/.git" ]; do root=$(dirname "$root"); done
      #       wotr-output status=owned owner="$root"
      #   db-schema:
      #     icon: 💾
      #     exclusive: false
      #     description: Database schema
      #     acquire: |
      #       bin/dev db:migrate
      #     inquire: |
      #       wotr-output status=compatible
    YAML

    INIT_LOCAL_TEMPLATE = <<~YAML
      # .wotr/config.local — personal wotr overrides (not committed to git)
      #
      # Same format as .wotr/config. Values here are deep-merged on top of
      # the shared config. Use this for personal actions, editor preferences,
      # or machine-specific hooks.

      # actions:
      #   editor:
      #     key: e
      #     steps:
      #       - fg: nvim .
    YAML

    USAGE = <<~USAGE
      wotr — git worktree manager

      Usage:
        wotr                          Launch TUI
        wotr --repo-path <path> ...   Run any command against a different repo
        wotr acquire <resource>       Run resource acquire script
        wotr inquire [resource]       Run resource inquire script(s), print JSON
        wotr resources                List configured resources
        wotr run <hook>               Run a config hook (e.g. new, switch)
        wotr init                     Scaffold .wotr/config in current repo
        wotr skill install            Install wotr-config skill for Claude Code
        wotr status [--json]          Show current branch
        wotr list                     List all worktrees
        wotr log [-f] [-n N] [--path] Tail the scripts log
        wotr update                   Update to latest version from GitHub
        wotr uninstall                Uninstall wotr and remove all binaries
        wotr version                  Print version
        wotr help                     Show this help

      Environment:
        WOTR_ROOT       Repo root (set automatically in scripts)
        WOTR_WORKTREE   Current worktree path (set automatically in scripts)
    USAGE

    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv
    end

    def run
      cmd = @argv[0]
      args = @argv[1..]

      case cmd
      when "version"                  then cmd_version
      when "help", "--help", "-h"     then cmd_help
      when "init"                     then cmd_init
      when "skill"                    then cmd_skill(args)
      when "status"                   then cmd_status(args)
      when "list"                     then cmd_list
      when "acquire"                  then cmd_acquire(args)
      when "inquire"                  then cmd_inquire(args)
      when "resources"                then cmd_resources
      when "run"                      then cmd_run(args)
      when "log"                      then cmd_log(args)
      when "update"                   then cmd_update
      when "uninstall"                then cmd_uninstall
      else
        warn "wotr: unknown command '#{cmd}'"
        warn "Run 'wotr help' for usage."
        exit 1
      end
    end

    private

    def cmd_version
      puts Wotr::VERSION
    end

    def cmd_help
      puts USAGE
    end

    def cmd_init
      repo = find_repo_or_exit
      config_path = File.join(repo.root, ".wotr", "config")

      if File.exist?(config_path)
        puts "#{config_path} already exists."
        exit 0
      end

      if claude_available?
        puts <<~MSG

          wotr can generate a tailored .wotr/config by analyzing your project
          with Claude Code. It will look at your dev scripts, Docker setup,
          database tooling, and ports to propose hooks and resources.

        MSG

        print "Use Claude Code to generate config? [Y/n] "
        answer = $stdin.gets&.strip&.downcase || ""

        if answer == "n"
          basic_init(config_path)
        else
          skill_dir = File.join(gem_data_dir, "skills", "wotr-config")
          skill_md = File.join(skill_dir, "SKILL.md")
          refs_dir = File.join(skill_dir, "references")

          unless File.exist?(skill_md)
            warn "wotr: skill data not found in gem (expected #{skill_md})"
            warn "Falling back to basic init."
            basic_init(config_path)
            return
          end

          # Read skill materials and pass as system prompt context
          skill_content = File.read(skill_md)
          Dir.glob(File.join(refs_dir, "*.md")).sort.each do |ref|
            next if File.basename(ref) == "skill-install.md"
            skill_content += "\n\n---\n# #{File.basename(ref)}\n\n#{File.read(ref)}"
          end

          # Append skill-install instructions last (only relevant during wotr init)
          install_ref = File.join(refs_dir, "skill-install.md")
          if File.exist?(install_ref)
            skill_content += "\n\n---\n# #{File.basename(install_ref)}\n\n#{File.read(install_ref)}"
          end

          puts "\nLaunching Claude Code to generate .wotr/config...\n\n"
          exec("claude",
               "--append-system-prompt", skill_content,
               "Analyze this project and generate a .wotr/config file. Follow the wotr-config workflow in your system prompt.")
        end
      else
        basic_init(config_path)
      end
    end

    def basic_init(config_path)
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, INIT_TEMPLATE)
      puts "Created #{config_path}"

      local_path = config_path + ".local"
      unless File.exist?(local_path)
        File.write(local_path, INIT_LOCAL_TEMPLATE)
        puts "Created #{local_path}"
      end

      puts "Edit them to match your project's dev setup."
    end

    def cmd_skill(args)
      subcmd = args[0]

      case subcmd
      when "install"
        skill_install
      else
        warn "Usage: wotr skill install"
        warn ""
        warn "Installs the wotr-config skill into this project so Claude Code"
        warn "can help you update .wotr/config anytime."
        exit 1
      end
    end

    def skill_install
      repo = find_repo_or_exit
      skill_dir = File.join(gem_data_dir, "skills", "wotr-config")

      unless File.directory?(skill_dir)
        warn "wotr: skill data not found in gem (expected #{skill_dir})"
        exit 1
      end

      target = File.join(repo.root, ".claude", "skills", "wotr-config")

      reinstall = File.exist?(File.join(target, "SKILL.md"))

      require 'fileutils'
      Dir.glob(File.join(skill_dir, "**", "*")).each do |src|
        next if File.directory?(src)
        next if File.basename(src) == "skill-install.md"
        rel = src.sub("#{skill_dir}/", "")
        dst = File.join(target, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src, dst)
      end
      verb = reinstall ? "Updated" : "Installed"
      puts "#{verb} wotr-config skill at #{target}/"
    end

    def claude_available?
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, "claude"))
      end
    end

    def gem_data_dir
      File.expand_path("../../data", __dir__)
    end

    def cmd_status(args)
      repo = find_repo_or_exit
      branch = current_branch(repo)

      if args.include?("--json")
        puts JSON.pretty_generate({ branch: branch })
      else
        puts "Branch: #{branch}"
      end
    end

    def cmd_list
      repo = find_repo_or_exit
      worktrees = repo.worktrees

      if worktrees.empty?
        puts "(no worktrees)"
        return
      end

      worktrees.each do |wt|
        marker = wt.path == Dir.pwd ? " ← current" : ""
        puts "  #{wt.branch}  #{wt.path}#{marker}"
      end
    end

    def cmd_acquire(args)
      name = args[0]
      if name.nil?
        warn "Usage: wotr acquire <resource>"
        exit 1
      end

      repo = find_repo_or_exit
      cfg = config(repo)

      unless cfg.resource(name)
        warn "wotr: resource '#{name}' not found in .wotr/config"
        exit 1
      end

      puts "Acquiring #{name}..."
      result = cfg.run_acquire(name, env: wotr_env(repo), chdir: Dir.pwd)

      unless result[:ran]
        warn "wotr: no acquire script for resource '#{name}'"
        exit 1
      end

      exit 1 unless result[:success]
    end

    def cmd_inquire(args)
      repo = find_repo_or_exit
      cfg = config(repo)

      names = args.empty? ? cfg.resource_names : args

      if names.empty?
        puts "(no resources configured)"
        return
      end

      failed = false
      names.each do |name|
        unless cfg.resource(name)
          warn "wotr: resource '#{name}' not found in .wotr/config"
          failed = true
          next
        end

        result = cfg.run_inquire(name, env: wotr_env(repo), chdir: Dir.pwd)

        unless result[:ran]
          warn "wotr: no inquire script for resource '#{name}'"
          failed = true
          next
        end

        unless result[:success]
          warn "wotr: inquire script for '#{name}' failed"
          failed = true
          next
        end

        puts JSON.generate(result[:data])
      end

      exit 1 if failed
    end

    def cmd_resources
      repo = find_repo_or_exit
      cfg = config(repo)

      names = cfg.resource_names
      if names.empty?
        puts "(no resources configured)"
        return
      end

      names.each do |name|
        res = cfg.resource(name)
        icon = res["icon"] || "•"
        desc = res["description"] || ""
        kind = res["exclusive"] == true ? "exclusive" : "compatible"
        puts "#{icon}  #{name} (#{kind})"
        puts "   #{desc}" unless desc.empty?
      end
    end

    def cmd_run(args)
      hook_name = args[0]
      if hook_name.nil?
        warn "Usage: wotr run <hook>"
        exit 1
      end

      repo = find_repo_or_exit
      cfg = config(repo)

      unless cfg.hook(hook_name)
        warn "wotr: hook '#{hook_name}' not found in .wotr/config"
        exit 1
      end

      result = cfg.run_hook(hook_name, env: wotr_env(repo), chdir: Dir.pwd, visible: true)

      unless result[:ran]
        warn "wotr: hook '#{hook_name}' did not run"
        exit 1
      end

      exit 1 unless result[:success]
    end

    def cmd_log(args)
      repo = find_repo_or_exit
      log_file = config(repo).log_path

      if args.include?("--path")
        puts log_file
        return
      end

      unless File.exist?(log_file)
        warn "wotr: no log file at #{log_file}"
        exit 1
      end

      follow = args.include?("-f")
      n = args.each_cons(2).find { |a, _| a == "-n" }&.last || "50"

      tail_args = ["-n", n.to_s]
      tail_args << "-f" if follow
      exec("tail", *tail_args, log_file)
    end

    REPO_URL = "gtmax/wotr"

    def cmd_update
      puts "Updating wotr..."
      # Re-run the install script from GitHub
      exec("/bin/bash", "-c",
        "curl -fsSL https://raw.githubusercontent.com/#{REPO_URL}/main/install.sh | bash")
    end

    def cmd_uninstall
      puts "Uninstalling wotr..."
      ruby_bin = RbConfig.ruby
      gem_bin = File.join(File.dirname(ruby_bin), "gem")
      brew_prefix = ENV.fetch("HOMEBREW_PREFIX", "/opt/homebrew")

      # Remove gem
      system(gem_bin, "uninstall", "wotr", "-x")

      # Remove binaries
      %w[wotr wotr-default-setup wotr-launch-claude wotr-output wotr-rename-tab].each do |bin|
        path = File.join(brew_prefix, "bin", bin)
        if File.exist?(path)
          File.delete(path)
          puts "  Removed #{path}"
        end
      end

      puts "wotr uninstalled."
    end

    # --- Helpers ---

    def find_repo_or_exit
      repo = Repository.discover(Dir.pwd)
      unless repo
        warn "wotr: not inside a git repository"
        exit 1
      end
      repo
    end

    def config(repo)
      @config ||= Config.load(repo.root)
    end

    def current_branch(repo)
      repo.git.current_branch
    rescue StandardError
      "unknown"
    end

    def wotr_env(repo)
      {
        "WOTR_ROOT"     => File.realpath(repo.root),
        "WOTR_WORKTREE" => Dir.pwd
      }
    end
  end
end
