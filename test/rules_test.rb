# frozen_string_literal: true

require_relative "test_helper"

class RulesTest < Minitest::Test
  CONFIG = SweepWorktrees::Config.new(SweepWorktrees::Config::DEFAULTS)
  HEAD = "a" * 40
  BASE = {
    path: "/root/app/wt", kind: :worktree, error: nil, self_checkout: false, occupied: false,
    app_reserved: nil, keep_file: false, locked: false, head: HEAD, branch: "claude/wt", dirt: "",
    dirty: false, idle_days: 0.0, plans: false, forge_ok: true, pr: nil, head_known: false,
    head_on_ref: true, head_in_default: false,
    submodule_dirt: [], nested_checkouts: [], local_env_files: []
  }.freeze
  DIRTY = { dirty: true, dirt: "?? x\n" }.freeze
  CLONE = { kind: :clone, hosted_worktrees: 0, stash_count: 0, unpushed_refs: [],
            precious_ignored: [] }.freeze

  CASES = {
    "open PR keeps" => [{ pr: :open }, { action: :keep, tag: :open }],
    "open PR keeps even a dirty idle one" => [{ pr: :open, **DIRTY, idle_days: 90.0 },
                                              { action: :keep, tag: :open, attention: false }],
    "merged clean goes with its branch" => [{ pr: :merged },
                                            { action: :remove, delete_branch: true, salvage: false,
                                              force: false }],
    "merged clean with plans is salvaged" => [{ pr: :merged, plans: true },
                                              { action: :remove, salvage: true, force: false }],
    "merged detached has no branch to delete" => [{ pr: :merged, branch: nil },
                                                  { action: :remove, delete_branch: false }],
    "merged dirty idle 8d goes salvaged" => [{ pr: :merged, **DIRTY, idle_days: 8.0 },
                                             { action: :remove, salvage: true, force: true,
                                               delete_branch: true }],
    "merged dirty idle 3d waits" => [{ pr: :merged, **DIRTY, idle_days: 3.0 },
                                     { action: :keep, tag: :waiting }],
    "merged dirty inside a submodule stays however idle" => [
      { pr: :merged, **DIRTY, idle_days: 40.0,
        submodule_dirt: ["lib/dep"] }, { action: :keep, tag: :dirty, attention: true }
    ],
    "a local env file keeps a merged clean worktree" => [
      { pr: :merged, local_env_files: ["mise.toml"] }, { action: :keep, tag: :dirty }
    ],
    "a local env file keeps an idle unmerged worktree, flagged" => [
      { idle_days: 40.0, local_env_files: [".env"] },
      { action: :keep, tag: :dirty, attention: true },
    ],
    "hosting a nested checkout guards" => [{ pr: :merged, nested_checkouts: ["wt"] },
                                           { action: :keep, tag: :guarded }],
    "a clone hosting a nested checkout stays" => [
      { pr: :merged, **CLONE, nested_checkouts: ["tmp/scratch"] }, { action: :keep, tag: :guarded }
    ],
    "closed review checkout goes" => [{ pr: :closed, branch: nil }, { action: :remove }],
    "closed branch waits for the idle window" => [{ pr: :closed, idle_days: 5.0 },
                                                  { action: :keep, tag: :waiting }],
    "closed branch idle 20d goes and keeps its branch" => [{ pr: :closed, idle_days: 20.0 },
                                                           { action: :remove,
                                                             delete_branch: false }],
    "no PR idle 20d in the default branch loses its branch too" => [
      { idle_days: 20.0, head_in_default: true }, { action: :remove, delete_branch: true }
    ],
    "no PR idle 5d waits" => [{ idle_days: 5.0 }, { action: :keep, tag: :waiting }],
    "no PR dirty idle 40d needs attention" => [{ **DIRTY, idle_days: 40.0 },
                                               { action: :keep, tag: :dirty, attention: true }],
    "no PR dirty idle 10d is just dirty" => [{ **DIRTY, idle_days: 10.0 },
                                             { action: :keep, tag: :dirty, attention: false }],
    "failed lookup in the default branch idle 20d goes" => [
      { forge_ok: false, head_in_default: true,
        idle_days: 20.0 }, { action: :remove, delete_branch: true }
    ],
    "failed lookup outside the default branch stays" => [{ forge_ok: false, idle_days: 90.0 },
                                                         { action: :keep, tag: :other }],
    "failed lookup idle 5d waits" => [{ forge_ok: false, head_in_default: true, idle_days: 5.0 },
                                      { action: :keep, tag: :waiting }],
    "failed lookup dirty stays" => [
      { forge_ok: false, head_in_default: true, **DIRTY,
        idle_days: 90.0 }, { action: :keep, tag: :dirty }
    ],
    "a fact error guards" => [{ pr: :merged, error: "boom" }, { action: :keep, tag: :guarded }],
    "running from it guards" => [{ pr: :merged, self_checkout: true },
                                 { action: :keep, tag: :live }],
    "a live process guards" => [{ pr: :merged, occupied: true }, { action: :keep, tag: :live }],
    "the app pool guards" => [{ pr: :merged, app_reserved: "pooled by the desktop app" },
                              { action: :keep, tag: :pooled }],
    "a keep file guards" => [{ pr: :merged, keep_file: true }, { action: :keep, tag: :guarded }],
    "a lock guards" => [{ pr: :merged, locked: true }, { action: :keep, tag: :guarded }],
    "an orphan detached head guards" => [{ branch: nil, head_on_ref: false, idle_days: 90.0 },
                                         { action: :keep, tag: :guarded }],
    "a detached head known to the forge is no orphan" => [
      { pr: :merged, branch: nil, head_on_ref: false, head_known: true }, { action: :remove }
    ],
    "a clone hosting a worktree stays" => [{ pr: :merged, **CLONE, hosted_worktrees: 1 },
                                           { action: :keep, tag: :guarded }],
    "a clone with a stash stays" => [{ pr: :merged, **CLONE, stash_count: 1 },
                                     { action: :keep, tag: :guarded }],
    "a clone with unpushed work stays" => [{ pr: :merged, **CLONE, unpushed_refs: ["wip"] },
                                           { action: :keep, tag: :guarded }],
    "a clone with ignored files that may matter stays" => [
      { pr: :merged, **CLONE, idle_days: 20.0, precious_ignored: [".env"] },
      { action: :keep, tag: :guarded },
    ],
    "a merged clean clone waits out the idle window" => [{ pr: :merged, **CLONE, idle_days: 3.0 },
                                                         { action: :keep, tag: :waiting }],
    "a merged clean clone goes once idle" => [{ pr: :merged, **CLONE, idle_days: 20.0 },
                                              { action: :remove, delete_branch: false }],
    "an idle clone without a PR goes" => [{ **CLONE, idle_days: 20.0, head_in_default: true },
                                          { action: :remove, delete_branch: false }],
  }.freeze

  def pr(state)
    SweepWorktrees::PullRequest.new(number: 7, state:, head_sha: HEAD, source_branch: "claude/wt",
                                    url: "https://example.com/pr/7")
  end

  CASES.each do |name, (overrides, expected)|
    define_method("test_#{name.gsub(/\W+/, '_')}") do
      given = overrides[:pr] ? overrides.merge(pr: pr(overrides[:pr])) : overrides
      facts = SweepWorktrees::Facts.new(**BASE, **given)
      verdict = SweepWorktrees::Rules.verdict(facts, CONFIG)
      expected.each do |attr, value|
        assert_equal value, verdict.public_send(attr), "#{name}: #{attr} (#{verdict.reason})"
      end
    end
  end
end
