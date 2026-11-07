# frozen_string_literal: true

require_relative "test_helper"

class SalvageTest < Minitest::Test
  include TestHelper

  MB = 1024 * 1024

  def config(**overrides)
    values = SweepWorktrees::Config::DEFAULTS.merge("worktrees_root" => @root,
                                                    "salvage_dir" => File.join(@tmp, "salvage"))
    SweepWorktrees::Config.new(values.merge(overrides.transform_keys(&:to_s)))
  end

  def salvage(path, **)
    writer = SweepWorktrees::Salvage.new(config(**), now: Time.new(2026, 9, 21, 12, 30))
    writer.write(build_facts(path), repo_name: "app", remote_url: nil, reason: "merged").tarball
  end

  def write_result(path, **)
    writer = SweepWorktrees::Salvage.new(config(**), now: Time.new(2026, 9, 21, 12, 30))
    writer.write(build_facts(path), repo_name: "app", remote_url: nil, reason: "merged")
  end

  def manifest_of(result) = sh!("tar", "-xOzf", result.tarball, "./MANIFEST")

  def entries_of(result) = sh!("tar", "-tzf", result.tarball).lines.map(&:chomp)

  def write_bytes(file, size)
    FileUtils.mkdir_p(File.dirname(file))
    File.binwrite(file, "x" * size)
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
                                               reason: "merged").tarball

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

  def test_leftovers_over_the_cap_drop_the_big_file_and_keep_the_rest
    path, = add_worktree(make_repo("app"), "feature")
    write_bytes(File.join(path, ".plans", "big.bin"), 2 * MB)
    File.write(File.join(path, ".plans", "notes.md"), "# notes\n")

    result = write_result(path, salvage_max_mb: 1)

    assert_includes entries_of(result), "./plans/notes.md"
    refute_includes entries_of(result), "./plans/big.bin"
    assert_equal ["plans/big.bin"], result.dropped.map(&:label)
    assert_includes manifest_of(result), "dropped (over the 1 MB cap):\nplans/big.bin  2.0"
  end

  def test_the_largest_entries_go_first
    path, = add_worktree(make_repo("app"), "feature")
    write_bytes(File.join(path, ".plans", "a.bin"), 3 * MB)
    write_bytes(File.join(path, ".plans", "b.bin"), 2 * MB)
    write_bytes(File.join(path, ".plans", "c.bin"), MB / 2)

    result = write_result(path, salvage_max_mb: 3)

    assert_equal ["plans/a.bin"], result.dropped.map(&:label)
    assert_includes entries_of(result), "./plans/b.bin"
  end

  def test_ties_drop_untracked_before_plans_then_by_path
    path, = add_worktree(make_repo("app"), "feature")
    write_bytes(File.join(path, "z.bin"), MB)
    write_bytes(File.join(path, ".plans", "a.bin"), MB)
    write_bytes(File.join(path, "b.bin"), MB)

    result = write_result(path, salvage_max_mb: 1)

    assert_equal %w[untracked/b.bin untracked/z.bin], result.dropped.map(&:label)
  end

  def test_an_untracked_directory_drops_as_one_unit
    path, = add_worktree(make_repo("app"), "feature")
    # git lists a nested repository as one directory entry; its files are not listed.
    nested = File.join(path, "dump")
    FileUtils.mkdir_p(nested)
    git(nested, "init", "-q")
    write_bytes(File.join(nested, "one.bin"), MB)
    write_bytes(File.join(nested, "two.bin"), MB)
    File.write(File.join(path, "small.txt"), "s")

    result = write_result(path, salvage_max_mb: 1)

    assert_equal ["untracked/dump"], result.dropped.map(&:label)
    assert_equal 1, manifest_of(result).scan("untracked/dump").size
    assert_includes entries_of(result), "./untracked/small.txt"
    assert(entries_of(result).none? { |entry| entry.include?("dump") })
  end

  def test_under_the_cap_nothing_is_dropped
    path, = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "notes.txt"), "notes\n")

    result = write_result(path)

    assert_empty result.dropped
    refute_includes manifest_of(result), "dropped ("
  end

  def test_the_patch_is_kept_when_everything_else_is_dropped
    path, = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "README"), "edited\n")
    File.write(File.join(path, "dump.bin"), "x" * 10)
    write_bytes(File.join(path, ".plans", "p.md"), 10)

    result = write_result(path, salvage_max_mb: 0)

    assert_equal 2, result.dropped.size
    assert_includes entries_of(result), "./changes.patch"
    assert(entries_of(result).none? do |entry|
      entry.start_with?("./untracked/", "./plans/") && entry.end_with?(".bin", ".md")
    end)
  end

  def test_check_reports_what_write_drops_and_writes_nothing
    path, = add_worktree(make_repo("app"), "feature")
    File.write(File.join(path, "dump.bin"), "x" * 10)

    dropped = SweepWorktrees::Salvage.new(config(salvage_max_mb: 0)).check(build_facts(path))

    assert_equal ["untracked/dump.bin"], dropped.map(&:label)
    assert_empty SweepWorktrees::Salvage.new(config).check(build_facts(path))
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
