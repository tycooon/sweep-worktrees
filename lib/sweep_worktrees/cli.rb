# frozen_string_literal: true

require "fileutils"
require "optparse"

module SweepWorktrees
  class Log
    attr_reader :warnings

    def initialize(io, verbose:)
      @io = io
      @verbose = verbose
      @warnings = 0
    end

    def info(message) = @io.puts(message)

    def verbose(message)
      @io.puts(message) if @verbose
    end

    def warn(message)
      @warnings += 1
      @io.puts("warn: #{message}")
    end
  end

  module CLI
    USAGE = "Usage: sweep-worktrees [--dry-run] [--verbose] [--config PATH]"

    module_function

    # Exit code: 0 clean, 1 when anything warned, 2 on bad usage or config.
    def run(argv, io: $stdout)
      options = parse(argv)
      config = Config.load(options[:config])
      with_lock(config.lock_file, io) do
        log = Log.new(io, verbose: options[:verbose])
        Sweep.new(config, log, dry_run: options[:dry_run]).call
        log.warnings.zero? ? 0 : 1
      end
    rescue OptionParser::ParseError, Config::Invalid => error
      io.puts("error: #{error.message}", USAGE)
      2
    end

    def parse(argv)
      options = { dry_run: false, verbose: false, config: nil }
      rest = OptionParser.new(USAGE) do |opts|
        opts.on("--dry-run", "print what would be done, change nothing") do
          options[:dry_run] = true
        end
        opts.on("--verbose", "also list every kept checkout and why") { options[:verbose] = true }
        opts.on("--config PATH", "config file (default #{Config::DEFAULT_PATH})") { |path| options[:config] = path }
      end.parse(argv)
      raise OptionParser::InvalidArgument, rest.join(" ") unless rest.empty?

      options
    end

    def with_lock(path, io)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          io.puts("another sweep-worktrees run holds #{path}; exiting")
          return 0
        end
        yield
      end
    end
  end
end
