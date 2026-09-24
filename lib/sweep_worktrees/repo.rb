# frozen_string_literal: true

module SweepWorktrees
  # What a dry run has reported doing to a repository: worktree registrations dropped (removed
  # or pruned, by path), branches deleted, and registrations reconnected (old path to new).
  # A real run has done all that before it prunes or judges the clone, so a dry run must too.
  Pretended = Struct.new(:worktrees, :branches, :moved, keyword_init: true) do
    # A registration as a real run would have left it, or nil once it is gone.
    def apply(path, prunable)
      if (target = moved[path])
        path = target
        prunable = false
      end
      [path, prunable] unless worktrees.include?(path)
    end
  end

  # A repository, addressed by its main checkout or by a standalone clone's own dir.
  class Repo
    attr_reader :dir, :pretended

    def self.of(path)
      common = common_dir_of(path)
      new(File.basename(common) == ".git" ? File.dirname(common) : common)
    end

    def self.common_dir_of(path)
      Command.git!(path, "rev-parse", "--path-format=absolute", "--git-common-dir").strip
    end

    def initialize(dir)
      @dir = dir
      @pretended = Pretended.new(worktrees: [], branches: [], moved: {})
    end

    def common_dir
      @common_dir ||= self.class.common_dir_of(dir)
    end

    def name = File.basename(dir)

    # Registered worktrees as [path, prunable] pairs, the main checkout first. Under --dry-run,
    # as a real run would have left them by now.
    def worktrees(*options)
      listing = Command.git!(dir, "worktree", "list", "--porcelain", *options)
      listing.split("\n\n").filter_map do |entry|
        path, *attributes = entry.lines(chomp: true)
        prunable = attributes.any? { |line| line.start_with?("prunable") }
        pretended.apply(path.delete_prefix("worktree "), prunable)
      end
    end

    def origin_url
      return @origin_url if defined?(@origin_url)

      res = Command.git(dir, "remote", "get-url", "origin")
      @origin_url = res.ok? ? res.out.strip : nil
    end

    # origin/HEAD when it is set, else whichever of origin/master and origin/main exists.
    def default_ref
      return @default_ref if defined?(@default_ref)

      head = Command.git(dir, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
      candidates = head.ok? ? [head.out.strip] : %w[origin/master origin/main]
      @default_ref = candidates.find do |ref|
        Command.git(dir, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}").ok?
      end
    end

    def in_default?(sha)
      !default_ref.nil? && Command.git(dir, "merge-base", "--is-ancestor", sha, default_ref).ok?
    end
  end
end
