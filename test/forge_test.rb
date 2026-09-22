# frozen_string_literal: true

require_relative "test_helper"

class ForgeTest < Minitest::Test
  Status = Struct.new(:success?)

  # Answers each call with handler.call(args) → [stdout, ok].
  class FakeRunner
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def run(*args, **)
      @calls << args
      out, success = @handler.call(args)
      SweepWorktrees::Result.new(out, success ? "" : "boom", Status.new(success))
    end
  end

  GH_FIELDS = "number,state,headRefName,headRefOid,url"
  REMOTES = {
    "https://github.com/acme/app.git" => ["github.com", "acme/app"],
    "https://github.com/acme/app" => ["github.com", "acme/app"],
    "git@gitlab.example.com:group/app" => ["gitlab.example.com", "group/app"],
    "git@gitlab.example.com:group/sub/app.git" => ["gitlab.example.com", "group/sub/app"],
    "https://gitlab.com/group/sub/app.git" => ["gitlab.com", "group/sub/app"],
    "ssh://git@git.example.com:2222/group/app.git" => ["git.example.com", "group/app"],
  }.freeze

  def forge(runner, limit: 500) = SweepWorktrees::Forge.new(limit:, runner:)

  def pr(state, head, branch)
    SweepWorktrees::PullRequest.new(number: 1, state:, head_sha: head, source_branch: branch)
  end

  def github_pr(number, state, head, branch: "b", url: "u")
    { "number" => number, "state" => state, "headRefOid" => head, "headRefName" => branch,
      "url" => url }
  end

  def gitlab_mr(iid, state, head: "s#{iid}")
    { "iid" => iid, "state" => state, "sha" => head, "source_branch" => "b", "web_url" => "u" }
  end

  def test_parses_ssh_https_and_scp_like_remotes
    REMOTES.each do |url, (host, project)|
      remote = SweepWorktrees::Forge.parse_remote(url)
      assert_equal [host, project], [remote&.host, remote&.project], url
    end
  end

  def test_local_and_missing_remotes_are_not_forges
    [nil, "", "/srv/git/app.git", "file:///srv/git/app.git"].each do |url|
      assert_nil SweepWorktrees::Forge.parse_remote(url), url.inspect
    end
  end

  def test_github_pull_requests_are_normalized
    url = "https://github.com/acme/app/pull/3"
    runner = FakeRunner.new do
      [JSON.generate([github_pr(3, "MERGED", "abc", branch: "claude/x", url:)]), true]
    end

    prs = forge(runner).pull_requests("https://github.com/acme/app.git")

    expected = SweepWorktrees::PullRequest.new(number: 3, state: :merged, head_sha: "abc",
                                               source_branch: "claude/x", url:)
    assert_equal [expected], prs
    assert_equal [
      %W[gh pr list --repo acme/app --state open --limit 5000 --json #{GH_FIELDS}],
      %W[gh pr list --repo acme/app --state all --limit 500 --json #{GH_FIELDS}],
    ], runner.calls
  end

  def test_an_open_pr_older_than_the_capped_window_is_still_found
    old_open = github_pr(1, "OPEN", "old", branch: "claude/old")
    recent = (2..4).map { |number| github_pr(number, "MERGED", "h#{number}") }
    runner = FakeRunner.new do |args|
      [JSON.generate(args.include?("open") ? [old_open] : recent), true]
    end

    prs = forge(runner, limit: 3).pull_requests("https://github.com/acme/app.git")

    assert_equal [1, 2, 3, 4], prs.map(&:number)
    assert_equal 1, SweepWorktrees::Forge.match(prs, head: "newer", branch: "claude/old").number
  end

  def test_a_failed_or_garbled_lookup_is_nil
    failing = forge(FakeRunner.new { ["", false] })
    assert_nil failing.pull_requests("https://github.com/acme/app.git")
    assert_nil forge(FakeRunner.new { ["{oops", true] })
      .pull_requests("git@gitlab.example.com:group/app.git")
  end

  def test_gitlab_pages_each_query_until_a_short_page
    runner = FakeRunner.new do |args|
      page = args.last[/page=(\d+)\z/, 1].to_i
      batch = if args.last.include?("state=opened") then [gitlab_mr(1, "opened")]
              elsif page == 3 then [gitlab_mr(1, "opened"), gitlab_mr(2, "locked")]
              else Array.new(100) { |index| gitlab_mr((page * 100) + index, "merged") }
              end
      [JSON.generate(batch), true]
    end

    prs = forge(runner).pull_requests("git@gitlab.example.com:group/sub/app.git")

    assert_equal 4, runner.calls.size
    assert_equal 202, prs.size
    assert_equal %i[open open], prs.values_at(0, -1).map(&:state)
    query = "state=opened&order_by=updated_at&per_page=100&page=1"
    assert_equal ["glab", "api", "--hostname", "gitlab.example.com",
                  "projects/group%2Fsub%2Fapp/merge_requests?#{query}"], runner.calls.first
  end

  def test_github_pull_requests_are_found_by_commit
    rest = [
      { "number" => 7, "state" => "closed", "merged_at" => "2026-06-01T00:00:00Z",
        "head" => { "sha" => "abc", "ref" => "claude/x" }, "html_url" => "u7" },
      { "number" => 8, "state" => "closed", "merged_at" => nil,
        "head" => { "sha" => "abc", "ref" => "y" }, "html_url" => "u8" },
      { "number" => 9, "state" => "open",
        "head" => { "sha" => "abc", "ref" => "z" }, "html_url" => "u9" },
    ]
    runner = FakeRunner.new { [JSON.generate(rest), true] }

    prs = forge(runner).pull_requests_for_commit("https://github.com/acme/app", "abc")

    assert_equal [[7, :merged], [8, :closed], [9, :open]],
                 prs.map { |found| [found.number, found.state] }
    assert_equal %w[gh api repos/acme/app/commits/abc/pulls], runner.calls.first
  end

  def test_gitlab_merge_requests_are_found_by_commit
    runner = FakeRunner.new { [JSON.generate([gitlab_mr(5, "merged", head: "abc")]), true] }

    prs = forge(runner).pull_requests_for_commit("git@gitlab.example.com:g/app", "abc")

    assert_equal [[5, :merged]], prs.map { |found| [found.number, found.state] }
    assert_equal ["glab", "api", "--hostname", "gitlab.example.com",
                  "projects/g%2Fapp/repository/commits/abc/merge_requests"], runner.calls.first
  end

  def test_a_failed_commit_lookup_finds_nothing
    failing = forge(FakeRunner.new { ["", false] })

    assert_empty failing.pull_requests_for_commit("https://github.com/acme/app", "abc")
    assert_empty failing.pull_requests_for_commit("/srv/git/app.git", "abc")
  end

  def test_lookups_are_cached_per_remote
    runner = FakeRunner.new { ["[]", true] }
    cached = forge(runner)
    2.times { cached.pull_requests("https://github.com/acme/app.git") }
    cached.pull_requests("git@github.com:acme/app.git")

    assert_equal 2, runner.calls.size
  end

  def test_match_prefers_open_then_merged_then_closed
    merged = pr(:merged, "h", "b")
    closed = pr(:closed, "h", "b")
    open_by_branch = pr(:open, "other", "b")
    open_by_head = pr(:open, "h", "elsewhere")
    match = -> (prs, branch) { SweepWorktrees::Forge.match(prs, head: "h", branch:) }

    assert_same open_by_branch, match.call([closed, merged, open_by_branch], "b")
    assert_same open_by_head, match.call([merged, open_by_head], nil)
    assert_same merged, match.call([closed, merged], "b")
    assert_same closed, match.call([closed], "b")
    assert_nil SweepWorktrees::Forge.match([merged], head: "other", branch: "x")
  end
end
