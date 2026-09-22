# frozen_string_literal: true

module SweepWorktrees
  # A repository, addressed by its main checkout or by a standalone clone's own dir.
  class Repo
    attr_reader :dir

    def self.of(path)
      common = Command.git!(path, "rev-parse", "--path-format=absolute", "--git-common-dir").strip
      new(File.basename(common) == ".git" ? File.dirname(common) : common)
    end

    def initialize(dir)
      @dir = dir
    end

    def name = File.basename(dir)

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
