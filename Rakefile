# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

desc "Rewrite lib/billionsend/resources.rb from the OpenAPI snapshot"
task :generate do
  ruby "script/generate.rb"
end

namespace :generate do
  desc "Fail if lib/billionsend/resources.rb differs from the OpenAPI snapshot"
  task :check do
    ruby "script/generate.rb --check"
  end
end

desc "Refresh openapi/api.openapi.json from the published document"
task :sync_openapi do
  ruby "script/sync_openapi.rb"
end

task default: %i[generate:check test]
