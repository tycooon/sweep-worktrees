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
      "github_hosts" => [],
    }.freeze
    PATHS = %w[worktrees_root salvage_dir app_registry lock_file].freeze
    NUMBERS = %w[dirty_merged_idle_days unmerged_idle_days attention_idle_days salvage_max_mb
                 salvage_retention_days forge_lookup_limit].freeze

    # An explicit path must exist: a typo must not fall back to the default config
    # and its real root.
    def self.load(path = nil)
      file = File.expand_path(path || DEFAULT_PATH)
      raise Invalid, "config not found: #{file}" if path && !File.exist?(file)

      data = read(file)
      unknown = data.keys - DEFAULTS.keys
      raise Invalid, "unknown config keys in #{file}: #{unknown.join(', ')}" if unknown.any?

      problem = problem(data)
      raise Invalid, "#{file}: #{problem}" if problem

      new(DEFAULTS.merge(data))
    end

    def self.read(file)
      data = File.exist?(file) ? YAML.safe_load_file(file) || {} : {}
      raise Invalid, "#{file} must hold a mapping" unless data.is_a?(Hash)

      data
    rescue Psych::SyntaxError => error
      raise Invalid, "#{file} is not valid YAML: #{error.message}"
    end

    def self.problem(data)
      return "worktrees_root is required" if data["worktrees_root"].to_s.empty?

      path = PATHS.find { |key| data.key?(key) && !data[key].is_a?(String) }
      return "#{path} must be a path" if path

      number = NUMBERS.find { |key| data.key?(key) && !positive_integer?(data[key]) }
      return "#{number} must be a positive whole number" if number
      return "hooks must map repository paths to commands" unless string_map?(data["hooks"])

      "github_hosts must be a list of host names" unless string_list?(data["github_hosts"])
    end

    def self.positive_integer?(value) = value.is_a?(Integer) && value.positive?

    def self.string_map?(value)
      value.nil? || (value.is_a?(Hash) && value.all? { |key, item| [key, item].all?(String) })
    end

    def self.string_list?(value) = value.nil? || (value.is_a?(Array) && value.all?(String))

    private_class_method :read, :problem, :positive_integer?, :string_map?, :string_list?

    def initialize(values)
      @values = values
    end

    PATHS.each { |key| define_method(key) { File.expand_path(@values.fetch(key)) } }
    NUMBERS.each { |key| define_method(key) { Integer(@values.fetch(key)) } }

    def hooks
      (@values.fetch("hooks") || {}).to_h { |repo, command| [File.expand_path(repo), command.to_s] }
    end

    def github_hosts = Array(@values.fetch("github_hosts"))

    def idle_floor_days = [dirty_merged_idle_days, unmerged_idle_days].min
  end
end
