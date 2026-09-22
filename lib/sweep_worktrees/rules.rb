# frozen_string_literal: true

module SweepWorktrees
  # action is :keep or :remove; removing a clone deletes the whole clone.
  # tag groups kept checkouts in the summary.
  Verdict = Struct.new(:action, :reason, :tag, :salvage, :force, :delete_branch, :attention,
                       keyword_init: true) do
    def remove? = action == :remove
  end

  # Pure: facts in, verdict out.
  module Rules
    module_function

    def verdict(facts, config)
      guarded = guard(facts)
      return keep(*guarded) if guarded

      decided = facts.forge_ok ? by_pull_request(facts, config) : fallback(facts, config)
      clone_wait(facts, config, decided) || decided
    end

    # Deleting a clone deletes its repository, so a clone always waits out the longer window.
    def clone_wait(facts, config, decided)
      days = config.unmerged_idle_days
      return unless decided.remove? && facts.kind == :clone && facts.idle_days < days

      waiting(decided.reason, days)
    end

    # [reason, tag] when the checkout must not be touched, else nil.
    def guard(facts)
      return ["facts unavailable: #{facts.error}", :guarded] if facts.error
      return ["the sweeper runs from it", :live] if facts.self_checkout
      return ["a process is running in it", :live] if facts.occupied
      return [facts.app_reserved, :pooled] if facts.app_reserved
      return [".worktree-keep", :guarded] if facts.keep_file
      return ["locked", :guarded] if facts.locked
      return ["detached HEAD is on no ref and no PR/MR", :guarded] if orphan_head?(facts)
      return ["hosts nested checkouts: #{list(facts.nested_checkouts)}", :guarded] if
        facts.nested_checkouts&.any?

      clone_guard(facts) if facts.kind == :clone
    end

    def orphan_head?(facts) = facts.detached? && !facts.head_on_ref && !facts.head_known

    def clone_guard(facts)
      return ["hosts #{facts.hosted_worktrees} worktree(s)", :guarded] if
        facts.hosted_worktrees.positive?
      return ["has stash entries", :guarded] if facts.stash_count.positive?
      return ["unpushed: #{list(facts.unpushed_refs)}", :guarded] if facts.unpushed_refs.any?
      return ["ignored files that may matter: #{list(facts.precious_ignored)}", :guarded] if
        facts.precious_ignored.any?

      nil
    end

    def by_pull_request(facts, config)
      pr = facts.pr
      label = pr && "#{pr.state} #{pr.url}"
      case pr&.state
      when :open then keep(label, :open)
      when :merged then merged(facts, config, label)
      else
        return remove(facts, "review of #{label}") if pr && facts.detached? && !facts.dirty

        unmerged(facts, config, label || "no PR/MR")
      end
    end

    def merged(facts, config, label)
      return remove(facts, label, delete_branch: true) unless facts.dirty
      # A tarball holds a submodule only as one gitlink line, so its changes would be lost.
      if facts.submodule_dirt&.any?
        reason = "#{label}, changes inside submodules #{list(facts.submodule_dirt)}"
        return dirty(facts, config, reason)
      end

      days = config.dirty_merged_idle_days
      return waiting(label, days) if facts.idle_days < days

      remove(facts, "#{label}, dirty, idle #{facts.idle_days.floor}d", delete_branch: true)
    end

    def unmerged(facts, config, label)
      return dirty(facts, config, label) if facts.dirty

      days = config.unmerged_idle_days
      return waiting(label, days) if facts.idle_days < days

      remove(facts, "#{label}, idle #{facts.idle_days.floor}d",
             delete_branch: facts.head_in_default)
    end

    def fallback(facts, config)
      label = "PR/MR lookup failed"
      return dirty(facts, config, label) if facts.dirty
      return keep("#{label}, HEAD not in the default branch", :other) unless facts.head_in_default

      days = config.unmerged_idle_days
      return waiting(label, days) if facts.idle_days < days

      remove(facts, "#{label}, in the default branch, idle #{facts.idle_days.floor}d",
             delete_branch: true)
    end

    def remove(facts, reason, delete_branch: false)
      Verdict.new(
        action: :remove,
        reason:,
        tag: :removed,
        salvage: facts.dirty || facts.plans || false,
        force: facts.dirty,
        delete_branch: delete_branch && facts.kind == :worktree && !facts.detached?,
        attention: false,
      )
    end

    def dirty(facts, config, label)
      keep("#{label}, dirty", :dirty).tap do |verdict|
        verdict.attention = facts.idle_days >= config.attention_idle_days
      end
    end

    def waiting(label, days) = keep("#{label}, idle < #{days}d", :waiting)

    def keep(reason, tag)
      Verdict.new(action: :keep, reason:, tag:, salvage: false, force: false,
                  delete_branch: false, attention: false)
    end

    def list(items) = items.join(", ")
  end
end
