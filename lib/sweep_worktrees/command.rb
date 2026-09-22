# frozen_string_literal: true

require "open3"

module SweepWorktrees
  class FactError < StandardError
  end

  Result = Struct.new(:out, :err, :status) do
    def ok? = status&.success? || false
  end

  # Runs external commands without a shell. LC_ALL=C keeps git's messages matchable.
  module Command
    ENV_OVERRIDES = { "LC_ALL" => "C" }.freeze

    module_function

    def run(*, chdir: nil, merge_err: false)
      opts = chdir ? { chdir: chdir } : {}
      if merge_err
        out, status = Open3.capture2e(ENV_OVERRIDES, *, **opts)
        Result.new(out, "", status)
      else
        Result.new(*Open3.capture3(ENV_OVERRIDES, *, **opts))
      end
    rescue SystemCallError => error
      Result.new("", error.message, nil)
    end

    def git(dir, *) = run("git", "-C", dir, *)

    def git!(dir, *args)
      res = git(dir, *args)
      raise FactError, "git #{args.first} failed in #{dir}: #{res.err.strip}" unless res.ok?

      res.out
    end
  end
end
