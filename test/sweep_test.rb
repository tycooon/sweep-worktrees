# frozen_string_literal: true

require_relative "test_helper"

class SweepTest < Minitest::Test
  include TestHelper

  BIN = File.expand_path("../bin/sweep-worktrees", __dir__)
  FAKES = {
    "gh" => <<~'RUBY',
      #!/usr/bin/env ruby
      if ARGV[0] == "api"
        file = File.join(ENV.fetch("FIXTURES"), "gh-api-#{ARGV[1].tr('/', '_')}.json")
        abort("gh: no fixture for #{ARGV[1]}") unless File.exist?(file)
        print File.read(file)
        exit
      end
      repo = ARGV[ARGV.index("--repo") + 1]
      file = File.join(ENV.fetch("FIXTURES"), "gh-#{repo.tr('/', '_')}.json")
      abort("gh: no fixture for #{repo}") unless File.exist?(file)
      print File.read(file)
    RUBY
    "glab" => <<~'RUBY',
      #!/usr/bin/env ruby
      require "uri"
      path = ARGV.find { |arg| arg.start_with?("projects/") }
      project = URI.decode_www_form_component(path[%r{\Aprojects/([^/]+)/}, 1])
      file = File.join(ENV.fetch("FIXTURES"), "glab-#{project.tr('/', '_')}.json")
      abort("glab: no fixture for #{project}") unless File.exist?(file)
      print(path.match?(/[?&]page=1\z/) ? File.read(file) : "[]")
    RUBY
    # Keeps the host of an SSH remote as it is, whatever the real ~/.ssh/config says.
    "ssh" => <<~'RUBY',
      #!/usr/bin/env ruby
      puts "hostname #{ARGV.last}"
    RUBY
    # The first call is the classification snapshot; later calls are the re-checks
    # before each action.
    "lsof" => <<~'RUBY',
      #!/usr/bin/env ruby
      dir = ENV.fetch("FIXTURES")
      abort("lsof: failing on purpose") if File.exist?(File.join(dir, "lsof.fail"))
      calls = File.join(dir, "lsof.calls")
      count = File.exist?(calls) ? File.read(calls).to_i + 1 : 1
      File.write(calls, count)
      touch = File.join(dir, "lsof.late.touch")
      File.write(File.read(touch).strip, "late\n") if count == 2 && File.exist?(touch)
      files = [File.join(dir, "lsof.txt")]
      files << File.join(dir, "lsof.late.txt") if count > 1
      files.each { |file| print File.read(file) if File.exist?(file) }
    RUBY
  }.freeze

  def setup
    super
    @fixtures = File.join(@tmp, "fixtures")
    @bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p([@fixtures, @bin])
    FAKES.each do |name, source|
      File.write(File.join(@bin, name), source)
      File.chmod(0o755, File.join(@bin, name))
    end
    @main = make_repo("proj")
    write_config
  end

  def write_config(**extra)
    @config = File.join(@tmp, "config.yml")
    settings = {
      "worktrees_root" => @root,
      "salvage_dir" => File.join(@tmp, "salvage"),
      "app_registry" => File.join(@tmp, "registry.json"),
      "lock_file" => File.join(@tmp, "sweep.lock"),
    }
    File.write(@config, YAML.dump(settings.merge(extra.transform_keys(&:to_s))))
  end

  def sweep(*, env: {})
    env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "FIXTURES" => @fixtures }.merge(env)
    out, status = Open3.capture2e(env, "ruby", BIN, "--config", @config, *, chdir: @tmp)
    [out, status.exitstatus]
  end

  def github(slug, prs)
    data = prs.map do |pr|
      { "number" => pr.number, "state" => pr.state.to_s.upcase, "headRefOid" => pr.head_sha,
        "headRefName" => pr.source_branch, "url" => pr.url }
    end
    File.write(File.join(@fixtures, "gh-#{slug.tr('/', '_')}.json"), JSON.generate(data))
  end

  def github_by_commit(slug, sha, prs)
    data = prs.map do |pr|
      { "number" => pr.number, "state" => pr.state == :open ? "open" : "closed",
        "merged_at" => ("2026-06-01T00:00:00Z" if pr.state == :merged),
        "head" => { "sha" => pr.head_sha, "ref" => pr.source_branch }, "html_url" => pr.url }
    end
    file = "gh-api-repos_#{slug.tr('/', '_')}_commits_#{sha}_pulls.json"
    File.write(File.join(@fixtures, file), JSON.generate(data))
  end

  def gitlab(project, prs)
    states = { open: "opened", merged: "merged", closed: "closed" }
    data = prs.map do |pr|
      { "iid" => pr.number, "state" => states.fetch(pr.state), "sha" => pr.head_sha,
        "source_branch" => pr.source_branch, "web_url" => pr.url }
    end
    File.write(File.join(@fixtures, "glab-#{project.tr('/', '_')}.json"), JSON.generate(data))
  end

  def occupy(path) = File.write(File.join(@fixtures, "lsof.txt"), "p1\nn#{path}\n", mode: "a")

  def registry(pooled: [])
    worktrees = pooled.to_h { |path| [File.basename(path), { "path" => path, "leasedBy" => nil }] }
    File.write(File.join(@tmp, "registry.json"),
               JSON.generate("schemaVersion" => 2, "worktrees" => worktrees))
  end

  def branch?(repo, name)
    system("git", "-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/#{name}")
  end

  def tarballs = Dir.glob(File.join(@tmp, "salvage", "*", "*.tar.gz"))

  def listing(tarball) = sh!("tar", "-tzf", tarball).lines.map(&:chomp)

  def test_a_merged_clean_worktree_goes_with_its_branch
    path, head = add_worktree(@main, "done")
    github("acme/proj", [pull_request(1, :merged, head, branch: "claude/done")])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
    refute branch?(@main, "claude/done")
    assert_match(/removed 1, /, out)
  end

  def test_an_open_pr_keeps_even_an_idle_worktree
    path, = add_worktree(@main, "wip")
    age(path, 40)
    github("acme/proj", [pull_request(2, :open, "0" * 40, branch: "claude/wip")])

    out, status = sweep

    assert_equal 0, status, out
    assert File.exist?(path), out
  end

  def test_dry_run_changes_nothing_and_passes_the_flag_to_hooks
    path, head = add_worktree(@main, "done")
    github("acme/proj", [pull_request(1, :merged, head)])
    File.write(File.join(@main, "hook"), "#!/bin/sh\necho \"hook args: $*\"\n")
    File.chmod(0o755, File.join(@main, "hook"))
    write_config(hooks: { @main => "./hook" })

    out, status = sweep("--dry-run")

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert branch?(@main, "claude/done")
    assert_match(/DRY-RUN: remove #{Regexp.escape(path)}/, out)
    assert_match(/\[hook proj\] hook args: --dry-run/, out)
  end

  def test_a_worktree_without_a_pr_waits_for_the_idle_window_then_goes_keeping_its_branch
    fresh, = add_worktree(@main, "fresh")
    stale, = add_worktree(@main, "stale")
    age(stale, 20)
    github("acme/proj", [])

    out, status = sweep

    assert_equal 0, status, out
    assert File.exist?(fresh), out
    refute File.exist?(stale), out
    assert branch?(@main, "claude/stale"), "the branch of unmerged work must survive"
  end

  def test_guards_keep_live_pooled_marked_and_locked_worktrees
    worktrees = %w[live pooled marked locked].to_h { |name| [name, add_worktree(@main, name)] }
    github("acme/proj", worktrees.values.each_with_index.map do |(_, head), i|
      pull_request(i + 1, :merged, head)
    end)
    occupy(worktrees["live"][0])
    registry(pooled: [worktrees["pooled"][0]])
    FileUtils.touch(File.join(worktrees["marked"][0], ".worktree-keep"))
    git(@main, "worktree", "lock", worktrees["locked"][0])
    reasons = { "live" => "a process is running in it", "pooled" => "pooled by the desktop app",
                "marked" => ".worktree-keep", "locked" => "locked" }

    out, status = sweep("--verbose")

    assert_equal 0, status, out
    worktrees.each do |name, (path, _)|
      assert File.exist?(path), "#{path} should stay:\n#{out}"
      assert_includes out, "keep #{path}: #{reasons.fetch(name)}"
    end
  end

  def test_a_dirty_merged_worktree_is_salvaged_once_idle
    path, head = add_worktree(@main, "leftovers")
    File.write(File.join(path, "README"), "edited\n")
    File.write(File.join(path, "scratch.txt"), "notes\n")
    FileUtils.mkdir_p(File.join(path, ".plans"))
    File.write(File.join(path, ".plans", "design.md"), "# design\n")
    age(path, 8)
    github("acme/proj", [pull_request(3, :merged, head)])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
    assert_equal 1, tarballs.size, out
    entries = listing(tarballs.first)
    %w[./MANIFEST ./changes.patch ./untracked/scratch.txt ./plans/design.md].each do |entry|
      assert_includes entries, entry
    end
    assert_includes sh!("tar", "-xOzf", tarballs.first, "./MANIFEST"), "head: #{head}"
  end

  def test_a_merged_pr_older_than_the_capped_list_is_found_by_its_commit
    path, head = add_worktree(@main, "old")
    File.write(File.join(path, "scratch.txt"), "notes\n")
    age(path, 30)
    github("acme/proj", [])
    github_by_commit("acme/proj", head, [pull_request(7, :merged, head, branch: "claude/old")])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
    assert_equal 1, tarballs.size, out
    refute branch?(@main, "claude/old")
  end

  def test_a_detached_review_checkout_found_only_by_its_commit_goes
    path = File.join(@root, "proj", "old-review")
    git(@main, "worktree", "add", "-q", "--detach", path, "origin/master")
    head = commit(path, "fork-change.txt")
    age(path, 30)
    github("acme/proj", [])
    github_by_commit("acme/proj", head, [pull_request(8, :closed, head, branch: "fork-branch")])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
  end

  def test_a_dirty_merged_worktree_waits_under_the_idle_window
    path, head = add_worktree(@main, "recent")
    File.write(File.join(path, "scratch.txt"), "notes\n")
    age(path, 3)
    github("acme/proj", [pull_request(4, :merged, head)])

    out, status = sweep

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert_empty tarballs
  end

  def test_a_clean_removal_archives_plans_only
    path, head = add_worktree(@main, "planned")
    FileUtils.mkdir_p(File.join(path, ".plans"))
    File.write(File.join(path, ".plans", "plan.md"), "# plan\n")
    github("acme/proj", [pull_request(5, :merged, head)])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
    entries = listing(tarballs.first)
    assert_includes entries, "./plans/plan.md"
    refute(entries.any? { |entry| entry.start_with?("./untracked/", "./changes.patch") })
  end

  def test_a_clean_worktree_with_a_submodule_is_force_removed
    path = add_worktree_with_submodule(@main, "with-sub")
    github("acme/proj", [pull_request(6, :merged, git(path, "rev-parse", "HEAD"))])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
  end

  def test_a_staged_submodule_bump_keeps_the_checkout
    path = add_worktree_with_submodule(@main, "sub-bump")
    commit(File.join(path, "dep"), "inside.txt")
    git(path, "add", "dep")
    age(path, 12)
    github("acme/proj", [pull_request(6, :merged, git(path, "rev-parse", "HEAD"))])

    out, status = sweep("--verbose")

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert_empty tarballs
    assert_includes out, "changes inside submodules dep"
  end

  def test_a_run_without_a_locale_reads_non_ascii_forge_output
    path, head = add_worktree(@main, "unicode")
    github("acme/proj", [pull_request(1, :merged, head, branch: "claude/тест")])
    no_locale = ENV.keys.grep(/\A(?:LANG|LC_\w+)\z/).to_h { |key| [key, nil] }

    out, status = sweep(env: no_locale)

    assert_equal 0, status, out
    refute File.exist?(path), out
  end

  def test_local_env_files_keep_a_worktree_unless_they_match_the_main_checkout
    File.write(File.join(@main, ".git", "info", "exclude"), "mise.toml\n.env\n")
    File.write(File.join(@main, "mise.toml"), "[env]\nA = 1\n")
    same, same_head = add_worktree(@main, "same")
    File.write(File.join(same, "mise.toml"), "[env]\nA = 1\n")
    changed, changed_head = add_worktree(@main, "changed")
    File.write(File.join(changed, "mise.toml"), "[env]\nA = 1\nB = 2\n")
    extra, extra_head = add_worktree(@main, "extra")
    File.write(File.join(extra, ".env"), "TOKEN=local\n")
    prs = [pull_request(1, :merged, same_head), pull_request(2, :merged, changed_head),
           pull_request(3, :merged, extra_head)]
    github("acme/proj", prs)

    out, status = sweep("--verbose")

    assert_equal 0, status, out
    refute File.exist?(same), out
    assert File.exist?(changed), out
    assert File.exist?(extra), out
    assert_includes out, "local mise.toml"
    assert_includes out, "local .env"
  end

  def test_a_worktree_dirty_inside_a_submodule_is_kept_unsalvaged
    path = add_worktree_with_submodule(@main, "sub-dirt")
    File.write(File.join(path, "dep", "README"), "changed inside\n")
    age(path, 8)
    github("acme/proj", [pull_request(6, :merged, git(path, "rev-parse", "HEAD"))])

    out, status = sweep("--verbose")

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert_empty tarballs
    assert_includes out, "changes inside submodules dep"
  end

  def test_a_clone_hosting_a_nested_worktree_stays_while_the_worktree_is_judged_alone
    clone = make_repo("tool", dest: File.join(@root, "tool"))
    nested = File.join(clone, "done")
    git(@main, "worktree", "add", "-q", "-b", "claude/done", nested, "origin/master")
    head = commit(nested, "done.txt")
    github("acme/proj", [pull_request(1, :merged, head)])
    github("acme/tool", [pull_request(2, :merged, git(clone, "rev-parse", "HEAD"))])

    out, status = sweep("--verbose")

    assert_equal 0, status, out
    refute File.exist?(nested), out
    assert File.exist?(clone), out
    assert_includes out, "keep #{clone}: hosts nested checkouts: done"
  end

  def test_a_detached_review_checkout_of_a_closed_pr_goes
    path = File.join(@root, "proj", "review-7")
    git(@main, "worktree", "add", "-q", "--detach", path, "origin/master")
    github("acme/proj", [pull_request(7, :closed, git(path, "rev-parse", "HEAD"))])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
  end

  def test_a_failed_lookup_falls_back_to_the_default_branch_rule_and_warns
    in_default, = add_worktree(@main, "in-default", commits: 0)
    ahead, = add_worktree(@main, "ahead")
    age(in_default, 20)
    age(ahead, 20)

    out, status = sweep

    assert_equal 1, status, out
    assert_match(%r{PR/MR lookup failed}, out)
    refute File.exist?(in_default), out
    assert File.exist?(ahead), out
  end

  def test_gitlab_merge_requests_are_matched_by_commit
    main = make_repo("gl", url: "git@gitlab.example.com:group/sub/gl.git")
    path, head = add_worktree(main, "mr")
    gitlab("group/sub/gl", [pull_request(9, :merged, head)])

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(path), out
  end

  def test_clones_go_only_when_nothing_would_be_lost
    merged = make_repo("proj", dest: File.join(@root, "merged-clone"))
    unpushed = make_repo("proj", dest: File.join(@root, "unpushed-clone"))
    commit(unpushed, "local.txt")
    hosting = make_repo("proj", dest: File.join(@root, "hosting-clone"))
    git(hosting, "worktree", "add", "-q", "-b", "side", File.join(@root, "hosting-clone-wt"),
        "origin/master")
    commit(File.join(@root, "hosting-clone-wt"), "side.txt")
    no_remote = make_repo("proj", dest: File.join(@root, "no-remote-clone"))
    git(no_remote, "remote", "remove", "origin")
    with_env = make_repo("proj", dest: File.join(@root, "env-clone"))
    File.write(File.join(with_env, ".git", "info", "exclude"), ".env\n")
    File.write(File.join(with_env, ".env"), "SECRET=1\n")
    fresh = make_repo("proj", dest: File.join(@root, "fresh-clone"))
    [merged, unpushed, hosting, no_remote, with_env].each { |clone| age(clone, 20) }
    github("acme/proj", [pull_request(1, :merged, git(merged, "rev-parse", "HEAD"))])

    out, status = sweep("--verbose")

    assert_equal 0, status, out
    refute File.exist?(merged), out
    [unpushed, hosting, no_remote, with_env, fresh].each do |clone|
      assert File.exist?(clone), "#{clone} should stay:\n#{out}"
    end
    assert_includes out, "keep #{unpushed}: unpushed: master"
    assert_includes out, "keep #{hosting}: hosts 1 worktree(s)"
    assert_includes out, "keep #{no_remote}: unpushed: master"
    assert_includes out, "keep #{with_env}: ignored files that may matter: .env"
    assert_match(/keep #{Regexp.escape(fresh)}: merged .*, idle < 14d/, out)
  end

  def test_a_dry_run_shows_the_clone_that_goes_with_its_last_worktree
    clone = make_repo("proj", dest: File.join(@root, "review-clone"))
    worktree = File.join(@root, "review-wt")
    git(clone, "worktree", "add", "-q", "-b", "claude/review", worktree, "origin/master")
    github("acme/proj", [pull_request(1, :merged, commit(worktree, "review.txt"))])
    age(clone, 20)

    out, status = sweep("--dry-run")

    assert_equal 0, status, out
    assert File.exist?(worktree), out
    assert File.exist?(clone), out
    assert_includes out, "DRY-RUN: remove #{worktree} ("
    assert_includes out, "DRY-RUN: delete clone #{clone} ("

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(worktree), out
    refute File.exist?(clone), out
  end

  def test_the_branch_deleted_with_the_last_worktree_does_not_keep_the_clone_in_a_dry_run
    clone = make_repo("proj", dest: File.join(@root, "old-clone"))
    worktree = File.join(@root, "old-wt")
    git(clone, "worktree", "add", "-q", "-b", "claude/old", worktree, "origin/master")
    head = commit(worktree, "old.txt")
    [worktree, clone].each { |path| age(path, 30) }
    github("acme/proj", [])
    github_by_commit("acme/proj", head, [pull_request(7, :merged, head, branch: "claude/old")])

    out, status = sweep("--dry-run")

    assert_equal 0, status, out
    assert_includes out, "DRY-RUN: delete branch claude/old in #{clone}"
    assert_includes out, "DRY-RUN: delete clone #{clone} ("

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(clone), out
  end

  def test_a_process_that_appears_after_classification_stops_the_removal
    path, head = add_worktree(@main, "raced")
    github("acme/proj", [pull_request(1, :merged, head)])
    File.write(File.join(@fixtures, "lsof.late.txt"), "p9\nn#{path}\n")

    out, status = sweep

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert_includes out, "kept #{path}: a process is running in it"
  end

  def test_a_local_env_file_written_after_classification_keeps_the_worktree
    File.write(File.join(@main, ".git", "info", "exclude"), ".env\n")
    path, head = add_worktree(@main, "late-env")
    github("acme/proj", [pull_request(1, :merged, head)])
    File.write(File.join(@fixtures, "lsof.late.touch"), File.join(path, ".env"))

    out, status = sweep

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert_includes out, "kept #{path}: it changed since it was checked"
  end

  def test_a_worktree_that_changes_after_classification_is_kept
    path, head = add_worktree(@main, "moving")
    github("acme/proj", [pull_request(1, :merged, head)])
    File.write(File.join(@fixtures, "lsof.late.touch"), File.join(path, "late.txt"))

    out, status = sweep

    assert_equal 0, status, out
    assert File.exist?(path), out
    assert_includes out, "kept #{path}: it changed since it was checked"
  end

  def test_broken_and_stray_dirs_are_reported_and_empty_ones_removed
    broken = File.join(@root, "proj", "broken")
    FileUtils.mkdir_p(broken)
    File.write(File.join(broken, ".git"), "gitdir: #{File.join(@tmp, 'gone')}\n")
    stray = File.join(@root, "proj", "stray")
    FileUtils.mkdir_p(File.join(stray, ".claude"))
    empty = File.join(@root, "empty")
    FileUtils.mkdir_p(empty)
    FileUtils.touch(File.join(empty, ".DS_Store"))

    out, status = sweep

    assert_equal 0, status, out
    assert_includes out, "broken checkout, review manually: #{broken}"
    assert_includes out, "not a checkout, review manually: #{stray}"
    assert File.exist?(broken)
    assert File.exist?(stray)
    refute File.exist?(empty), out
  end

  def test_an_unreadable_registry_blocks_every_removal_prune_hook_and_expiry
    path, head = add_worktree(@main, "done")
    github("acme/proj", [pull_request(1, :merged, head)])
    File.write(File.join(@tmp, "registry.json"), "{not json")
    File.write(File.join(@main, "hook"), "#!/bin/sh\necho ran\n")
    File.chmod(0o755, File.join(@main, "hook"))
    write_config(hooks: { @main => "./hook" })
    old = File.join(@tmp, "salvage", "proj", "old-20260101-0000.tar.gz")
    FileUtils.mkdir_p(File.dirname(old))
    FileUtils.touch(old)
    File.utime(Time.now - (100 * 86_400), Time.now - (100 * 86_400), old)
    gone, = add_worktree(@main, "gone")
    FileUtils.rm_rf(gone)

    out, status = sweep

    assert_equal 1, status, out
    assert File.exist?(path), out
    assert File.exist?(old), out
    assert registered?(gone), out
    refute_includes out, "[hook proj]"
    assert_match(/nothing is removed this run/, out)
    assert_match(/removed 0, .*warnings 1\z/, out.strip)
  end

  def test_a_failing_lsof_blocks_every_removal
    path, head = add_worktree(@main, "done")
    github("acme/proj", [pull_request(1, :merged, head)])
    FileUtils.touch(File.join(@fixtures, "lsof.fail"))

    out, status = sweep

    assert_equal 1, status, out
    assert File.exist?(path), out
  end

  def registered?(path)
    git(@main, "worktree", "list", "--porcelain").include?("worktree #{path}\n")
  end

  def admin_dir(path) = git(path, "rev-parse", "--path-format=absolute", "--git-dir")

  def test_a_moved_project_folder_is_reconnected_before_the_sweep
    path, = add_worktree(@main, "moved", project: "old")
    File.write(File.join(path, "wip.txt"), "wip\n")
    _, head = add_worktree(@main, "done", project: "old")
    github("acme/proj", [pull_request(1, :merged, head, branch: "claude/done")])
    FileUtils.mv(File.join(@root, "old"), File.join(@root, "new"))
    moved = File.join(@root, "new", "moved")

    out, status = sweep

    assert_equal 0, status, out
    assert registered?(moved), out
    assert_includes git(moved, "status", "--short"), "wip.txt"
    refute File.exist?(File.join(@root, "new", "done")), out
  end

  def test_a_relative_registration_stays_relative_when_reconnected
    git_version = Gem::Version.new(git(@tmp, "version")[/\d+\.\d+/])
    skip "needs git 2.48+" if git_version < Gem::Version.new("2.48")
    git(@main, "config", "worktree.useRelativePaths", "true")
    path, = add_worktree(@main, "moved", project: "old")
    File.write(File.join(path, "wip.txt"), "wip\n")
    github("acme/proj", [])
    FileUtils.mv(File.join(@root, "old"), File.join(@root, "new"))
    moved = File.join(@root, "new", "moved")

    out, status = sweep

    assert_equal 0, status, out
    admin = admin_dir(moved)
    registered = File.read(File.join(admin, "gitdir")).strip
    refute File.absolute_path?(registered), registered
    assert_equal File.join(moved, ".git"), File.expand_path(registered, admin)
  end

  def test_a_worktree_moved_out_of_sight_keeps_its_registration
    add_worktree(@main, "active")
    path, = add_worktree(@main, "parked")
    File.write(File.join(path, "staged.txt"), "staged\n")
    git(path, "add", "staged.txt")
    parked = File.join(@root, "_parked", "parked")
    FileUtils.mkdir_p(File.dirname(parked))
    FileUtils.mv(path, parked)
    github("acme/proj", [])

    out, status = sweep

    assert_equal 0, status, out
    assert registered?(path), out
    assert_includes git(parked, "status", "--short"), "A  staged.txt"
    refute_match(/reconnected/, out)
  end

  def test_a_copy_never_takes_over_a_live_registration
    outside = File.join(@tmp, "elsewhere", "wt")
    git(@main, "worktree", "add", "-q", "-b", "claude/wt", outside, "origin/master")
    copy = File.join(@root, "proj", "wt-copy")
    FileUtils.mkdir_p(File.dirname(copy))
    FileUtils.cp_r(outside, copy)
    github("acme/proj", [])

    out, status = sweep

    assert_equal 0, status, out
    assert registered?(outside), out
    refute registered?(copy), out

    FileUtils.cp_r(copy, "#{copy}-2")
    FileUtils.rm_rf(outside)
    out, status = sweep

    assert_equal 0, status, out
    refute registered?(copy), out
    refute registered?("#{copy}-2"), out
  end

  def test_another_repositorys_worktree_at_a_stale_path_is_left_alone
    add_worktree(@main, "active")
    shared = File.join(@tmp, "elsewhere", "shared")
    git(@main, "worktree", "add", "-q", "-b", "claude/shared", shared, "origin/master")
    FileUtils.rm_rf(shared)
    other = make_repo("other")
    git(other, "worktree", "add", "-q", "-b", "mine", shared, "origin/master")
    github("acme/proj", [])

    out, status = sweep

    assert_equal 0, status, out
    common = git(shared, "rev-parse", "--path-format=absolute", "--git-common-dir")
    assert_equal File.join(other, ".git"), common
    assert_equal "mine", git(shared, "branch", "--show-current")
  end

  def test_prune_waits_while_a_worktree_outside_the_root_is_missing
    add_worktree(@main, "active")
    outside = File.join(@tmp, "outside", "wt")
    git(@main, "worktree", "add", "-q", "-b", "claude/outside", outside, "origin/master")
    FileUtils.mv(outside, "#{outside}-unmounted")
    github("acme/proj", [])

    out, status = sweep

    assert_equal 0, status, out
    assert registered?(outside), out
  end

  def test_stale_registrations_under_the_root_are_pruned_once_gc_would
    add_worktree(@main, "active")
    old, = add_worktree(@main, "old-gone")
    recent, = add_worktree(@main, "recent-gone")
    long_ago = Time.now - (100 * 86_400)
    File.utime(long_ago, long_ago, File.join(admin_dir(old), "index"))
    FileUtils.rm_rf([old, recent])
    github("acme/proj", [])

    out, status = sweep

    assert_equal 0, status, out
    refute registered?(old), out
    assert registered?(recent), out

    git(@main, "config", "gc.worktreePruneExpire", "now")
    out, status = sweep

    assert_equal 0, status, out
    refute registered?(recent), out
  end

  def test_a_second_run_exits_while_the_lock_is_held
    path, head = add_worktree(@main, "done")
    github("acme/proj", [pull_request(1, :merged, head)])
    File.open(File.join(@tmp, "sweep.lock"), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      out, status = sweep
      assert_equal 1, status, out
      assert_match(/another sweep-worktrees run/, out)
    end
    assert File.exist?(path)
  end

  def test_old_tarballs_expire
    dir = File.join(@tmp, "salvage", "proj")
    FileUtils.mkdir_p(dir)
    old = File.join(dir, "old-20260101-0000.tar.gz")
    recent = File.join(dir, "recent-20260901-0000.tar.gz")
    FileUtils.touch([old, recent])
    File.utime(Time.now - (100 * 86_400), Time.now - (100 * 86_400), old)

    out, status = sweep

    assert_equal 0, status, out
    refute File.exist?(old), out
    assert File.exist?(recent)
  end

  def test_leftovers_over_the_cap_keep_the_worktree_and_warn
    path, head = add_worktree(@main, "big")
    File.write(File.join(path, "dump.bin"), "x" * ((1024 * 1024) + 1))
    age(path, 8)
    github("acme/proj", [pull_request(1, :merged, head)])
    write_config(salvage_max_mb: 1)

    out, status = sweep

    assert_equal 1, status, out
    assert File.exist?(path), out
    assert_match(/over the 1 MB cap/, out)
  end
end
