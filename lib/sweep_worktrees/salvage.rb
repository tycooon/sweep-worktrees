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

    def initialize(config, now: Time.now)
      @config = config
      @now = now
    end

    # Returns the tarball path. On Failed the checkout must stay.
    def write(facts, repo_name:, remote_url:, reason:)
      path = facts.path
      untracked = untracked_files(path)
      plans = plans_files(path)
      check_size!(path, untracked, plans)
      target = File.join(@config.salvage_dir, repo_name,
                         "#{File.basename(path)}-#{@now.strftime('%Y%m%d-%H%M')}.tar.gz")
      Dir.mktmpdir("sweep-salvage") do |stage|
        File.write(File.join(stage, "MANIFEST"), manifest(facts, repo_name, remote_url, reason))
        stage_changes(path, stage)
        copy(path, untracked, File.join(stage, "untracked"))
        copy(File.join(path, ".plans"), plans, File.join(stage, "plans"))
        pack(stage, target)
      end
      target
    rescue FactError, SystemCallError => error
      raise Failed, error.message
    end

    def expired
      cutoff = @now - (@config.salvage_retention_days * DAY)
      files = Dir.glob(File.join(@config.salvage_dir, "*", "*.tar.gz"))
      files.select { |file| File.mtime(file) < cutoff }.sort
    end

    private

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

    def stage_changes(path, stage)
      patch = Command.git!(path, "diff", "--binary", "HEAD")
      File.write(File.join(stage, "changes.patch"), patch) unless patch.empty?
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
        File.symlink?(src) ? File.symlink(File.readlink(src),
                                          dest) : FileUtils.cp_r(src, dest, preserve: true)
      end
    end

    def pack(stage, target)
      FileUtils.mkdir_p(File.dirname(target))
      tmp = "#{target}.tmp"
      packed = Command.run("tar", "-czf", tmp, "-C", stage, ".")
      raise Failed, "tar failed: #{packed.err.strip}" unless packed.ok?

      listed = Command.run("tar", "-tzf", tmp)
      raise Failed, "the tarball does not list back: #{listed.err.strip}" unless listed.ok?

      File.rename(tmp, target)
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
