# frozen_string_literal: true

require_relative "test_helper"

class CommandTest < Minitest::Test
  def test_a_command_past_its_deadline_is_killed_and_reads_as_failed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = SweepWorktrees::Command.run("sleep", "10", timeout: 0.5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute result.ok?
    assert_match(/timed out/, result.err)
    assert_operator elapsed, :<, 5
  end

  def test_output_and_status_come_back
    result = SweepWorktrees::Command.run("sh", "-c", "echo out; echo err >&2; exit 3")

    assert_equal ["out\n", "err\n", 3], [result.out, result.err, result.status.exitstatus]
  end

  def test_stderr_can_be_merged_into_the_output
    result = SweepWorktrees::Command.run("sh", "-c", "echo out; echo err >&2", merge_err: true)

    assert result.ok?
    assert_equal "out\nerr\n", result.out
  end

  def test_a_missing_command_reads_as_failed
    refute SweepWorktrees::Command.run("definitely-not-a-command").ok?
  end
end
