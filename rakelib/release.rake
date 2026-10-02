# frozen_string_literal: true

# Release flow
# ------------
# Publishing happens from a laptop. CI does not push to any registry; it only
# cuts the GitHub Release (with auto notes + the built gem) when the tag lands.
#
#   1. rake release:prepare[0.1.0]   # bump version.rb + stamp CHANGELOG, then
#                                    #   STAGE the changes and show the diff.
#   2. git diff --cached             # review
#   3. rake release:publish          # commit, publish the gem, then tag + push
#                                    #   -> the Release workflow cuts the Release
#
# To abort after prepare: git reset (unstages) or git checkout -- . (discards).
# publish is idempotent: it skips a gem already on RubyGems and only tags if the
# tag is missing, so a partial failure can be re-run.

RELEASE_VERSION_FILE = "lib/sqlite_search/version.rb"
RELEASE_CHANGELOG = "CHANGELOG.md"
RELEASE_GEM_NAME = "sqlite_search"
RELEASE_REPO = "https://github.com/radioactive-labs/sqlite_search"

namespace :release do
  def current_version
    File.read(RELEASE_VERSION_FILE)[/VERSION = "([\d.]+)"/, 1] ||
      abort("Could not read VERSION from #{RELEASE_VERSION_FILE}")
  end

  def gem_published?(version)
    # Output looks like "sqlite_search (0.2.0, 0.1.0)"; compare whole versions so
    # 0.1.0 does not match 10.1.0.
    out = `gem list --remote --exact --all #{RELEASE_GEM_NAME} 2>/dev/null`
    out[/\((.*)\)/, 1].to_s.split(",").map { |v| v.split.first }.include?(version)
  end

  desc "Show the current version"
  task :version do
    puts "Current version: #{current_version}"
  end

  desc "Stage a release (bump version + stamp changelog) for review. Pass X.Y.Z."
  task :prepare, [:version] do |_t, args|
    version = args[:version] or abort("Usage: rake release:prepare[X.Y.Z]")
    abort("Version must be X.Y.Z (got #{version.inspect})") unless version.match?(/\A\d+\.\d+\.\d+\z/)
    abort("Working tree is dirty. Commit or stash first.") unless `git status --porcelain`.strip.empty?

    puts "Preparing release v#{version}..."

    # Bump version.rb
    content = File.read(RELEASE_VERSION_FILE)
    File.write(RELEASE_VERSION_FILE, content.gsub(/VERSION = "[\d.]+"/, %(VERSION = "#{version}")))
    puts "  updated #{RELEASE_VERSION_FILE}"

    # Stamp the changelog: turn the Unreleased section into this version, add a
    # fresh empty Unreleased above it, and add the compare link.
    date = Time.now.strftime("%Y-%m-%d")
    log = File.read(RELEASE_CHANGELOG)
    log = log.sub("## [Unreleased]\n", "## [Unreleased]\n\n## [#{version}] - #{date}\n")
    log = log.sub(
      %r{^\[Unreleased\]: .*$},
      "[Unreleased]: #{RELEASE_REPO}/compare/v#{version}...HEAD\n[#{version}]: #{RELEASE_REPO}/releases/tag/v#{version}"
    )
    File.write(RELEASE_CHANGELOG, log)
    puts "  stamped #{RELEASE_CHANGELOG}"

    sh "git", "add", "-A"
    puts "\nStaged. Review with: git diff --cached"
    puts "Then: rake release:publish"
    sh "git", "--no-pager", "diff", "--cached", "--stat"
  end

  desc "Commit the staged release, publish the gem, then tag and push"
  task :publish do
    version = current_version
    tag = "v#{version}"

    if `git status --porcelain`.strip.empty?
      puts "• working tree clean, nothing to commit"
    else
      sh "git", "commit", "-m", "chore(release): v#{version}"
      puts "✓ committed release v#{version}"
    end

    if gem_published?(version)
      puts "• #{RELEASE_GEM_NAME} #{version} already on RubyGems, skipping push"
    else
      sh "gem build #{RELEASE_GEM_NAME}.gemspec"
      gem_file = "#{RELEASE_GEM_NAME}-#{version}.gem"
      sh "gem push #{gem_file}"
      File.delete(gem_file) if File.exist?(gem_file)
      puts "✓ published #{RELEASE_GEM_NAME} #{version} to RubyGems"
    end

    branch = `git branch --show-current`.strip
    if system("git rev-parse #{tag} > /dev/null 2>&1")
      puts "• tag #{tag} already exists, skipping"
    else
      sh "git", "tag", tag
    end
    sh "git", "push", "origin", branch
    sh "git", "push", "origin", tag

    puts "\n✓ Released #{tag}. The Release workflow will cut the GitHub Release."
  end
end
