# frozen_string_literal: true

require "find"

module SweepWorktrees
  Facts = Struct.new(
    :path, :kind, :error,
    :self_checkout, :occupied, :app_reserved, :keep_file,
    :locked, :head, :branch, :dirt, :dirty, :idle_days, :plans,
    :forge_ok, :pr, :head_known, :head_on_ref, :head_in_default,
    :submodule_dirt, :nested_checkouts,
    :hosted_worktrees, :stash_count, :unpushed_branches,
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
      merged_heads = prs.select { |pr| pr.state == :merged }.map(&:head_sha)
      worktrees = Command.git!(path, "worktree", "list", "--porcelain")
      facts.hosted_worktrees = worktrees.scan(/^worktree /).size - 1
      facts.stash_count = Command.git!(path, "stash", "list").lines.size
      branches = Command.git!(path, "for-each-ref", "--format=%(refname:short) %(objectname)",
                              "refs/heads")
      facts.unpushed_branches = branches.lines.map(&:split).filter_map do |name, sha|
        next if merged_heads.include?(sha)

        unpushed = Command.git!(path, "rev-list", "--count", sha, "--not", "--remotes").strip
        name unless unpushed == "0"
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
        changed << fields.last if fields[2].start_with?("S") && fields[2] != "S..."
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
