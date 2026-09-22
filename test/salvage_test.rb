# frozen_string_literal: true

require_relative "test_helper"

class SalvageTest < Minitest::Test
  include TestHelper

  def config(**overrides)
    values = SweepWorktrees::Config::DEFAULTS.merge("salvage_dir" => File.join(@tmp, "salvage"))
    SweepWorktrees::Config.new(values.merge(overrides.transform_keys(&:to_s)))
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

    assert_equal File.join(@tmp, "salvage", "app", "feature-20260921-1230.tar.gz"), tarball
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

  def test_expired_lists_tarballs_past_retention
    dir = File.join(@tmp, "salvage", "app")
    FileUtils.mkdir_p(dir)
    old = File.join(dir, "old.tar.gz")
    fresh = File.join(dir, "fresh.tar.gz")
    FileUtils.touch([old, fresh])
    File.utime(Time.now - (91 * 86_400), Time.now - (91 * 86_400), old)

    assert_equal [old], SweepWorktrees::Salvage.new(config).expired
  end
end
