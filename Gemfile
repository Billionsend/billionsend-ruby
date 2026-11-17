# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  # The Ruby image ships bigdecimal 3.1.8 already built; a newer one needs a compiler.
  gem "bigdecimal", "3.1.8"
  gem "json_schemer", "2.4.0"
  gem "minitest", "5.25.4"
  gem "rake", "13.2.1"
  # json_schemer 2.4.0 does not load with regexp_parser 2.11 or later.
  gem "regexp_parser", "2.10.0"
end
