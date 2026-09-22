# frozen_string_literal: true

require "yaml"

module SweepWorktrees
  class Config
    class Invalid < StandardError
    end

    DEFAULT_PATH = "~/.config/sweep-worktrees/config.yml"
    DEFAULTS = {
      "worktrees_root" => nil,
      "salvage_dir" => "~/.local/share/sweep-worktrees/salvage",
      "app_registry" => "~/Library/Application Support/Claude/git-worktrees.json",
      "lock_file" => "~/.cache/sweep-worktrees.lock",
      "dirty_merged_idle_days" => 7,
      "unmerged_idle_days" => 14,
      "attention_idle_days" => 30,
      "salvage_max_mb" => 200,
      "salvage_retention_days" => 90,
      "forge_lookup_limit" => 500,
      "hooks" => {},
    }.freeze
    PATHS = %w[worktrees_root salvage_dir app_registry lock_file].freeze
    NUMBERS = %w[dirty_merged_idle_days unmerged_idle_days attention_idle_days salvage_max_mb
                 salvage_retention_days forge_lookup_limit].freeze

    # An explicit path must exist: a typo must not fall back to the default config
    # and its real root.
    def self.load(path = nil)
      file = File.expand_path(path || DEFAULT_PATH)
      raise Invalid, "config not found: #{file}" if path && !File.exist?(file)

      data = File.exist?(file) ? YAML.safe_load_file(file) || {} : {}
      raise Invalid, "#{file} must hold a mapping" unless data.is_a?(Hash)

      unknown = data.keys - DEFAULTS.keys
      raise Invalid, "unknown config keys in #{file}: #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "#{file} must set worktrees_root" if data["worktrees_root"].to_s.empty?

      new(DEFAULTS.merge(data))
    end

    def initialize(values)
      @values = values
    end

    PATHS.each { |key| define_method(key) { File.expand_path(@values.fetch(key)) } }
    NUMBERS.each { |key| define_method(key) { Integer(@values.fetch(key)) } }

    def hooks
      (@values.fetch("hooks") || {}).to_h { |repo, command| [File.expand_path(repo), command.to_s] }
    end

    def idle_floor_days = [dirty_merged_idle_days, unmerged_idle_days].min
  end
end
