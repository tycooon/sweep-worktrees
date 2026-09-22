# frozen_string_literal: true

require_relative "test_helper"

class DiscoveryTest < Minitest::Test
  include TestHelper

  def fake_worktree(path, gitdir)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, ".git"), "gitdir: #{gitdir}\n")
  end

  def test_classifies_what_lives_under_the_root
    alive = File.join(@tmp, "admin", "alive")
    FileUtils.mkdir_p(alive)
    fake_worktree(File.join(@root, "app", "wt"), alive)
    fake_worktree(File.join(@root, "app", "broken"), File.join(@tmp, "admin", "gone"))
    fake_worktree(File.join(@root, "legacy-wt"), alive)
    FileUtils.mkdir_p(File.join(@root, "clone", ".git"))
    FileUtils.mkdir_p(File.join(@root, "app", "stray", ".claude"))
    FileUtils.mkdir_p(File.join(@root, "empty"))
    FileUtils.mkdir_p(File.join(@root, "ds-only"))
    FileUtils.touch(File.join(@root, "ds-only", ".DS_Store"))
    FileUtils.mkdir_p(File.join(@root, "_scratch", "x", ".git"))
    FileUtils.mkdir_p(File.join(@root, "files-only"))
    FileUtils.touch(File.join(@root, "files-only", "notes.rb"))

    found = SweepWorktrees::Discover.call(@root)

    kinds = found.checkouts.to_h do |checkout|
      [checkout.path.delete_prefix("#{@root}/"), checkout.kind]
    end
    assert_equal(
      { "app/broken" => :broken, "app/wt" => :worktree, "clone" => :clone,
        "legacy-wt" => :worktree }, kinds
    )
    assert_equal [File.join(@root, "app", "stray")], found.stray_dirs
    assert_equal [File.join(@root, "ds-only"), File.join(@root, "empty")], found.empty_dirs
  end

  def test_checkouts_inside_a_first_level_clone_are_found_but_its_submodules_are_not
    main = make_repo("app")
    clone = make_repo("tool", dest: File.join(@root, "tool"))
    make_repo("dep", url: nil)
    git(clone, "submodule", "add", "-q", File.join(@tmp, "origins", "dep.git"), "dep")
    nested = File.join(clone, "wt")
    git(main, "worktree", "add", "-q", "-b", "claude/wt", nested, "origin/master")

    found = SweepWorktrees::Discover.call(@root)

    assert_equal [[clone, :clone], [nested, :worktree]], found.checkouts.map { |c|
      [c.path, c.kind]
    }
    assert_empty found.stray_dirs
  end
end
