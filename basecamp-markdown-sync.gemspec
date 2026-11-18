# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "basecamp-markdown-sync"
  spec.version = "0.4.0"
  spec.summary = "Publish Git Markdown to Basecamp with rewritten links"
  spec.authors = ["Basecamp Markdown Sync contributors"]
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "bin/*", "test/**/*.rb", "README.md", "basecamp-sync.example.yml"]
  spec.bindir = "bin"
  spec.executables = ["basecamp-md-sync"]
  spec.require_paths = ["lib"]
  spec.add_dependency "kramdown", "~> 2.5"
  spec.add_dependency "kramdown-parser-gfm", "~> 1.1"
end
