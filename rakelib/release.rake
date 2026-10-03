# frozen_string_literal: true

# Release flow
# ------------
# Publishing happens from a laptop. CI does not push to any registry; it only
# cuts the GitHub Release (with the CHANGELOG section + the built gem) when the
# tag lands.
#
#   1. rake release:prepare          # next version computed by git-cliff
#      rake release:prepare[1.2.3]   # ...or pass one explicitly
#                                    #   -> bump version.rb, SECURITY.md series
#                                    #   and CHANGELOG, then STAGE the changes
#                                    #   and show the diff. Nothing is committed.
#   2. git diff --cached             # review (edit CHANGELOG.md freely here)
#   3. rake release:publish          # commit, publish the gem, then tag + push
#                                    #   -> the Release workflow cuts the Release
#
# To abort after prepare: git reset --hard (discards the staged changes).
# publish is idempotent: it skips a gem already on RubyGems and only tags if the
# tag is missing, so a partial failure can be re-run.

RELEASE_CLIFF_CONFIG = ".cliff.toml"
RELEASE_VERSION_FILE = "lib/sqlite_search/version.rb"
RELEASE_CHANGELOG = "CHANGELOG.md"
RELEASE_SECURITY_FILE = "SECURITY.md"
RELEASE_GEM_NAME = "sqlite_search"

namespace :release do
  def current_version
    File.read(RELEASE_VERSION_FILE)[/VERSION = "([\d.]+)"/, 1] ||
      abort("Could not read VERSION from #{RELEASE_VERSION_FILE}")
  end

  def require_git_cliff!
    system("which git-cliff > /dev/null 2>&1") or abort("git-cliff not found. Install with: brew install git-cliff")
  end

  def previous_tag?
    system("git describe --tags --abbrev=0 --match 'v[0-9]*' > /dev/null 2>&1")
  end

  # Next version per conventional commits. git-cliff owns the semver math,
  # including the pre-1.0 rules under [bump] in .cliff.toml. With no tag yet it
  # errors out instead of returning its own 0.1.0 default, so use that here.
  def computed_next_version
    return "0.1.0" unless previous_tag?

    require_git_cliff!
    bumped = `git-cliff --config #{RELEASE_CLIFF_CONFIG} --bumped-version 2>/dev/null`.strip
    abort("git-cliff could not compute a version (no conventional commits since the last tag?)") if bumped.empty?
    bumped.delete_prefix("v")
  end

  def gem_published?(version)
    # Output looks like "sqlite_search (0.2.0, 0.1.0)"; compare whole versions so
    # 0.1.0 does not match 10.1.0.
    out = `gem list --remote --exact --all #{RELEASE_GEM_NAME} 2>/dev/null`
    out[/\((.*)\)/, 1].to_s.split(",").map { |v| v.split.first }.include?(version)
  end

  desc "Show the current version and the next one computed from conventional commits"
  task :version do
    puts "Current version: #{current_version}"
    puts "Next version:    #{computed_next_version}"
  end

  desc "Stage a release (bump + changelog) for review. Version optional; git-cliff computes it."
  task :prepare, [:version] do |_t, args|
    version = args[:version] || computed_next_version
    abort("Version must be X.Y.Z (got #{version.inspect})") unless version.match?(/\A\d+\.\d+\.\d+\z/)
    abort("Working tree is dirty. Commit or stash first.") unless `git status --porcelain`.strip.empty?

    puts "Preparing release v#{version}..."

    # Bump version.rb
    content = File.read(RELEASE_VERSION_FILE)
    File.write(RELEASE_VERSION_FILE, content.gsub(/VERSION = "[\d.]+"/, %(VERSION = "#{version}")))
    puts "  updated #{RELEASE_VERSION_FILE}"

    # Gemfile.lock records the gem's own version, so refresh it to match, or the
    # release commit ships a stale lockfile.
    Bundler.with_unbundled_env { sh "bundle", "lock", "--local" }
    puts "  updated Gemfile.lock"

    # Name the current release series (e.g. `0.1.x`) in the security policy.
    security = File.read(RELEASE_SECURITY_FILE)
    series = "#{version.split(".").first(2).join(".")}.x"
    File.write(RELEASE_SECURITY_FILE, security.gsub(/`\d+\.\d+\.x`/, "`#{series}`"))
    puts "  updated #{RELEASE_SECURITY_FILE}"

    # Changelog. git-cliff prepends a section built from the commits since the
    # last tag, below the header and leaving hand-written entries alone (`-o`
    # would regenerate the whole file from history and erase them).
    #
    # With no tag yet, git-cliff would treat the entire history, plans and fixes
    # to unshipped features included, as this release. The first release instead
    # stamps the hand-written Unreleased section.
    if previous_tag?
      require_git_cliff!
      system("git-cliff", "--config", RELEASE_CLIFF_CONFIG, "--tag", "v#{version}", "--unreleased", "--prepend", RELEASE_CHANGELOG) ||
        abort("Changelog generation failed")
    else
      log = File.read(RELEASE_CHANGELOG)
      log.include?("## [Unreleased]\n") or abort("No tag yet and no ## [Unreleased] section in #{RELEASE_CHANGELOG} to stamp")
      File.write(RELEASE_CHANGELOG, log.sub("## [Unreleased]\n", "## [#{version}] - #{Time.now.strftime("%Y-%m-%d")}\n"))
    end
    puts "  updated #{RELEASE_CHANGELOG}"

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
      sh "git", "add", "-A"
      sh "git", "commit", "-m", "chore(release): prepare for v#{version}"
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

# Neutralize the bare `rake release` that bundler/gem_tasks defines: it would tag
# and push the gem directly, skipping the review step.
if Rake::Task.task_defined?("release")
  Rake::Task["release"].clear
  task :release do
    warn "Use `rake release:prepare` then `rake release:publish`. See rakelib/release.rake."
  end
end
