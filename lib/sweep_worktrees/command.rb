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
    # A stalled network call or hook must not hold the lock forever. A command past its
    # deadline reads as failed, which every caller already treats as "keep".
    TIMEOUT = 600

    module_function

    def run(*args, chdir: nil, merge_err: false, timeout: TIMEOUT)
      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir
      popen = merge_err ? :popen2e : :popen3
      Open3.public_send(popen, ENV_OVERRIDES, *args, **opts) do |stdin, *pipes, wait|
        stdin.close
        readers = pipes.map { |pipe| Thread.new { pipe.read } }
        finished = wait.join(timeout)
        kill_group(wait.pid) unless finished
        out, err = readers.map(&:value)
        next Result.new(out, "timed out after #{timeout}s", nil) unless finished

        Result.new(out, err.to_s, wait.value)
      end
    rescue SystemCallError => error
      Result.new("", error.message, nil)
    end

    def kill_group(pid)
      Process.kill("KILL", -pid)
    rescue SystemCallError
      nil
    end

    def git(dir, *) = run("git", "-C", dir, *)

    def git!(dir, *args)
      res = git(dir, *args)
      raise FactError, "git #{args.first} failed in #{dir}: #{res.err.strip}" unless res.ok?

      res.out
    end
  end
end
