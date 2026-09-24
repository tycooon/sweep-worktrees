# frozen_string_literal: true

require_relative "test_helper"

class SalvageTest < Minitest::Test
  include TestHelper

  def config(**overrides)
    values = SweepWorktrees::Config::DEFAULTS.merge("worktrees_root" => @root,
                                                    "salvage_dir" => File.join(@tmp, "salvage"))
    SweepWorktrees::Config.new(values.merge(overrides.transform_keys(&:to_s)))
  end

  def salvage(path, **)
    writer = SweepWorktrees::Salvage.new(config(**), now: Time.new(2026, 9, 21, 12, 30))
    writer.write(build_facts(path), repo_name: "app", remote_url: nil, reason: "merged")
  end

  def test_the_tarball_holds_the_patch_untracked_files_plans_and_a_manifest
    path, head = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "README"), "edited\n")
    File.write(File.join(path, "notes.txt"), "notes\n")
    FileUtils.mkdir_p(File.join(path, ".plans", "sub"))
    File.write(File.join(path, ".plans", "sub", "plan.md"), "# plan\n")

    salvage = SweepWorktrees::Salvage.new(config, now: Time.new(2026, 9, 21, 12, 30))
    tarball = salvage.write(build_facts(path), repo_name: "app",
                                               remote_url: "https://github.com/acme/app.git",
                                               reason: "merged")

    assert_equal File.join(@tmp, "salvage", "app", "app_feature-20260921-1230.tar.gz"), tarball
    entries = sh!("tar", "-tzf", tarball).lines.map(&:chomp)
    %w[./MANIFEST ./changes.patch ./untracked/notes.txt ./plans/sub/plan.md].each do |entry|
      assert_includes entries, entry
    end
    manifest = sh!("tar", "-xOzf", tarball, "./MANIFEST")
    assert_includes manifest, "head: #{head}"
    assert_includes manifest, "?? notes.txt"
    assert_includes sh!("tar", "-xOzf", tarball, "./changes.patch"), "+edited"
  end

  def test_leftovers_over_the_cap_are_refused
    path, = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "dump.bin"), "x" * 10)

    error = assert_raises(SweepWorktrees::Salvage::Failed) do
      salvage = SweepWorktrees::Salvage.new(config(salvage_max_mb: 0))
      salvage.write(build_facts(path), repo_name: "app", remote_url: nil, reason: "merged")
    end
    assert_match(/over the 0 MB cap/, error.message)
    assert_empty Dir.glob(File.join(@tmp, "salvage", "**", "*.tar.gz*"))
  end

  def test_check_refuses_what_write_would_and_writes_nothing
    path, = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "dump.bin"), "x" * 10)

    error = assert_raises(SweepWorktrees::Salvage::Failed) do
      SweepWorktrees::Salvage.new(config(salvage_max_mb: 0)).check(build_facts(path))
    end
    assert_match(/over the 0 MB cap/, error.message)
    SweepWorktrees::Salvage.new(config).check(build_facts(path))
    refute File.exist?(File.join(@tmp, "salvage"))
  end

  def test_the_patch_applies_whatever_the_diff_config
    main = make_repo("app")
    path, head = add_worktree(main, "feature")
    File.write(File.join(path, "feature-0.txt"), "changed\n")
    settings = { "diff.external" => "echo", "diff.noprefix" => "true", "color.ui" => "always",
                 "diff.mnemonicPrefix" => "true" }
    settings.each { |key, value| git(@tmp, "config", "--global", key, value) }

    tarball = salvage(path)

    check = File.join(@tmp, "check")
    git(main, "worktree", "add", "-q", "--detach", check, head)
    patch = File.join(@tmp, "changes.patch")
    File.write(patch, "#{sh!('tar', '-xOzf', tarball, './changes.patch')}\n")
    git(check, "apply", "--check", patch)
  end

  def test_same_named_checkouts_get_separate_tarballs
    main = make_repo("app")
    [["a", "claude/a-fix"], ["b", "claude/b-fix"]].map do |project, branch|
      path, = add_worktree(main, "fix", branch:, project:)
      File.write(File.join(path, "notes.txt"), "#{project}\n")
      salvage(path)
    end => [first, second]

    refute_equal first, second
    assert File.exist?(first)
    assert File.exist?(second)
  end

  def test_an_existing_tarball_is_never_overwritten
    path, = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "notes.txt"), "notes\n")
    target = File.join(@tmp, "salvage", "app", "app_feature-20260921-1230.tar.gz")
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "earlier salvage")

    assert_raises(SweepWorktrees::Salvage::Failed) { salvage(path) }
    assert_equal "earlier salvage", File.read(target)
  end

  def test_expired_lists_only_its_own_tarballs_past_retention
    dir = File.join(@tmp, "salvage", "app")
    FileUtils.mkdir_p(dir)
    old = File.join(dir, "app_old-20260101-0000.tar.gz")
    fresh = File.join(dir, "app_fresh-20260920-0000.tar.gz")
    foreign = File.join(dir, "backup.tar.gz")
    FileUtils.touch([old, fresh, foreign])
    stale = Time.now - (91 * 86_400)
    File.utime(stale, stale, old, foreign)

    assert_equal [old], SweepWorktrees::Salvage.new(config).expired
  end
end
