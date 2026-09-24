# frozen_string_literal: true

require "fileutils"
require "find"
require "time"
require "tmpdir"

module SweepWorktrees
  # Tarballs of what a removal would destroy: uncommitted changes, untracked files and .plans/ docs.
  class Salvage
    class Failed < StandardError
    end

    MB = 1024 * 1024
    DAY = 86_400
    TARBALL = /-\d{8}-\d{4}\.tar\.gz\z/
    # `git diff` honors the user's diff config (external tools, textconv, prefixes, colors);
    # a salvaged patch must stay a plain patch whatever that config says.
    DIFF = %w[
      diff --binary --no-ext-diff --no-textconv --no-color --no-relative --submodule=short
      --src-prefix=a/ --dst-prefix=b/ HEAD
    ].freeze

    def initialize(config, now: Time.now)
      @config = config
      @now = now
    end

    # Returns the tarball path. On Failed the checkout must stay.
    def write(facts, repo_name:, remote_url:, reason:)
      path = facts.path
      target = File.join(@config.salvage_dir, repo_name, "#{tarball_name(path)}.tar.gz")
      staged(path) do |stage, untracked, plans|
        File.write(File.join(stage, "MANIFEST"), manifest(facts, repo_name, remote_url, reason))
        copy(path, untracked, File.join(stage, "untracked"))
        copy(File.join(path, ".plans"), plans, File.join(stage, "plans"))
        pack(stage, target)
      end
      target
    end

    # The checks of write without the tarball: a dry run must keep what a real run keeps.
    def check(facts)
      staged(facts.path) { nil }
    end

    # Only tarballs this tool wrote, so a salvage_dir shared with other archives stays intact.
    def expired
      cutoff = @now - (@config.salvage_retention_days * DAY)
      files = Dir.glob(File.join(@config.salvage_dir, "*", "*.tar.gz")).grep(TARBALL)
      files.select { |file| File.mtime(file) < cutoff }.sort
    end

    private

    def staged(path)
      untracked = untracked_files(path)
      plans = plans_files(path)
      check_size!(path, untracked, plans)
      Dir.mktmpdir("sweep-salvage") do |stage|
        stage_changes(path, stage)
        yield stage, untracked, plans
      end
    rescue FactError, SystemCallError => error
      raise Failed, error.message
    end

    # The path under the root keeps same-named checkouts of one repo apart within a run.
    def tarball_name(path)
      rel = path.delete_prefix("#{@config.worktrees_root}/").tr("/", "_")
      "#{rel}-#{@now.strftime('%Y%m%d-%H%M')}"
    end

    def untracked_files(path)
      listing = Command.git!(path, "ls-files", "--others", "--exclude-standard", "-z")
      listing.split("\0").map { |rel| rel.chomp("/") }
    end

    def check_size!(path, untracked, plans)
      size = untracked.sum { |rel| bytes(File.join(path, rel)) } +
             plans.sum { |rel| bytes(File.join(path, ".plans", rel)) }
      cap = @config.salvage_max_mb
      return if size <= cap * MB

      raise Failed, "leftovers are #{(size.to_f / MB).ceil} MB, over the #{cap} MB cap"
    end

    # A patch that doesn't reverse-apply to the checkout it came from would not restore it either.
    def stage_changes(path, stage)
      patch = Command.git!(path, *DIFF)
      return if patch.empty?

      file = File.join(stage, "changes.patch")
      File.write(file, patch)
      check = Command.git(path, "apply", "--check", "--reverse", "--whitespace=nowarn", file)
      return if check.ok?

      raise Failed, "the patch does not apply back to the checkout: #{check.err.strip}"
    end

    def plans_files(path)
      dir = File.join(path, ".plans")
      return [] unless File.directory?(dir)

      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |rel| File.file?(File.join(dir, rel)) }
    end

    def bytes(file)
      stat = File.lstat(file)
      return stat.size unless stat.directory?

      total = 0
      Find.find(file) { |entry| total += File.lstat(entry).size if File.lstat(entry).file? }
      total
    end

    def copy(src_root, rels, dest_root)
      rels.each do |rel|
        src = File.join(src_root, rel)
        dest = File.join(dest_root, rel)
        FileUtils.mkdir_p(File.dirname(dest))
        if File.symlink?(src)
          File.symlink(File.readlink(src), dest)
        else
          FileUtils.cp_r(src, dest, preserve: true)
        end
      end
    end

    def pack(stage, target)
      FileUtils.mkdir_p(File.dirname(target))
      tmp = "#{target}.tmp"
      packed = Command.run("tar", "-czf", tmp, "-C", stage, ".")
      raise Failed, "tar failed: #{packed.err.strip}" unless packed.ok?

      listed = Command.run("tar", "-tzf", tmp)
      raise Failed, "the tarball does not list back: #{listed.err.strip}" unless listed.ok?

      File.link(tmp, target) # raises when the target exists: an earlier salvage is never replaced
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    def manifest(facts, repo_name, remote_url, reason)
      <<~MANIFEST + facts.dirt
        repo: #{repo_name}
        remote: #{remote_url || '-'}
        path: #{facts.path}
        branch: #{facts.branch || '(detached)'}
        head: #{facts.head}
        pull request: #{facts.pr&.url || '-'}
        reason: #{reason}
        salvaged at: #{@now.iso8601}
        restore: extract, `git apply changes.patch` on a checkout of head,
          then copy untracked/ and plans/ back

        git status --porcelain:
      MANIFEST
    end
  end
end
