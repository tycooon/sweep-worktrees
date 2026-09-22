# frozen_string_literal: true

module SweepWorktrees
  # Working directories of all running processes: a checkout someone sits in must not
  # vanish under them.
  class Processes
    class Unavailable < StandardError
    end

    def self.snapshot(runner: Command)
      res = runner.run("lsof", "-a", "-d", "cwd", "-Fn")
      raise Unavailable, "lsof failed: #{res.err.strip}" unless res.ok?

      new(res.out.each_line.filter_map { |line| line[1..].chomp if line.start_with?("n") })
    end

    def initialize(cwds)
      @cwds = cwds
    end

    def occupied?(path)
      [path, File.realpath(path)].uniq.any? do |dir|
        @cwds.any? { |cwd| cwd == dir || cwd.start_with?("#{dir}/") }
      end
    rescue SystemCallError
      true
    end
  end
end
