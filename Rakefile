# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new do |task|
  task.pattern = "test/**/*_test.rb"
  task.warning = false
end

RuboCop::RakeTask.new

task default: %i[test rubocop]
