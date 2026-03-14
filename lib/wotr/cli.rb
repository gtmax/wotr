# frozen_string_literal: true

require 'json'

module Wotr
  class CLI
    INIT_TEMPLATE = <<~YAML
      # .wotr/config — wotr configuration
      # See: https://github.com/gtmax/wotr

      # hooks:
      #   new: |
      #     wotr-default-setup
      #     # pnpm install --frozen-lockfile
      #   switch: |
      #     # wotr acquire web-server

      # actions:
      #   lint:
      #     key: l
      #     run: pnpm lint
      #   test:
      #     key: t
      #     run: pnpm test

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
      #     switch_to: nvim .
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
        wotr status [--json]          Show current branch
        wotr list                     List all worktrees
        wotr log [-f] [-n N] [--path] Tail the scripts log
        wotr update                   Update to latest version from GitHub
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
      when "status"                   then cmd_status(args)
      when "list"                     then cmd_list
      when "acquire"                  then cmd_acquire(args)
      when "inquire"                  then cmd_inquire(args)
      when "resources"                then cmd_resources
      when "run"                      then cmd_run(args)
      when "log"                      then cmd_log(args)
      when "update"                   then cmd_update
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

    SKILL_NAME = "wotr-init"

    def cmd_init
      repo = find_repo_or_exit
      config_path = File.join(repo.root, ".wotr", "config")

      if File.exist?(config_path)
        puts "#{config_path} already exists."
        exit 0
      end

      if claude_available?
        skill_installed = skill_installed?(repo)

        unless skill_installed
          puts <<~MSG

            wotr can generate a tailored .wotr/config by analyzing your project
            with Claude Code. It will look at your dev scripts, Docker setup,
            database tooling, and ports to propose hooks and resources.

            This installs a Claude Code skill (#{SKILL_NAME}) that guides the
            interactive generation.

          MSG

          print "Install the wotr-init skill? [Y/n/q] "
          answer = $stdin.gets&.strip&.downcase || ""

          case answer
          when "q"
            exit 0
          when "n"
            basic_init(config_path)
            return
          end

          install_skill(repo)
          skill_installed = true
        end

        if skill_installed
          puts "\nLaunching Claude Code to generate .wotr/config...\n\n"
          exec("claude", "--prompt", "wotr init")
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

    def claude_available?
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, "claude"))
      end
    end

    def skill_dir_candidates(repo)
      [
        File.join(repo.root, ".claude", "skills", SKILL_NAME),
        File.expand_path("~/.claude/skills/#{SKILL_NAME}")
      ]
    end

    def skill_installed?(repo)
      skill_dir_candidates(repo).any? do |dir|
        File.exist?(File.join(dir, "SKILL.md"))
      end
    end

    def install_skill(repo)
      source_dir = File.join(gem_data_dir, "skills", SKILL_NAME)

      unless File.directory?(source_dir)
        warn "wotr: skill data not found in gem (expected #{source_dir})"
        warn "Falling back to basic init."
        return false
      end

      puts "\nWhere should the skill be installed?"
      puts "  1) This project only  (.claude/skills/#{SKILL_NAME}/)"
      puts "  2) All projects       (~/.claude/skills/#{SKILL_NAME}/)"
      print "\n> "
      choice = $stdin.gets&.strip || "1"

      target = case choice
               when "2"
                 File.expand_path("~/.claude/skills/#{SKILL_NAME}")
               else
                 File.join(repo.root, ".claude", "skills", SKILL_NAME)
               end

      copy_skill_files(source_dir, target)
      puts "Installed #{SKILL_NAME} skill to #{target}/"
      true
    end

    def copy_skill_files(source, target)
      require 'fileutils'
      Dir.glob(File.join(source, "**", "*")).each do |src_file|
        next if File.directory?(src_file)

        rel = src_file.sub("#{source}/", "")
        dst = File.join(target, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src_file, dst)
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
