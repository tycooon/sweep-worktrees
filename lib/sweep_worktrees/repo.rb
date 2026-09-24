# frozen_string_literal: true

module SweepWorktrees
  # Worktree paths and branch names a dry run has reported removing. A real run has removed them
  # by the time the repository's clone is judged, so the clone's facts leave them out.
  Pretended = Struct.new(:worktrees, :branches)

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
      @pretended = Pretended.new([], [])
    end

    def common_dir
      @common_dir ||= self.class.common_dir_of(dir)
    end

    def name = File.basename(dir)

    # `git worktree list --porcelain` as [path, attribute lines] pairs, the main checkout first.
    def worktrees(*options)
      Command.git!(dir, "worktree", "list", "--porcelain", *options).split("\n\n").map do |entry|
        path, *attributes = entry.lines(chomp: true)
        [path.delete_prefix("worktree "), attributes]
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
