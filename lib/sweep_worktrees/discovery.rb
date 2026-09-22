# frozen_string_literal: true

module SweepWorktrees
  Checkout = Struct.new(:path, :kind, keyword_init: true) # kind: :worktree, :clone or :broken
  Discovery = Struct.new(:checkouts, :stray_dirs, :empty_dirs, keyword_init: true)

  # Checkouts one or two levels under the root: `<project>/<name>` containers and
  # legacy top-level dirs.
  module Discover
    IGNORED_FILES = [".DS_Store"].freeze

    module_function

    def call(root)
      found = Discovery.new(checkouts: [], stray_dirs: [], empty_dirs: [])
      subdirs(root).each do |top|
        if git_entry?(top)
          found.checkouts << checkout(top)
          nested(top).each { |dir| found.checkouts << checkout(dir) }
        elsif (Dir.children(top) - IGNORED_FILES).empty?
          found.empty_dirs << top
        else
          subdirs(top).each do |dir|
            git_entry?(dir) ? found.checkouts << checkout(dir) : found.stray_dirs << dir
          end
        end
      end
      found
    end

    def subdirs(dir)
      names = Dir.children(dir).reject { |name| name.start_with?(".", "_") }.sort
      paths = names.map { |name| File.join(dir, name) }
      paths.select { |path| File.directory?(path) && !File.symlink?(path) }
    end

    def git_entry?(dir)
      git = File.join(dir, ".git")
      File.exist?(git) || File.symlink?(git)
    end

    # Checkouts one level inside a first-level checkout, e.g. worktrees made in a project
    # folder that is itself a clone. Submodules belong to their checkout and are left out.
    def nested(top)
      subdirs(top).select { |dir| git_entry?(dir) && !gitlink?(top, File.basename(dir)) }
    end

    def gitlink?(top, name)
      Command.git(top, "ls-files", "--stage", "--", name).out.start_with?("160000 ")
    end

    def checkout(path)
      git = File.join(path, ".git")
      return Checkout.new(path: path, kind: :clone) if File.directory?(git) && !File.symlink?(git)

      gitdir = File.read(git)[/\Agitdir: (.+)$/, 1]
      alive = gitdir && File.directory?(File.expand_path(gitdir, path))
      Checkout.new(path: path, kind: alive ? :worktree : :broken)
    rescue SystemCallError
      Checkout.new(path: path, kind: :broken)
    end
  end
end
