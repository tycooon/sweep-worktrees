# frozen_string_literal: true

require_relative "test_helper"

class AppRegistryTest < Minitest::Test
  include TestHelper

  def write(data)
    File.join(@tmp, "registry.json").tap do |path|
      File.write(path, data.is_a?(String) ? data : JSON.generate(data))
    end
  end

  def test_pooled_and_creating_entries_are_reserved
    registry = SweepWorktrees::AppRegistry.load(write("worktrees" => {
      "a" => { "path" => "/w/a", "leasedBy" => nil },
      "b" => { "path" => "/w/b", "leasedBy" => "local_1", "status" => "creating" },
      "c" => { "path" => "/w/c", "leasedBy" => "local_2" },
      "d" => { "leasedBy" => nil },
    }))

    assert_equal "pooled by the desktop app", registry.reason("/w/a")
    assert_equal "being created by the desktop app", registry.reason("/w/b")
    assert_nil registry.reason("/w/c")
    assert_nil registry.reason("/w/elsewhere")
  end

  def test_a_missing_registry_reserves_nothing
    assert_nil SweepWorktrees::AppRegistry.load(File.join(@tmp, "absent.json")).reason("/w/a")
  end

  def test_an_unparseable_registry_raises
    assert_raises(SweepWorktrees::AppRegistry::Unreadable) { SweepWorktrees::AppRegistry.load(write("{nope")) }
    assert_raises(SweepWorktrees::AppRegistry::Unreadable) { SweepWorktrees::AppRegistry.load(write("[]")) }
  end
end

class ProcessesTest < Minitest::Test
  include TestHelper

  Status = Struct.new(:success?)

  def runner(out, success: true)
    result = SweepWorktrees::Result.new(out, success ? "" : "denied", Status.new(success))
    Object.new.tap { |fake| fake.define_singleton_method(:run) { |*| result } }
  end

  def test_a_cwd_inside_a_checkout_occupies_it_but_a_sibling_prefix_does_not
    app = File.join(@root, "app")
    FileUtils.mkdir_p([File.join(app, "sub"), "#{app}2"])
    lsof = "p1\nn#{app}/sub\np2\nn/elsewhere\n"
    processes = SweepWorktrees::Processes.snapshot(runner: runner(lsof))

    assert processes.occupied?(app)
    refute processes.occupied?("#{app}2")
  end

  def test_a_failing_lsof_raises
    assert_raises(SweepWorktrees::Processes::Unavailable) do
      SweepWorktrees::Processes.snapshot(runner: runner("", success: false))
    end
  end
end
