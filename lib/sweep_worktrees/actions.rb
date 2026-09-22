# frozen_string_literal: true

require "fileutils"
require "shellwords"

module SweepWorktrees
  # Every destructive step. Each re-checks its guards right before acting;
  # under --dry-run nothing changes.
  class Actions
    class Refused < StandardError
    end

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

    # `git worktree prune` has no path filter: it drops every registration whose folder is
    # missing right now, including a renamed project folder or an unmounted volume. So moved
    # worktrees under the root are repaired first, and pruning waits while any missing
    # worktree lies outside the root.
    def prune(repo, paths)
      return if @dry_run

      existing = paths.select { |path| File.directory?(path) }
      Command.git(repo.dir, "worktree", "repair", *existing) if existing.any?
      stale = prunable(repo)
      return if stale.nil? || stale.empty?

      outside = stale.reject { |path| path.start_with?("#{@config.worktrees_root}/") }
      return @log.verbose("left missing worktrees to git gc: #{outside.join(', ')}") if outside.any?

      res = Command.git(repo.dir, "worktree", "prune")
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
      res = Command.run(*args, chdir: repo_dir, merge_err: true)
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

    def prunable(repo)
      res = Command.git(repo.dir, "worktree", "list", "--porcelain")
      return unless res.ok?

      res.out.split("\n\n").filter_map do |block|
        lines = block.lines.map(&:chomp)
        lines.first.delete_prefix("worktree ") if lines.any? { |line| line.start_with?("prunable") }
      end
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

      unless @dry_run
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
