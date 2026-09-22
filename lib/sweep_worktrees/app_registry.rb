# frozen_string_literal: true

require "json"

module SweepWorktrees
  # The Claude desktop app's worktree registry. The app reuses pooled entries
  # (leasedBy null) and reaps them itself.
  class AppRegistry
    class Unreadable < StandardError
    end

    def self.load(path)
      return new({}) unless File.exist?(path)

      entries = JSON.parse(File.read(path)).fetch("worktrees").values.select do |entry|
        entry["path"].is_a?(String)
      end
      new(entries.to_h { |entry| [File.expand_path(entry["path"]), entry] })
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError, SystemCallError => error
      raise Unreadable, "app registry #{path} is unreadable: #{error.message}"
    end

    def initialize(by_path)
      @by_path = by_path
    end

    def reason(path)
      entry = @by_path[File.expand_path(path)] or return nil
      return "being created by the desktop app" if entry["status"] == "creating"

      "pooled by the desktop app" if entry["leasedBy"].nil?
    end
  end
end
