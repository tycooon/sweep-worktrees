# frozen_string_literal: true

module SweepWorktrees
  # One pass: discover, classify and act per repository, then empty dirs, hooks and tarball expiry.
  class Sweep
    KEPT_TAGS = %i[live pooled open dirty waiting guarded other stopped].freeze

    def initialize(config, log, dry_run:)
      @config = config
      @log = log
      @dry_run = dry_run
      @forge = Forge.new(limit: config.forge_lookup_limit)
      @kept = Hash.new(0)
      @attention = []
    end

    def call
      @log.info("== sweep-worktrees #{Time.now.strftime('%F %T')}#{' (dry-run)' if @dry_run} ==")
      found = Discover.call(@config.worktrees_root)
      report(found)
      builder = snapshot
      actions = Actions.new(config: @config, log: @log, dry_run: @dry_run,
                            recheck: method(:recheck))
      repositories(found).each { |repo, checkouts| sweep_repo(repo, checkouts, builder, actions) }
      if builder
        tidy(found, actions)
      else
        @log.info("skipped pruning, empty dirs, hooks and tarball expiry: " \
                  "this run is not safe to delete anything")
      end
      summarize(actions.counts)
    end

    private

    def sweep_repo(repo, checkouts, builder, actions)
      return unless builder

      worktrees, clones = checkouts.partition { |checkout| checkout.kind == :worktree }
      sweep(worktrees, repo, builder, actions)
      actions.prune(repo, worktrees.map(&:path)) unless worktrees.empty?
      sweep(clones, repo, builder, actions)
    end

    def tidy(found, actions)
      found.empty_dirs.each { |dir| actions.remove_empty_dir(dir) }
      @config.hooks.each { |dir, command| actions.run_hook(dir, command) }
      actions.expire_salvage
    end

    def report(found)
      found.checkouts.select { |checkout| checkout.kind == :broken }
           .each { |checkout| @log.info("broken checkout, review manually: #{checkout.path}") }
      found.stray_dirs.each { |dir| @log.info("not a checkout, review manually: #{dir}") }
    end

    def builder!
      FactsBuilder.new(
        registry: AppRegistry.load(@config.app_registry),
        processes: Processes.snapshot,
        idle_floor_days: @config.idle_floor_days,
      )
    end

    def snapshot
      builder!
    rescue AppRegistry::Unreadable, Processes::Unavailable => error
      @log.warn("#{error.message}; nothing is removed this run")
      nil
    end

    # Worktrees grouped under their repository; a standalone clone is its own repository.
    def repositories(found)
      checkouts = found.checkouts.reject { |checkout| checkout.kind == :broken }
      grouped = checkouts.each_with_object({}) do |checkout, repos|
        repo = checkout.kind == :clone ? Repo.new(checkout.path) : Repo.of(checkout.path)
        (repos[repo.dir] ||= [repo, []]).last << checkout
      rescue FactError => error
        @log.warn("#{checkout.path}: #{error.message}")
      end
      grouped.values
    end

    def sweep(checkouts, repo, builder, actions)
      facts = checkouts.map { |checkout| builder.cheap(checkout) }
      candidates = facts.reject { |f| builder.guarded_cheaply?(f) }
      prs = lookup(repo) if candidates.any?
      facts.each do |f|
        if candidates.include?(f)
          builder.complete(f, repo, prs)
          find_older_pull_request(f, repo, builder)
        end
        verdict = Rules.verdict(f, @config)
        next if verdict.remove? && actions.remove(f, verdict, repo, prs)

        tally(f, verdict)
      end
    end

    # The PR/MR list is capped, so a checkout idle past the floor that matched nothing
    # there gets one lookup by its own commit; fresher ones are waiting either way.
    def find_older_pull_request(facts, repo, builder)
      return unless facts.forge_ok && facts.pr.nil?
      return if Rules.guard(facts) && !Rules.orphan_head?(facts)
      return if facts.idle_days < @config.idle_floor_days

      found = @forge.pull_requests_for_commit(repo.origin_url, facts.head)
      builder.match_pull_requests(facts, found) if found.any?
    end

    def tally(facts, verdict)
      tag = verdict.remove? ? :stopped : verdict.tag
      @kept[tag] += 1
      @attention << facts.path if verdict.attention
      @log.verbose("keep #{facts.path}: #{verdict.reason}") unless verdict.remove?
    end

    def lookup(repo)
      prs = @forge.pull_requests(repo.origin_url)
      if prs.nil? && Forge.parse_remote(repo.origin_url)
        @log.warn("PR/MR lookup failed for #{repo.dir} (#{repo.origin_url})")
      end
      prs
    end

    def recheck(facts, repo, prs)
      builder = builder!
      fresh = builder.cheap(Checkout.new(path: facts.path, kind: facts.kind))
      unless builder.guarded_cheaply?(fresh)
        builder.complete(fresh, repo, prs, measure_idle: false)
        # prs is only the capped list; a PR found by commit still speaks for an unchanged HEAD.
        fresh.head_known ||= facts.head_known if fresh.head == facts.head
      end
      guarded = Rules.guard(fresh)
      return guarded.first if guarded

      changed = %i[head branch dirt].any? { |key| fresh[key] != facts[key] }
      "it changed since it was checked" if changed
    rescue AppRegistry::Unreadable, Processes::Unavailable => error
      error.message
    end

    def summarize(counts)
      @attention.each { |path| @log.verbose("attention, dirty and idle: #{path}") }
      kept = KEPT_TAGS.map { |tag| "#{tag} #{@kept[tag]}" }.join(", ")
      @log.info("removed #{counts[:removed]}, clones deleted #{counts[:clones]}, " \
                "salvaged #{counts[:salvaged]}, branches deleted #{counts[:branches]}; " \
                "kept #{@kept.values.sum} (#{kept}); " \
                "attention #{@attention.size}; warnings #{@log.warnings}")
    end
  end
end
