# frozen_string_literal: true

require_relative "lib/auto_cacher/version"

Gem::Specification.new do |spec|
  spec.name = "auto_cacher"
  spec.version = "0.1.0"
  spec.authors = ["Daniel Dailey"]
  spec.email = ["daniel@danieldailey.com"]

  spec.summary = "Automatically caches calculated fields in Rails models"
  spec.description = "A Rails gem that automatically caches calculated fields in models using database triggers"
  spec.homepage = "https://github.com/corporatetools/auto_cacher"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.glob("{bin,lib}/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "activerecord", ">= 7.0.0"
  spec.add_dependency "activesupport", ">= 7.0.0"
  spec.add_dependency "hall_monitor", ">= 0.1.0"

  # Development dependencies
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "standard", "~> 1.31"
  spec.add_development_dependency "rubocop", "~> 1.57"
  spec.add_development_dependency "rubocop-rails", "~> 2.23"
  spec.add_development_dependency "pg", "~> 1.5"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
