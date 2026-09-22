# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include TestHelper

  def write(yaml)
    File.join(@tmp, "config.yml").tap { |path| File.write(path, yaml) }
  end

  def test_defaults_fill_what_the_file_leaves_out
    config = SweepWorktrees::Config.load(
      write("worktrees_root: ~/worktrees\nunmerged_idle_days: 21\n" \
            "hooks:\n  ~/code/app: bin/hook\n"),
    )

    assert_equal File.expand_path("~/worktrees"), config.worktrees_root
    assert_equal 21, config.unmerged_idle_days
    assert_equal 7, config.dirty_merged_idle_days
    assert_equal 7, config.idle_floor_days
    assert_equal File.expand_path("~/.local/share/sweep-worktrees/salvage"), config.salvage_dir
    assert_equal File.expand_path("~/.cache/sweep-worktrees.lock"), config.lock_file
    assert_equal({ File.expand_path("~/code/app") => "bin/hook" }, config.hooks)
  end

  def test_the_worktrees_root_is_required
    error = assert_raises(SweepWorktrees::Config::Invalid) { SweepWorktrees::Config.load(write("hooks: {}\n")) }
    assert_match(/worktrees_root/, error.message)
  end

  def test_a_missing_explicit_config_is_an_error
    assert_raises(SweepWorktrees::Config::Invalid) { SweepWorktrees::Config.load(File.join(@tmp, "nope.yml")) }
  end

  def test_unknown_keys_are_rejected
    error = assert_raises(SweepWorktrees::Config::Invalid) { SweepWorktrees::Config.load(write("worktree_root: /x\n")) }
    assert_match(/worktree_root/, error.message)
  end

  def test_a_non_mapping_file_is_rejected
    assert_raises(SweepWorktrees::Config::Invalid) { SweepWorktrees::Config.load(write("- a\n")) }
  end
end
