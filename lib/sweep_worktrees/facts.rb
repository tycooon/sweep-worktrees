# frozen_string_literal: true

require "find"

module SweepWorktrees
  Facts = Struct.new(
    :path, :kind, :error,
    :self_checkout, :occupied, :app_reserved, :keep_file,
    :locked, :head, :branch, :dirt, :dirty, :idle_days, :plans,
    :forge_ok, :pr, :head_known, :head_on_ref, :head_in_default,
    :submodule_dirt, :nested_checkouts,
    :hosted_worktrees, :stash_count, :unpushed_refs, :precious_ignored, :local_env_files,
    keyword_init: true
  ) do
    def detached? = branch.nil?
  end

  # Collects what the rules need. Cheap facts come first so that guarded checkouts
  # cost no git calls.
  class FactsBuilder
    DAY = 86_400
    PRUNED_DIRS = %w[node_modules target vendor .git].freeze
    STATUS = %w[status --porcelain --untracked-files=normal --ignore-submodules=none].freeze
    STATUS_V2 = %w[
      status --porcelain=v2 -z --untracked-files=normal --ignore-submodules=none
    ].freeze
    V2_FIELDS = { "1" => 9, "2" => 10, "u" => 11 }.freeze
    NESTED_DEPTH = 4
    # Ignored paths a clone may take with it: dependencies, build output and caches, editor
    # and agent state, and .plans/, which is salvaged first. Anything else (.env, local
    # databases, keys) keeps the clone.
    DISPOSABLE_IGNORED = %w[
      node_modules vendor target dist out coverage tmp log logs
      .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .bundle .gradle
      .next .nuxt .cache .parcel-cache .turbo .terraform
      .DS_Store .idea .vscode .claude .codex .cursor .zed .superpowers .plans
    ].freeze
    DISPOSABLE_IGNORED_FILES = /\A(?:.+\.(?:pyc|log)|Gemfile\.lock)\z/
    # Also common source folders (Helm charts, Go packages, packaging), so these count only
    # when git lists the folder itself as ignored.
    DISPOSABLE_WHEN_LISTED = %w[build charts pkg].freeze
    # Ignored, so they are never dirt and never salvaged. Usually copied from the main
    # checkout, but a copy that differs may hold keys found nowhere else.
    LOCAL_ENV_FILES = %w[.env .envrc mise.toml .mise.toml mise.local.toml .mise.local.toml].freeze

    def initialize(registry:, processes:, idle_floor_days:, now: Time.now, cwd: Dir.pwd)
      @registry = registry
      @processes = processes
      @idle_floor_days = idle_floor_days
      @now = now
      @cwd = cwd
    end

    def cheap(checkout)
      path = checkout.path
      Facts.new(
        path:,
        kind: checkout.kind,
        self_checkout: @cwd == path || @cwd.start_with?("#{path}/"),
        occupied: @processes.occupied?(path),
        app_reserved: @registry.reason(path),
        keep_file: File.exist?(File.join(path, ".worktree-keep")),
      )
    end

    def guarded_cheaply?(facts)
      facts.self_checkout || facts.occupied || facts.app_reserved || facts.keep_file
    end

    # prs is an Array of PullRequest, or nil when the forge could not be asked.
    def complete(facts, repo, prs, measure_idle: true)
      git_facts(facts, measure_idle:)
      facts.forge_ok = !prs.nil?
      match_pull_requests(facts, prs || [])
      facts.head_in_default = repo.in_default?(facts.head)
      clone_facts(facts, prs || []) if facts.kind == :clone
      facts.local_env_files = local_env_files(facts.path, repo.dir) if facts.kind == :worktree
      facts
    rescue FactError, SystemCallError => error
      facts.error = error.message
      facts
    end

    def match_pull_requests(facts, prs)
      facts.pr = Forge.match(prs, head: facts.head, branch: facts.branch)
      facts.head_known = prs.any? { |pr| pr.head_sha == facts.head }
    end

    private

    def git_facts(facts, measure_idle:)
      path = facts.path
      gitdir = Command.git!(path, "rev-parse", "--path-format=absolute", "--git-dir").strip
      facts.head = Command.git!(path, "rev-parse", "HEAD").strip
      branch = Command.git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
      facts.branch = branch.ok? ? branch.out.strip : nil
      facts.dirt = Command.git!(path, *STATUS)
      facts.dirty = !facts.dirt.empty?
      facts.submodule_dirt = facts.dirty ? submodule_changes(path) : []
      facts.nested_checkouts = nested_checkouts(path)
      facts.locked = File.exist?(File.join(gitdir, "locked"))
      facts.idle_days = idle_days(path, gitdir) if measure_idle
      facts.plans = plans?(path)
      facts.head_on_ref = facts.branch ? true : on_ref?(path, facts.head)
    end

    def clone_facts(facts, prs)
      path = facts.path
      worktrees = Command.git!(path, "worktree", "list", "--porcelain")
      facts.hosted_worktrees = worktrees.scan(/^worktree /).size - 1
      facts.stash_count = Command.git!(path, "stash", "list").lines.size
      facts.unpushed_refs = unpushed_refs(path, prs)
      facts.precious_ignored = precious_ignored(path)
    end

    # Branches and tags holding commits that no remote has, unless a merged PR/MR has them.
    def unpushed_refs(path, prs)
      merged_heads = prs.select { |pr| pr.state == :merged }.map(&:head_sha)
      refs = Command.git!(path, "for-each-ref", "--format=%(refname:short) %(objectname)",
                          "refs/heads", "refs/tags")
      refs.lines.map(&:split).filter_map do |name, sha|
        next if merged_heads.include?(sha)

        unpushed = Command.git!(path, "rev-list", "--count", sha, "--not", "--remotes").strip
        name unless unpushed == "0"
      end
    end

    def ignored_entries(path)
      Command.git!(path, "ls-files", "--others", "--ignored", "--exclude-standard",
                   "--directory", "-z").split("\0")
    end

    def local_env_files(path, main_dir)
      files = ignored_entries(path).select { |rel| LOCAL_ENV_FILES.include?(File.basename(rel)) }
      files.reject do |rel|
        main = File.join(main_dir, rel)
        File.file?(main) && File.binread(main) == File.binread(File.join(path, rel))
      end
    end

    def precious_ignored(path)
      listing = ignored_entries(path)
      junk_dirs = listing.select do |rel|
        rel.end_with?("/") && DISPOSABLE_WHEN_LISTED.include?(File.basename(rel))
      end
      listing.reject do |rel|
        parts = rel.chomp("/").split("/")
        parts.intersect?(DISPOSABLE_IGNORED) || DISPOSABLE_IGNORED_FILES.match?(parts.last) ||
          junk_dirs.any? { |dir| rel.start_with?(dir) }
      end
    end

    def on_ref?(path, sha)
      refs = Command.git!(path, "for-each-ref", "--count=1", "--contains", sha,
                          "refs/heads", "refs/remotes", "refs/tags")
      !refs.empty?
    end

    # Porcelain v2 marks a submodule entry S<commit><tracked><untracked>;
    # any flag set is a change inside it.
    def submodule_changes(path)
      entries = Command.git!(path, *STATUS_V2).split("\0")
      changed = []
      while (entry = entries.shift)
        count = V2_FIELDS[entry[0]] or next
        entries.shift if entry.start_with?("2 ") # a rename's original path is its own field
        fields = entry.split(" ", count)
        # "S..." is a staged bump: its commit may live only in this checkout's submodule.
        changed << fields.last if fields[2].start_with?("S")
      end
      changed
    end

    # Checkouts living inside this one (worktrees made in a project folder that is itself
    # a clone, a scratch clone under tmp/) would go with it unexamined. Submodules belong
    # to the checkout and don't count.
    def nested_checkouts(path)
      gitlinks = submodule_paths(path)
      found = []
      Find.find(path) do |entry|
        next if entry == path || !File.directory?(entry) || File.symlink?(entry)

        rel = entry.delete_prefix("#{path}/")
        if Discover.git_entry?(entry)
          found << rel unless gitlinks.include?(rel)
          Find.prune
        end
        too_deep = rel.count("/") >= NESTED_DEPTH - 1
        Find.prune if too_deep || PRUNED_DIRS.include?(File.basename(entry))
      end
      found
    end

    def submodule_paths(path)
      Command.git!(path, "ls-files", "--stage", "-z").split("\0").filter_map do |entry|
        entry.split("\t", 2).last if entry.start_with?("160000 ")
      end
    end

    def plans?(path)
      dir = File.join(path, ".plans")
      return false unless File.directory?(dir)

      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).any? { |rel| File.file?(File.join(dir, rel)) }
    end

    # Newest change in the checkout or its git HEAD log. The scan stops once the floor is
    # ruled out, so the value is exact at or above the floor; below it the rules need
    # nothing finer.
    def idle_days(path, gitdir)
      cutoff = @now - (@idle_floor_days * DAY)
      logs = [File.join(gitdir, "HEAD"), File.join(gitdir, "logs", "HEAD")]
      newest = logs.filter_map { |file| mtime(file) }.max || Time.at(0)
      if newest <= cutoff
        Find.find(path) do |entry|
          name = File.basename(entry)
          Find.prune if entry != path && PRUNED_DIRS.include?(name) && File.directory?(entry)
          next if name == ".DS_Store"

          time = mtime(entry)
          newest = time if time && time > newest
          break if newest > cutoff
        end
      end
      (@now - newest) / DAY
    end

    def mtime(file)
      File.lstat(file).mtime
    rescue SystemCallError
      nil
    end
  end
end
