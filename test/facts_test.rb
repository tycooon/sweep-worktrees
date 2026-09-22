# frozen_string_literal: true

require_relative "test_helper"

class FactsTest < Minitest::Test
  include TestHelper

  def setup
    super
    @main = make_repo("app")
  end

  def test_a_fresh_branch_worktree
    path, head = add_worktree(@main, "feature")
    facts = build_facts(path)

    assert_nil facts.error
    assert_equal [head, "claude/feature"], [facts.head, facts.branch]
    refute facts.dirty
    refute facts.locked
    assert facts.head_on_ref
    refute facts.head_in_default
    assert_operator facts.idle_days, :<, 1
  end

  def test_untracked_files_make_it_dirty_but_ignored_plans_do_not
    path, = add_worktree(@main, "feature")
    FileUtils.mkdir_p(File.join(path, ".plans"))
    File.write(File.join(path, ".plans", "design.md"), "x")
    clean = build_facts(path)
    File.write(File.join(path, "scratch.txt"), "x")
    dirty = build_facts(path)

    refute clean.dirty
    assert clean.plans
    assert dirty.dirty
    assert_includes dirty.dirt, "?? scratch.txt"
  end

  def test_idle_days_follow_the_newest_file
    path, = add_worktree(@main, "feature")
    age(path, 10)
    assert_in_delta 10, build_facts(path).idle_days, 0.1

    FileUtils.touch(File.join(path, "README"))
    assert_operator build_facts(path).idle_days, :<, 1
  end

  def test_dependency_dirs_do_not_count_as_activity
    path, = add_worktree(@main, "feature")
    FileUtils.mkdir_p(File.join(path, "node_modules", "pkg"))
    age(path, 10)
    FileUtils.touch(File.join(path, "node_modules", "pkg", "index.js"))

    assert_in_delta 10, build_facts(path).idle_days, 0.1
  end

  def test_a_commit_on_a_detached_head_is_on_no_ref
    path = File.join(@root, "app", "detached")
    git(@main, "worktree", "add", "-q", "--detach", path, "origin/master")
    assert build_facts(path).head_on_ref

    commit(path, "loose.txt")
    facts = build_facts(path)
    assert facts.detached?
    refute facts.head_on_ref
  end

  def test_locks_and_cheap_guards
    path, = add_worktree(@main, "feature")
    git(@main, "worktree", "lock", path)
    assert build_facts(path).locked

    facts = build_facts(path, pooled: [path], cwds: ["#{path}/sub"])
    assert facts.occupied
    assert_equal "pooled by the desktop app", facts.app_reserved
  end

  def test_pull_request_facts
    path, head = add_worktree(@main, "feature")
    facts = build_facts(path, prs: [pull_request(1, :merged, head)])

    assert_equal :merged, facts.pr.state
    assert facts.forge_ok
    assert facts.head_known
    refute build_facts(path, prs: nil).forge_ok
  end

  def test_a_worktree_without_commits_is_in_the_default_branch
    path, = add_worktree(@main, "feature", commits: 0)
    assert build_facts(path).head_in_default
  end

  def test_clone_facts
    clone = make_repo("app", dest: File.join(@root, "clone"))
    facts = build_facts(clone, kind: :clone)
    fields = %i[hosted_worktrees stash_count unpushed_refs precious_ignored]
    assert_equal [0, 0, [], []], fields.map { |field| facts[field] }

    head = commit(clone, "local.txt")
    assert_equal ["master"], build_facts(clone, kind: :clone).unpushed_refs
    merged = [pull_request(1, :merged, head)]
    assert_empty build_facts(clone, kind: :clone, prs: merged).unpushed_refs

    File.write(File.join(clone, "README"), "changed\n")
    git(clone, "stash", "-q")
    git(clone, "worktree", "add", "-q", "-b", "side", File.join(@root, "clone-side"))
    facts = build_facts(clone, kind: :clone)
    assert_equal [1, 1], [facts.hosted_worktrees, facts.stash_count]
  end

  def test_an_unpushed_tag_counts_as_unpushed_work
    clone = make_repo("app", dest: File.join(@root, "clone"))
    git(clone, "checkout", "-q", "--detach")
    commit(clone, "tagged.txt")
    git(clone, "tag", "v1")
    git(clone, "checkout", "-q", "master")

    assert_equal ["v1"], build_facts(clone, kind: :clone).unpushed_refs
  end

  def test_only_ignored_files_outside_the_disposable_set_are_precious
    clone = make_repo("app", dest: File.join(@root, "clone"))
    File.write(File.join(clone, ".git", "info", "exclude"), ".env\nnode_modules/\ndebug.log\n")
    File.write(File.join(clone, ".env"), "SECRET=1\n")
    File.write(File.join(clone, "debug.log"), "noise\n")
    FileUtils.mkdir_p(File.join(clone, "node_modules", "pkg"))
    File.write(File.join(clone, "node_modules", "pkg", "index.js"), "\n")

    assert_equal [".env"], build_facts(clone, kind: :clone).precious_ignored
  end

  def test_changes_inside_a_submodule_are_reported
    path = add_worktree_with_submodule(@main, "with-dep")
    assert_empty build_facts(path).submodule_dirt

    File.write(File.join(path, "dep", "README"), "changed\n")
    facts = build_facts(path)

    assert facts.dirty
    assert_equal ["dep"], facts.submodule_dirt
  end

  def test_checkouts_nested_inside_are_found_but_submodules_are_not
    path = add_worktree_with_submodule(@main, "host")
    FileUtils.mkdir_p(File.join(path, "tmp"))
    git(File.join(path, "tmp"), "init", "-q", "scratch")

    assert_equal ["tmp/scratch"], build_facts(path).nested_checkouts
  end

  def test_git_failures_become_a_fact_error
    path, = add_worktree(@main, "feature")
    FileUtils.rm_rf(File.join(@main, ".git", "worktrees", "feature"))
    builder = SweepWorktrees::FactsBuilder.new(
      registry: SweepWorktrees::AppRegistry.new({}),
      processes: SweepWorktrees::Processes.new([]),
      idle_floor_days: 7,
      cwd: @tmp,
    )

    facts = builder.complete(SweepWorktrees::Facts.new(path: path, kind: :worktree),
                             SweepWorktrees::Repo.new(@main), [])

    refute_nil facts.error
  end
end
