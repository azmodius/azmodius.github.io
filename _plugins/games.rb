# frozen_string_literal: true

# Resolves the play log in _data/games.yml before any page renders, so layouts read
# finished values instead of re-deriving them in Liquid:
#
#   year       as written, else the IGDB release year (no year = "don't remember,
#              probably when it came out")
#   cover_url  explicit `cover`, else a file in assets/img/games/ named after the
#              IGDB slug, else one named after the title slug, else nil
#
# IGDB data comes from _data/igdb.yml, which script/fetch-covers.rb writes. The build
# never calls IGDB, so CI needs no API keys.
#
# Plays: an entry is one play, or a parent with a `plays:` list when you played it
# more than once. Each play inherits the parent's keys and overrides any it sets, so
# year, platform, igdb_id and all_time can differ per play. Plays are flattened into
# ordinary entries before anything renders: every play is its own card.
#
# `platform` may be a list, for one play on several platforms at the same time. It
# is normalized to `platforms` (always a list, for future per-platform icons) and
# `platform` (the display string, "PC / Switch").
#
# Two plays with the same title, platforms AND year fail the build.
#
# script/fetch-covers.rb requires this file too, so the script and the page can never
# disagree about which file is a game's cover.

require "jekyll"

module Games
  COVER_DIR = "assets/img/games"
  EXTS = %w[jpg jpeg png webp].freeze

  PLATFORM_JOIN = " / "

  module_function

  # One hash per play, parent keys merged under each play's own.
  def flatten(games)
    return [] unless games.is_a?(Array)

    games.flat_map do |g|
      plays = g["plays"]
      next [g.dup] unless plays.is_a?(Array) && plays.any?

      parent = g.reject { |k, _| k == "plays" }
      plays.map { |play| parent.merge(play) }
    end
  end

  def platforms(game)
    Array(game["platforms"] || game["platform"]).map { |p| p.to_s.strip }.reject(&:empty?)
  end

  def title_key(game)
    game["title"].to_s.strip.downcase
  end

  # Titles logged more than once. Their title-slug filename is ambiguous (which
  # platform's art is it?), so it is never used for them.
  def shared_titles(games)
    games.map { |g| title_key(g) }.tally.select { |_, n| n > 1 }.keys
  end

  def igdb_entry(game, igdb)
    return nil unless game["igdb_id"] && igdb.is_a?(Hash)

    igdb[game["igdb_id"].to_i]
  end

  # Cover filenames to look for, most specific first, without extension. The first
  # one is where a fetched cover is saved.
  def cover_basenames(game, igdb, shared_title: false)
    names = []
    slug = igdb_entry(game, igdb)&.dig("slug")
    names << slug if slug
    names << Jekyll::Utils.slugify(game["title"].to_s) unless shared_title
    names.uniq
  end

  def find_cover(root, game, igdb, shared_title: false)
    return game["cover"] if game["cover"]

    cover_basenames(game, igdb, shared_title: shared_title).each do |base|
      EXTS.each do |ext|
        rel = "#{COVER_DIR}/#{base}.#{ext}"
        return "/#{rel}" if File.exist?(File.join(root, rel))
      end
    end
    nil
  end

  # Flattens plays and fills in year, platforms, platform and cover_url, replacing the
  # array's contents in place. Returns [level, message] pairs, level :warn or :error.
  def resolve!(games, igdb, root)
    return [] unless games.is_a?(Array)

    games.replace(flatten(games))
    issues = []
    shared = shared_titles(games)

    games.each do |g|
      list = platforms(g)
      g["platforms"] = list
      g["platform"] = list.empty? ? nil : list.join(PLATFORM_JOIN)
      g["year"] ||= igdb_entry(g, igdb)&.dig("release_year")
      g["cover_url"] = find_cover(root, g, igdb, shared_title: shared.include?(title_key(g)))
      next if g["year"]

      issues << [:warn, "#{g['title']}: no year and no cached IGDB release year, so it is " \
                        "left out of the year log. Add year:, or igdb_id: and run script/fetch-covers.rb."]
    end

    games.group_by { |g| [title_key(g), g["platforms"].map(&:downcase).sort, g["year"]] }.each_value do |dups|
      next if dups.size < 2

      g = dups.first
      issues << [:error, "#{g['title']}: #{dups.size} plays share platform " \
                         "#{g['platform'] ? g['platform'].inspect : '(none)'} and year #{g['year'].inspect}. " \
                         "Give each a different platform or year, or merge them."]
    end

    issues
  end
end

class GamesGenerator < Jekyll::Generator
  safe true
  priority :highest

  def generate(site)
    issues = Games.resolve!(site.data["games"], site.data["igdb"], site.source)
    issues.each { |_, msg| Jekyll.logger.warn("Games:", msg) }

    errors = issues.select { |level, _| level == :error }.map(&:last)
    raise Jekyll::Errors::FatalException, "_data/games.yml: #{errors.join(' ')}" if errors.any?
  end
end
