# frozen_string_literal: true

require "json"
require "uri"

module SweepWorktrees
  PullRequest = Struct.new(:number, :state, :head_sha, :source_branch, :url, keyword_init: true)

  # PR/MR state from GitHub (gh) or any other host treated as GitLab (glab). A failed lookup is nil.
  class Forge
    Remote = Struct.new(:host, :project, :ssh)

    URL_FORM = %r{\A(https?|ssh)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+?)(?:\.git)?/?\z}
    SCP_FORM = %r{\A(?:[^@/]+@)?([^/:]+):(?!/)(.+?)(?:\.git)?/?\z}
    # ssh.github.com is GitHub's SSH endpoint on port 443, for networks that block port 22.
    GITHUB_HOSTS = %w[github.com ssh.github.com].freeze
    GITLAB_STATES = { "opened" => :open, "locked" => :open, "merged" => :merged,
                      "closed" => :closed }.freeze
    GITLAB_PAGE = 100
    # Only the merged/closed history is capped: an open PR/MR must be found however old it is.
    OPEN_LIMIT = 5000

    def self.parse_remote(url)
      text = url.to_s.strip
      if (match = URL_FORM.match(text))
        Remote.new(match[2], match[3], match[1] == "ssh")
      elsif (match = SCP_FORM.match(text))
        Remote.new(match[1], match[2], true)
      end
    end

    # An open PR/MR wins; merged and closed ones only match the exact head commit.
    def self.match(prs, head:, branch:)
      prs.find do |pr|
        pr.state == :open && ((branch && pr.source_branch == branch) || pr.head_sha == head)
      end ||
        prs.find { |pr| pr.state == :merged && pr.head_sha == head } ||
        prs.find { |pr| pr.state == :closed && pr.head_sha == head }
    end

    # github_hosts: GitHub Enterprise hosts, which would otherwise be taken for GitLab.
    def initialize(limit:, runner: Command, github_hosts: [])
      @limit = limit
      @runner = runner
      @github_hosts = github_hosts
      @cache = {}
      @real_hosts = {}
    end

    def pull_requests(remote_url)
      remote = self.class.parse_remote(remote_url) or return nil
      key = [remote.host, remote.project]
      return @cache[key] if @cache.key?(key)

      @cache[key] = first_answer(remote) do |target|
        github?(target.host) ? github(target) : gitlab(target)
      end
    end

    # PRs/MRs holding the commit, for checkouts older than the capped list. A failure
    # finds nothing, which leaves the checkout where the capped list put it.
    def pull_requests_for_commit(remote_url, sha)
      remote = self.class.parse_remote(remote_url) or return []
      found = first_answer(remote) do |target|
        github?(target.host) ? github_for_commit(target, sha) : gitlab_for_commit(target, sha)
      end
      found || []
    end

    private

    def first_answer(remote)
      targets(remote).each do |target|
        answer = yield target
        return answer if answer
      end
      nil
    end

    # An SSH remote may name a Host alias from ~/.ssh/config (a second account, say), so the
    # host `ssh -G` resolves it to is asked too. The host as written goes first: the resolved
    # one may be an SSH-only endpoint or an address the CLI doesn't know. gh has no use for
    # an alias, so a GitHub host is asked alone.
    def targets(remote)
      hosts = [remote.host]
      hosts << (@real_hosts[remote.host] ||= real_host(remote.host)) if remote.ssh
      github = hosts.find { |host| github?(host) }
      (github ? [github] : hosts.uniq).map { |host| Remote.new(host, remote.project, remote.ssh) }
    end

    def real_host(host)
      res = @runner.run("ssh", "-G", host)
      (res.ok? && res.out[/^hostname (\S+)$/, 1]) || host
    end

    def github?(host) = GITHUB_HOSTS.include?(host) || @github_hosts.include?(host)

    # gh reaches github.com by default; an Enterprise host has to be named.
    def enterprise?(remote) = !GITHUB_HOSTS.include?(remote.host)

    def github_for_commit(remote, sha)
      host = enterprise?(remote) ? ["--hostname", remote.host] : []
      res = @runner.run("gh", "api", *host, "repos/#{remote.project}/commits/#{sha}/pulls")
      return nil unless res.ok?

      JSON.parse(res.out).map do |pr|
        state = if pr["state"] == "open" then :open
                elsif pr["merged_at"] then :merged
                else :closed
                end
        PullRequest.new(number: pr["number"], state: state, head_sha: pr.dig("head", "sha"),
                        source_branch: pr.dig("head", "ref"), url: pr["html_url"])
      end
    rescue JSON::ParserError
      nil
    end

    def gitlab_for_commit(remote, sha)
      project = URI.encode_www_form_component(remote.project)
      res = @runner.run("glab", "api", "--hostname", remote.host,
                        "projects/#{project}/repository/commits/#{sha}/merge_requests")
      return nil unless res.ok?

      JSON.parse(res.out).map { |mr| gitlab_mr(mr) }
    rescue JSON::ParserError
      nil
    end

    def github(remote)
      open_prs = github_list(remote, "open", OPEN_LIMIT) or return nil
      recent = github_list(remote, "all", @limit) or return nil
      (open_prs + recent).uniq(&:number)
    end

    def github_list(remote, state, limit)
      repo = enterprise?(remote) ? "#{remote.host}/#{remote.project}" : remote.project
      res = @runner.run("gh", "pr", "list", "--repo", repo, "--state", state,
                        "--limit", limit.to_s, "--json", "number,state,headRefName,headRefOid,url")
      return nil unless res.ok?

      JSON.parse(res.out).map do |pr|
        PullRequest.new(number: pr["number"], state: pr["state"].downcase.to_sym,
                        head_sha: pr["headRefOid"], source_branch: pr["headRefName"],
                        url: pr["url"])
      end
    rescue JSON::ParserError
      nil
    end

    def gitlab(remote)
      open_prs = gitlab_list(remote, "opened", OPEN_LIMIT) or return nil
      recent = gitlab_list(remote, "all", @limit) or return nil
      (open_prs + recent).uniq(&:number)
    end

    def gitlab_list(remote, state, limit)
      project = URI.encode_www_form_component(remote.project)
      prs = []
      (1..(limit.to_f / GITLAB_PAGE).ceil).each do |page|
        res = @runner.run("glab", "api", "--hostname", remote.host,
                          "projects/#{project}/merge_requests?state=#{state}&order_by=updated_at" \
                          "&per_page=#{GITLAB_PAGE}&page=#{page}")
        return nil unless res.ok?

        batch = JSON.parse(res.out)
        prs.concat(batch.map { |mr| gitlab_mr(mr) })
        break if batch.size < GITLAB_PAGE
      end
      prs
    rescue JSON::ParserError
      nil
    end

    def gitlab_mr(merge_request)
      PullRequest.new(
        number: merge_request["iid"],
        state: GITLAB_STATES.fetch(merge_request["state"], :closed),
        head_sha: merge_request["sha"],
        source_branch: merge_request["source_branch"],
        url: merge_request["web_url"],
      )
    end
  end
end
