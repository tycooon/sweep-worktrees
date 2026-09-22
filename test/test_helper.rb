# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../lib/sweep_worktrees"

# Every test gets its own temp dir, with git isolated from the user's global and system config.
module TestHelper
  GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
    "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com"
  }.freeze
  ENV_KEYS = [*GIT_ENV.keys, "GIT_CONFIG_GLOBAL"].freeze

  def setup
    @tmp = File.realpath(Dir.mktmpdir("sweep-test"))
    @root = File.join(@tmp, "worktrees")
    FileUtils.mkdir_p(@root)
    @saved_env = ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
    File.write(File.join(@tmp, "gitignore"), ".plans\n")
    File.write(File.join(@tmp, "gitconfig"), <<~GITCONFIG)
      [init]
      \tdefaultBranch = master
      [core]
      \texcludesFile = #{File.join(@tmp, 'gitignore')}
      [protocol "file"]
      \tallow = always
    GITCONFIG
    ENV.update(GIT_ENV.merge("GIT_CONFIG_GLOBAL" => File.join(@tmp, "gitconfig")))
  end

  def teardown
    @saved_env.each { |key, value| ENV[key] = value }
    FileUtils.rm_rf(@tmp)
  end

  def sh!(*args, chdir: @tmp)
    out, err, status = Open3.capture3(*args, chdir: chdir)
    raise "#{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def git(dir, *) = sh!("git", "-C", dir, *)

  # A bare origin with one commit on master, cloned to `dest`, whose origin URL is then
  # rewritten to `url`.
  def make_repo(name, dest: File.join(@tmp, "code", name),
                url: "https://github.com/acme/#{name}.git")
    origin = File.join(@tmp, "origins", "#{name}.git")
    unless File.directory?(origin)
      seed = File.join(@tmp, "seeds", name)
      FileUtils.mkdir_p([origin, seed])
      git(origin, "init", "--bare", "-q")
      git(seed, "init", "-q")
      commit(seed, "README", "#{name}\n")
      git(seed, "push", "-q", origin, "master")
    end
    sh!("git", "clone", "-q", origin, dest)
    git(dest, "remote", "set-url", "origin", url) if url
    dest
  end

  def commit(dir, file, content = "#{file}\n")
    File.write(File.join(dir, file), content)
    git(dir, "add", file)
    git(dir, "commit", "-q", "-m", file)
    git(dir, "rev-parse", "HEAD")
  end

  # A worktree under the root on a new branch off origin/master with `commits` commits.
  # Returns [path, head].
  def add_worktree(main, name, branch: "claude/#{name}", commits: 1, project: File.basename(main))
    path = File.join(@root, project, name)
    git(main, "worktree", "add", "-q", "-b", branch, path, "origin/master")
    commits.times { |i| commit(path, "#{name}-#{i}.txt") }
    [path, git(path, "rev-parse", "HEAD")]
  end

  # A worktree of `main` off its local master, which carries an initialized `dep` submodule.
  def add_worktree_with_submodule(main, name)
    make_repo("dep", url: nil) unless File.directory?(File.join(@tmp, "origins", "dep.git"))
    unless File.exist?(File.join(main, ".gitmodules"))
      git(main, "submodule", "add", "-q", File.join(@tmp, "origins", "dep.git"), "dep")
      git(main, "commit", "-q", "-m", "add dep")
    end
    path = File.join(@root, File.basename(main), name)
    git(main, "worktree", "add", "-q", "-b", "claude/#{name}", path, "master")
    git(path, "submodule", "update", "--init", "-q")
    path
  end

  def age(path, days)
    time = Time.now - (days * 86_400)
    gitdir = git(path, "rev-parse", "--path-format=absolute", "--git-dir")
    entries = Dir.glob("**/*", File::FNM_DOTMATCH, base: path).map { |rel| File.join(path, rel) }
    entries += [path, File.join(gitdir, "HEAD"), File.join(gitdir, "logs", "HEAD")]
    entries.each do |entry|
      File.utime(time, time, entry) if File.exist?(entry) && !File.symlink?(entry)
    end
  end

  def pull_request(number, state, head, branch: "x", url: "https://example.com/pr/#{number}")
    SweepWorktrees::PullRequest.new(number: number, state: state, head_sha: head,
                                    source_branch: branch, url: url)
  end

  def build_facts(path, kind: :worktree, prs: [], pooled: [], cwds: [])
    registry = SweepWorktrees::AppRegistry.new(pooled.to_h do |p|
      [p, { "path" => p, "leasedBy" => nil }]
    end)
    builder = SweepWorktrees::FactsBuilder.new(registry: registry, processes: SweepWorktrees::Processes.new(cwds),
                                               idle_floor_days: 7, cwd: @tmp)
    repo = kind == :clone ? SweepWorktrees::Repo.new(path) : SweepWorktrees::Repo.of(path)
    builder.complete(builder.cheap(SweepWorktrees::Checkout.new(path: path, kind: kind)), repo, prs)
  end
end
