# frozen_string_literal: true

require 'json'
require_relative 'resource_lease'
require_relative 'lease'

module Wotr
  class CLI
    # Bounded wait (seconds) before `wotr acquire` gives up on a held resource
    # and prints an actionable decision. `--wait` extends this to WAIT_MAX.
    WAIT_DEFAULT = 15
    WAIT_MAX = 30 * 60
    WAIT_POLL = 3
    INIT_TEMPLATE = <<~YAML
      # .wotr/config — wotr configuration
      # See: https://github.com/gtmax/wotr
      #
      # Hooks are arrays of steps. Each step is either:
      #   - bg: <script>   # runs in TUI log pane (non-interactive)
      #   - fg: <script>   # suspends TUI, takes the terminal (interactive)

      hooks:
        new:
          - bg: wotr-default-setup
        switch:
          - fg: wotr-launch-claude

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
        wotr new <branch> [--switch]  Create a worktree (--switch to enter it)
        wotr acquire <resource>       Acquire a resource (take its lease + run acquire)
                       [--force]        take it even if another worktree holds it
                       [--wait]         keep waiting instead of failing fast
        wotr release <resource>       Release this worktree's lease on a resource
        wotr inquire [resource]       Run resource inquire script(s), print JSON
        wotr resources                List configured resources and who holds them
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

      Options for 'new':
        --switch   Enter the new worktree: run setup + the 'switch' hook
                   (rename tab, launch editor/claude, …), then open a shell in it.
                   Without it, 'new' just creates the worktree and returns.

      Options for 'acquire' (exclusive resources):
        By default, if another worktree already holds the resource, acquire waits
        briefly then exits non-zero rather than stealing it silently.
        --force    take it anyway (stops the holder); prints who it took it from
        --wait     keep waiting for the holder to release instead of failing fast

      Environment:
        WOTR_ROOT          Repo root (set automatically in scripts)
        WOTR_WORKTREE      Current worktree path (set automatically in scripts)
        WOTR_START_POINT   Base ref for new branches (default: origin/<default-branch>)
        WOTR_ACQUIRE_WAIT  Seconds 'acquire' waits on a held resource before failing
                           (default 15; 0 fails immediately after one check)
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
      when "new"                      then cmd_new(args)
      when "skill"                    then cmd_skill(args)
      when "status"                   then cmd_status(args)
      when "list"                     then cmd_list
      when "acquire"                  then cmd_acquire(args)
      when "release"                  then cmd_release(args)
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

    # Create a new worktree, branched from origin/<default-branch>.
    #
    # Mirrors the TUI's two-hook model: creating a worktree only marks it as
    # needing setup — the 'new' (setup) and 'switch' hooks both run when you
    # *enter* it. So by default this is create-only (returns immediately, safe
    # to script). Pass --switch to enter the worktree: run setup (if needed),
    # run the 'switch' hook (rename tab, launch editor/claude, …), then drop
    # into a shell in the worktree.
    #
    # Idempotent: if a worktree for <branch> already exists, we act on it
    # instead of failing (a no-op with no flags; enter it with --switch).
    def cmd_new(args)
      switch = args.delete("--switch")

      name = args.find { |a| !a.start_with?("--") }
      if name.nil? || name.strip.empty?
        warn "Usage: wotr new <branch> [--switch]"
        exit 1
      end

      repo = find_repo_or_exit

      worktree = repo.find_worktree(name)
      if worktree
        puts "Worktree '#{worktree.branch}' already exists at #{worktree.path}"
      else
        result = repo.create_worktree(name)
        unless result[:success]
          warn "wotr: failed to create worktree '#{name}': #{result[:error]}"
          exit 1
        end

        worktree = result[:worktree]
        puts "Created worktree '#{worktree.branch}' at #{worktree.path}"
      end

      # Default: create only. Setup is deferred until the worktree is entered,
      # just like the TUI.
      return unless switch

      # Enter the worktree: chdir + OSC 7 so the terminal picks up the new CWD,
      # run setup once (if still needed), run the 'switch' hook, then hand the
      # caller a shell rooted in the worktree.
      Dir.chdir(worktree.path)
      print "\e]7;file://localhost#{worktree.path}\e\\"

      if worktree.needs_setup?
        worktree.run_setup!(visible: true)
        worktree.mark_setup_complete!
      end

      worktree.run_switch!

      exec ENV.fetch("SHELL", "/bin/zsh")
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
      force = !args.delete("--force").nil?
      wait = !args.delete("--wait").nil?
      name = args.find { |a| !a.start_with?("--") }
      if name.nil?
        warn "Usage: wotr acquire <resource> [--force] [--wait]"
        exit 1
      end

      repo = find_repo_or_exit
      require_config!(repo)
      cfg = config(repo)

      unless cfg.resource(name)
        warn "wotr: resource '#{name}' not found in .wotr/config"
        exit 1
      end

      # Compatible (non-exclusive) resources have no single owner — nothing to
      # lease or contend for. Keep the original run-and-report behaviour.
      unless cfg.exclusive?(name)
        run_acquire_or_exit(repo, cfg, name)
        return
      end

      me = repo.worktree_containing(Dir.pwd)
      me_path = me ? me.path : realpath(Dir.pwd)
      me_branch = me&.branch
      svc = ResourceLease.new(repo)
      env = wotr_env(repo)

      # Contention gate: if another live worktree holds the resource and we
      # weren't told to force, wait a bounded interval then fail with a decision.
      unless force
        waited = 0
        cap = wait ? WAIT_MAX : acquire_wait_default
        announced = false
        loop do
          holder = svc.current_holder(name, chdir: Dir.pwd, env: env)
          break if holder.nil? || svc.same_path?(holder.path, me_path)

          if wait && !announced
            puts "#{name} is held by #{holder_label(holder)}; waiting..."
            announced = true
          end

          if waited >= cap
            print_acquire_decision(name, holder, waited)
            exit 1
          end

          slice = [WAIT_POLL, cap - waited].min
          sleep slice
          waited += slice
        end
      else
        holder = svc.current_holder(name, chdir: Dir.pwd, env: env)
        if holder && !svc.same_path?(holder.path, me_path)
          puts "Taking #{name} from #{holder_label(holder)} (--force)."
        end
      end

      puts "Acquiring #{name}..."
      result = cfg.run_acquire(name, env: env, chdir: Dir.pwd)

      unless result[:ran]
        warn "wotr: no acquire script for resource '#{name}'"
        exit 1
      end

      unless result[:success]
        # Acquire failed — don't claim a lease we don't actually hold.
        exit 1
      end

      svc.record_acquire(name, holder: me_path, holder_branch: me_branch)
      puts "Acquired #{name}."
    end

    def cmd_release(args)
      name = args[0]
      if name.nil?
        warn "Usage: wotr release <resource>"
        exit 1
      end

      repo = find_repo_or_exit
      require_config!(repo)
      cfg = config(repo)

      unless cfg.resource(name)
        warn "wotr: resource '#{name}' not found in .wotr/config"
        exit 1
      end

      released = repo.lease_store.release(name)
      if released
        puts "Released #{name}."
      else
        puts "No lease on #{name} to release."
      end
    end

    def cmd_inquire(args)
      repo = find_repo_or_exit
      require_config!(repo)
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
      require_config!(repo)
      cfg = config(repo)

      names = cfg.resource_names
      if names.empty?
        puts "(no resources configured)"
        return
      end

      svc = ResourceLease.new(repo)
      env = wotr_env(repo)

      names.each do |name|
        res = cfg.resource(name)
        icon = res["icon"] || "•"
        desc = res["description"] || ""
        kind = res["exclusive"] == true ? "exclusive" : "compatible"
        puts "#{icon}  #{name} (#{kind})"
        puts "   #{desc}" unless desc.empty?

        next unless cfg.exclusive?(name)

        holder = svc.current_holder(name, chdir: Dir.pwd, env: env)
        if holder.nil?
          puts "   \e[2mfree\e[0m"
        else
          describe_holder(holder).each { |line| puts "   #{line}" }
        end
      end
    end

    def cmd_run(args)
      hook_name = args[0]
      if hook_name.nil?
        warn "Usage: wotr run <hook>"
        exit 1
      end

      repo = find_repo_or_exit
      require_config!(repo)
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
      require_config!(repo)
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

    # --- Resource / lease helpers ---

    # Run a resource's acquire script and exit non-zero on failure. Used for
    # compatible resources (no leasing) and preserves the pre-lease behaviour.
    def run_acquire_or_exit(repo, cfg, name)
      puts "Acquiring #{name}..."
      result = cfg.run_acquire(name, env: wotr_env(repo), chdir: Dir.pwd)

      unless result[:ran]
        warn "wotr: no acquire script for resource '#{name}'"
        exit 1
      end

      exit 1 unless result[:success]
    end

    # A short label for a holder: its branch, else a worktree basename, else a
    # generic phrase for a non-worktree owner.
    def holder_label(holder)
      if holder.branch
        "worktree '#{holder.branch}'"
      elsif holder.path && holder.path != "unknown"
        "worktree '#{File.basename(holder.path)}'"
      else
        "another process"
      end
    end

    # The multi-line holder description shown under a resource in `wotr resources`.
    def describe_holder(holder)
      lines = ["held by #{holder_label(holder)}"]
      lease = holder.lease
      if lease
        now = Time.now.to_i
        if lease.adopted?
          detail = "detected #{Duration.human(lease.age(now))} ago (started outside wotr)"
        else
          detail = "acquired #{Duration.human(lease.age(now))} ago, " \
                   "renewed #{Duration.human(lease.since_renew(now))} ago"
        end
        detail += "  \e[2m[lapsed]\e[0m" unless lease.live?(now)
        lines << detail
      end
      lines
    end

    # The actionable failure block printed when acquire gives up on a held
    # resource (mirrors the shape proposed in the issue).
    def print_acquire_decision(name, holder, waited)
      warn "#{name} is held by #{holder_label(holder)}"
      lease = holder.lease
      if lease
        now = Time.now.to_i
        if lease.adopted?
          warn "  detected #{Duration.human(lease.age(now))} ago (started outside wotr)"
        else
          warn "  acquired #{Duration.human(lease.age(now))} ago, " \
               "last renewed #{Duration.human(lease.since_renew(now))} ago"
        end
      end
      warn "  waited #{Duration.human(waited)}"
      warn ""
      warn "  wotr acquire #{name} --force   take it anyway"
      warn "  wotr acquire #{name} --wait    keep waiting"
    end

    def realpath(path)
      File.realpath(path)
    rescue Errno::ENOENT
      File.expand_path(path)
    end

    # Bounded wait before `wotr acquire` fails on a held resource. Overridable via
    # WOTR_ACQUIRE_WAIT (seconds) so agents can tune fail-fast behaviour; 0 fails
    # immediately after a single check.
    def acquire_wait_default
      raw = ENV["WOTR_ACQUIRE_WAIT"]
      return WAIT_DEFAULT if raw.nil? || raw.strip.empty?

      [raw.to_i, 0].max
    end

    # --- Helpers ---

    def find_repo_or_exit
      repo = Repository.discover(Dir.pwd)
      unless repo
        warn "wotr: not a git repository (or any parent). Run wotr from a git repo root."
        exit 1
      end
      repo
    end

    def require_config!(repo)
      config_path = File.join(repo.root, Config::CONFIG_FILE)
      return if File.exist?(config_path)

      warn "wotr: no config found at #{config_path}"
      warn "Run 'wotr init' in this repo first."
      exit 1
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
