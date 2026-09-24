# frozen_string_literal: true

require "fileutils"
require "pathname"
require "shellwords"

module SweepWorktrees
  # Every destructive step. Each re-checks its guards right before acting;
  # under --dry-run nothing changes.
  class Actions
    class Refused < StandardError
    end

    HOOK_TIMEOUT = 3600

    attr_reader :counts

    # recheck: callable(facts, repo, prs) returning a reason to stop, or nil.
    def initialize(config:, log:, dry_run:, recheck:)
      @config = config
      @log = log
      @dry_run = dry_run
      @recheck = recheck
      @salvage = Salvage.new(config)
      @counts = Hash.new(0)
    end

    def remove(facts, verdict, repo, prs)
      inside_root!(facts.path)
      return false if stopped?(facts, repo, prs)
      if verdict.salvage
        return false unless salvage(facts, verdict, repo)
        return false if stopped?(facts, repo, prs)
      end

      facts.kind == :clone ? delete_clone(facts, verdict) : remove_worktree(facts, verdict, repo)
    rescue Refused => error
      @log.warn(error.message)
      false
    end

    # A worktree moved within the root still works, but its registration names the old folder,
    # so git can't find it by path and prune would drop it. `git worktree repair` fixes that,
    # but it also rewrites the `.git` file of whatever sits at any other registered path,
    # another repository's worktree included. This writes only this repository's admin dirs.
    def reconnect(repo, paths)
      return if @dry_run || paths.empty?

      admin_root = File.realpath(File.join(repo.common_dir, "worktrees"))
      paths.group_by { |path| admin_dir(path) }.each do |admin, claimants|
        next unless admin && claimants.one? && File.dirname(admin) == admin_root

        relink(admin, claimants.first)
      end
    rescue FactError, SystemCallError => error
      @log.warn("could not reconnect moved worktrees of #{repo.dir}: #{error.message}")
    end

    # A worktree moved with plain `mv` looks just like a deleted one, so pruning waits as long
    # as git's own gc would (gc.worktreePruneExpire). `prune` has no path filter, so it also
    # waits while any expired entry lies outside the root.
    def prune(repo)
      return if @dry_run

      expire = "--expire=#{prune_expiry(repo)}"
      stale = prunable(repo, expire)
      return if stale.nil? || stale.empty?

      outside = stale.reject { |path| path.start_with?("#{@config.worktrees_root}/") }
      return @log.verbose("left missing worktrees to git gc: #{outside.join(', ')}") if outside.any?

      res = Command.git(repo.dir, "worktree", "prune", expire)
      @log.warn("git worktree prune failed in #{repo.dir}: #{res.err.strip}") unless res.ok?
    end

    def remove_empty_dir(dir)
      inside_root!(dir)
      unless @dry_run
        FileUtils.rm_f(File.join(dir, ".DS_Store"))
        Dir.rmdir(dir)
      end
      done(:empty_dirs, "remove empty dir #{dir}")
    rescue SystemCallError, Refused => error
      @log.warn("could not remove empty dir #{dir}: #{error.message}")
    end

    def run_hook(repo_dir, command)
      args = Shellwords.split(command)
      args[0] = File.expand_path(args[0], repo_dir) if args[0].include?("/")
      args << "--dry-run" if @dry_run
      res = Command.run(*args, chdir: repo_dir, merge_err: true, timeout: HOOK_TIMEOUT)
      res.out.each_line { |line| @log.info("[hook #{File.basename(repo_dir)}] #{line.chomp}") }
      return if res.ok?

      @log.warn("hook `#{command}` in #{repo_dir} failed: #{res.status&.exitstatus || res.err}")
    end

    def expire_salvage
      @salvage.expired.each do |file|
        File.delete(file) unless @dry_run
        done(:expired, "delete old tarball #{file}")
      end
    end

    private

    def admin_dir(path)
      link = File.read(File.join(path, ".git"))[/\Agitdir: (.+)$/, 1] or return nil
      File.realpath(File.expand_path(link, path))
    rescue SystemCallError
      nil
    end

    # Only a registration whose folder is gone moves: one that still resolves belongs to the
    # original, and this folder is a copy.
    def relink(admin, path)
      file = File.join(admin, "gitdir")
      registered = File.read(file).strip
      return if File.exist?(File.expand_path(registered, admin))

      target = File.join(File.realpath(path), ".git")
      # worktree.useRelativePaths writes registrations relative to the admin dir.
      unless File.absolute_path?(registered)
        target = Pathname(target).relative_path_from(admin).to_s
      end
      File.write(file, "#{target}\n")
      @log.info("reconnected moved worktree #{path}")
    end

    def prune_expiry(repo)
      res = Command.git(repo.dir, "config", "--get", "gc.worktreePruneExpire")
      res.ok? ? res.out.strip : "3.months.ago"
    end

    def prunable(repo, expire)
      repo.worktrees(expire).filter_map do |path, attributes|
        path if attributes.any? { |line| line.start_with?("prunable") }
      end
    rescue FactError
      nil
    end

    def stopped?(facts, repo, prs)
      reason = @recheck.call(facts, repo, prs) or return false
      @log.info("kept #{facts.path}: #{reason}")
      true
    end

    def salvage(facts, verdict, repo)
      tarball = @dry_run ? "a tarball" : write_tarball(facts, verdict, repo)
      done(:salvaged, "salvage #{facts.path} to #{tarball}")
    rescue Salvage::Failed => error
      @log.warn("kept #{facts.path}: salvage failed: #{error.message}")
      false
    end

    def write_tarball(facts, verdict, repo)
      @salvage.write(facts, repo_name: repo.name, remote_url: repo.origin_url,
                            reason: verdict.reason)
    end

    def remove_worktree(facts, verdict, repo)
      path = facts.path
      raise Refused, "refusing to remove the main checkout #{path}" if path == repo.dir
      return false unless @dry_run || git_worktree_remove(repo.dir, path, force: verdict.force)

      repo.pretended.worktrees << path if @dry_run
      removed = done(:removed, "remove #{facts.path} (#{verdict.reason})")
      delete_branch(repo, facts) if verdict.delete_branch
      removed
    end

    # Plain `git worktree remove` refuses any worktree holding an initialized submodule.
    # Only --force gets past that, and --force also drops git's own dirty check,
    # so cleanliness is re-verified first, failing closed.
    def git_worktree_remove(repo_dir, path, force:)
      res = Command.git(repo_dir, "worktree", "remove", *("--force" if force), path)
      return true if res.ok?

      if !force && res.err.include?("containing submodules")
        status = Command.git(path, *FactsBuilder::STATUS)
        return kept(path, "cleanliness re-check failed: #{status.err.strip}") unless status.ok?
        return kept(path, "not clean on re-check") unless status.out.empty?

        res = Command.git(repo_dir, "worktree", "remove", "--force", path)
        return true if res.ok?
      end
      kept(path, "git worktree remove: #{res.err.strip}")
    end

    def delete_branch(repo, facts)
      branch = facts.branch
      tip = Command.git(repo.dir, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
      unless tip.ok? && tip.out.strip == facts.head
        return @log.warn("kept branch #{branch} in #{repo.dir}: its tip moved")
      end

      if @dry_run
        repo.pretended.branches << branch
      else
        res = Command.git(repo.dir, "branch", "-D", branch)
        unless res.ok?
          return @log.warn("could not delete branch #{branch} in #{repo.dir}: #{res.err.strip}")
        end
      end
      done(:branches, "delete branch #{branch} in #{repo.dir}")
    end

    def delete_clone(facts, verdict)
      FileUtils.remove_entry_secure(facts.path) unless @dry_run
      done(:clones, "delete clone #{facts.path} (#{verdict.reason})")
    rescue SystemCallError, ArgumentError => error
      kept(facts.path, "clone deletion failed: #{error.message}")
    end

    # Logs why the checkout stays; the nil it returns reads as "not removed".
    def kept(path, message)
      @log.warn("kept #{path}: #{message}")
    end

    def done(key, message)
      @log.info(@dry_run ? "DRY-RUN: #{message}" : message)
      @counts[key] += 1
    end

    def inside_root!(path)
      root = @config.worktrees_root
      rel = path.delete_prefix("#{root}/")
      return if rel != path && !rel.empty? && rel.count("/") <= 1 && !rel.split("/").include?("..")

      raise Refused, "refusing to touch #{path}: not one or two levels under #{root}"
    end
  end
end
