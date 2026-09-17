#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync IGDB data for the play log and fetch missing cover art.
#
#   docker compose run --rm --no-deps \
#     -e IGDB_CLIENT_ID -e IGDB_CLIENT_SECRET -e STEAMGRIDDB_API_KEY \
#     --entrypoint bundle jekyll exec ruby script/fetch-covers.rb
#
# --entrypoint is required: entrypoint.sh ignores its arguments and always serves.
# Or run it from VS Code with the "Covers:" configs in .vscode/launch.json.
#
# What a run does
#   1. For every game with an `igdb_id`, saves its name, slug, release year,
#      platforms and cover id to _data/igdb.yml. The site uses that release year for
#      entries with no `year`. Commit the file: the CI build has no API keys.
#   2. For every game with no `igdb_id` that needs a year or a cover, prints IGDB
#      search candidates to pin. Title search alone never picks: it matches
#      "Riftbound" to "Demonlore" and "Destiny 2" to a GBA game.
#   3. Downloads covers for games that have none.
#
# Flags
#   --list           No credentials, no network. Lists every game with its year
#                    (and where it came from), igdb_id and cover path, or, when it
#                    has no cover, the filename to save one as plus search links.
#                    (--list-missing is an alias.)
#   --source NAME    igdb | sgdb. Default: every source you have credentials for,
#                    IGDB first, falling back to SteamGridDB for covers.
#   --dry-run        Look everything up, write and download nothing.
#   --force          Re-download covers that already exist (never an explicit `cover:`).
#
# Credentials (https://dev.twitch.tv/console/apps and
#               https://www.steamgriddb.com/profile/preferences/api)
#   IGDB_CLIENT_ID + IGDB_CLIENT_SECRET     exchanged for a token on each run
#   STEAMGRIDDB_API_KEY
#
# This script NEVER edits _data/games.yml. Round-tripping the YAML through a dumper
# would destroy every comment in it, and that file's comments are where the schema is
# documented. Everything it learns goes to _data/igdb.yml (generated, no comments to
# lose) or to cover files, and _plugins/games.rb merges both in at build time.
#
# Per-entry keys in _data/games.yml:
#   igdb_id: 1234                           IGDB data and IGDB covers need this
#   sgdb_id: 5247                           skip the SteamGridDB search
#   cover:   /assets/img/games/custom.jpg   override: never looked up or overwritten
# All of them work on a parent entry or on any of its `plays:`.

require "json"
require "net/http"
require "uri"
require "yaml"
require "fileutils"

# Cover naming and year resolution, shared with the site build.
require_relative "../_plugins/games"

ROOT      = File.expand_path("..", __dir__)
GAMES     = File.join(ROOT, "_data", "games.yml")
IGDB_DATA = File.join(ROOT, "_data", "igdb.yml")
IMG_DIR   = File.join(ROOT, Games::COVER_DIR)

LIST         = ARGV.include?("--list") || ARGV.include?("--list-missing")
DRY_RUN      = ARGV.include?("--dry-run")
FORCE        = ARGV.include?("--force")
WANT_SOURCE  = (ARGV[ARGV.index("--source") + 1] if ARGV.include?("--source"))

def http_request(req, uri)
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 25) do |http|
    http.request(req)
  end
end

def parse_json(body)
  JSON.parse(body)
rescue JSON::ParserError
  nil
end

def search_links(title)
  enc = URI.encode_www_form_component(title)
  ["igdb:    https://www.igdb.com/search?type=1&q=#{enc}",
   "sgdb:    https://www.steamgriddb.com/search/grids?term=#{enc}"]
end

# --------------------------------------------------------------------- sources ----

class IgdbSource
  NAME = "igdb"

  def initialize
    @client_id = ENV["IGDB_CLIENT_ID"].to_s.strip
    @secret    = ENV["IGDB_CLIENT_SECRET"].to_s.strip
    @token     = nil
  end

  def available?
    !@client_id.empty? && !@secret.empty?
  end

  def label
    "IGDB"
  end

  def token
    return @token if @token

    uri = URI("https://id.twitch.tv/oauth2/token")
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(client_id: @client_id, client_secret: @secret, grant_type: "client_credentials")
    res = http_request(req, uri)
    body = parse_json(res.body) || {}
    unless res.code.to_i == 200 && body["access_token"]
      warn "    IGDB auth failed: HTTP #{res.code} #{body['message'] || res.body.to_s[0, 120]}"
      return nil
    end
    @token = body["access_token"]
  end

  def query(body)
    return nil unless token

    # IGDB allows 4 requests a second and answers 429 past that.
    sleep 0.3

    uri = URI("https://api.igdb.com/v4/games")
    req = Net::HTTP::Post.new(uri)
    req["Client-ID"] = @client_id
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/json"
    req.body = body
    res = http_request(req, uri)
    unless res.code.to_i == 200
      warn "    IGDB query failed: HTTP #{res.code} #{res.body.to_s[0, 160]}"
      return nil
    end
    parse_json(res.body)
  end

  # { id => _data/igdb.yml entry } for every id IGDB knows, or nil on failure.
  def details(ids)
    rows = query("fields name,slug,first_release_date,platforms.name,cover.image_id; " \
                 "where id = (#{ids.join(',')}); limit #{ids.size};")
    return nil if rows.nil?

    rows.to_h do |r|
      [r["id"], {
        "name" => r["name"],
        "slug" => r["slug"],
        "release_year" => (Time.at(r["first_release_date"]).utc.year if r["first_release_date"]),
        "platforms" => Array(r["platforms"]).map { |p| p["name"] },
        "cover_image_id" => r.dig("cover", "image_id")
      }.compact]
    end
  end

  def candidates(title)
    # APICalypse. Quotes inside the term must be escaped or the query is invalid.
    term = title.gsub('"', '\"')
    query(%(search "#{term}"; fields name,first_release_date,platforms.abbreviation; limit 5;)) || []
  end

  # t_cover_big_2x is ~528x748, comfortably more than the cards render at.
  def self.cover_url(image_id)
    "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/#{image_id}.jpg"
  end
end

class SteamGridDbSource
  NAME = "sgdb"
  API = "https://www.steamgriddb.com/api/v2"
  # Vertical box-art proportions, which is what the cards are shaped for.
  DIMENSIONS = "600x900,342x482,660x930"

  def initialize
    @key = ENV["STEAMGRIDDB_API_KEY"].to_s.strip
  end

  def available?
    !@key.empty?
  end

  def label
    "SteamGridDB"
  end

  def get(path)
    uri = URI("#{API}#{path}")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{@key}"
    res = http_request(req, uri)
    body = parse_json(res.body) || {}
    unless res.code.to_i == 200 && body["success"]
      warn "    SteamGridDB failed: HTTP #{res.code} #{Array(body['errors']).join(', ')}"
      return nil
    end
    body["data"]
  end

  # [cover_url, "human readable match"] or nil
  def find(title, pinned_id)
    game_id = pinned_id
    name = "sgdb id #{pinned_id}"

    unless game_id
      results = get("/search/autocomplete/#{URI.encode_www_form_component(title)}")
      return nil if results.nil? || results.empty?

      game_id = results.first["id"]
      name = %(#{results.first['name']} (sgdb id #{game_id}))
    end

    grids = get("/grids/game/#{game_id}?dimensions=#{DIMENSIONS}&types=static&nsfw=false")
    grids = get("/grids/game/#{game_id}") if grids.nil? || grids.empty?
    return nil if grids.nil? || grids.empty?

    [grids.first["url"], name]
  end
end

# ------------------------------------------------------------------------ main ----

def download(url, dest)
  uri = URI(url)
  3.times do
    res = http_request(Net::HTTP::Get.new(uri), uri)
    case res
    when Net::HTTPSuccess      then File.binwrite(dest, res.body); return true
    when Net::HTTPRedirection  then uri = URI(res["location"])
    else return false
    end
  end
  false
end

games = begin
  YAML.load_file(GAMES)
rescue StandardError
  nil
end
abort "No games found in #{GAMES}." unless games.is_a?(Array) && games.any?

# One entry per play from here on: plays: children are flattened like the site does.
games = Games.flatten(games)

igdb = (YAML.load_file(IGDB_DATA) if File.exist?(IGDB_DATA)) || {}
shared = Games.shared_titles(games)

# --list is purely local: no network, so no credentials required.
if LIST
  resolved = Marshal.load(Marshal.dump(games))
  issues = Games.resolve!(resolved, igdb, ROOT)

  puts "#{games.size} game(s) in the log, #{resolved.count { |g| !g['cover_url'] }} without cover art.\n\n"
  games.zip(resolved).each do |raw, g|
    title = raw["title"].to_s
    puts "- #{[title, g['platform']].compact.join(', ')}"

    year =
      if raw["year"] then raw["year"].to_s
      elsif g["year"] then "#{g['year']}  (IGDB release year)"
      else "UNKNOWN"
      end
    puts "    year:    #{year}"

    if raw["igdb_id"]
      entry = Games.igdb_entry(raw, igdb)
      puts "    igdb_id: #{raw['igdb_id']}  #{entry ? entry['name'] : '(not synced yet, run the script)'}"
    end

    if g["cover_url"]
      puts "    cover:   #{g['cover_url']}#{raw['cover'] ? '  (explicit)' : ''}"
    else
      puts "    cover:   MISSING"
      base = Games.cover_basenames(raw, igdb, shared_title: shared.include?(Games.title_key(raw))).first
      puts(base ? "    save as: #{Games::COVER_DIR}/#{base}.jpg" : "    save as: (title is logged twice: pin igdb_id or set cover:)")
      search_links(title).each { |l| puts "    #{l}" }
    end
  end

  if issues.any?
    puts
    issues.each { |level, msg| puts "#{level.upcase}: #{msg}" }
  end
  exit 0
end

all_sources = [IgdbSource.new, SteamGridDbSource.new]
sources =
  if WANT_SOURCE
    picked = all_sources.select { |s| s.class::NAME == WANT_SOURCE }
    abort "Unknown --source #{WANT_SOURCE.inspect}. Use igdb or sgdb." if picked.empty?
    picked
  else
    all_sources
  end

usable = sources.select(&:available?)
if usable.empty?
  abort <<~MSG
    No usable credentials for #{sources.map(&:label).join(' or ')}.

    IGDB         https://dev.twitch.tv/console/apps
                 export IGDB_CLIENT_ID=...  IGDB_CLIENT_SECRET=...
    SteamGridDB  https://www.steamgriddb.com/profile/preferences/api
                 export STEAMGRIDDB_API_KEY=...

    Or skip credentials entirely and save the images by hand:
      bundle exec ruby script/fetch-covers.rb --list
  MSG
end

igdb_src = usable.find { |s| s.is_a?(IgdbSource) }
puts "#{games.size} game(s) in the log"
puts "sources: #{usable.map(&:label).join(' then ')}#{DRY_RUN ? '  [dry run]' : ''}\n\n"

# 1. IGDB data. Rebuilt from scratch each run, so an id removed from games.yml drops
#    out of the cache too. A SteamGridDB-only run leaves the cache alone.
pinned = games.filter_map { |g| g["igdb_id"]&.to_i }.uniq
if igdb_src && pinned.any?
  fresh = igdb_src.details(pinned)
  abort "IGDB lookup failed, nothing written." if fresh.nil?

  igdb = fresh.sort.to_h
  (pinned - igdb.keys).each { |id| puts "WARN: igdb_id #{id} not found on IGDB" }

  if DRY_RUN
    puts "IGDB data for #{igdb.size} game(s), not written (dry run)\n\n"
  else
    File.write(IGDB_DATA, <<~HEAD + igdb.to_yaml)
      # GENERATED by script/fetch-covers.rb from the igdb_id values in games.yml.
      # Do not edit: re-run the script. Commit it: the site build reads release years
      # and cover slugs from here and never calls IGDB itself.
    HEAD
    puts "IGDB data for #{igdb.size} game(s) -> _data/igdb.yml\n\n"
  end
end

# 2 + 3. Per game: say what is unresolved, fetch what is missing.
fetched = failed = 0

games.each do |g|
  title = g["title"].to_s
  next if title.empty?

  lines = []
  entry = Games.igdb_entry(g, igdb)
  shared_title = shared.include?(Games.title_key(g))
  wants_cover = !g["cover"] &&
                (FORCE || !Games.find_cover(ROOT, g, igdb, shared_title: shared_title))

  if entry
    lines << "igdb:  #{entry['name']} (#{entry['release_year'] || 'no release date'})"
    lines << "year:  #{entry['release_year']}, from IGDB release date" if !g["year"] && entry["release_year"]
  end
  lines << "year:  UNKNOWN. Add year:, or pin igdb_id: to use the release year." if !g["year"] && !entry&.dig("release_year")

  if igdb_src && !g["igdb_id"] && (!g["year"] || wants_cover)
    lines << "igdb:  no igdb_id. Candidates to pin:"
    igdb_src.candidates(title).each do |c|
      year = c["first_release_date"] && Time.at(c["first_release_date"]).utc.year
      platforms = Array(c["platforms"]).map { |p| p["abbreviation"] }.compact.join(",")
      lines << "         igdb_id: #{c['id'].to_s.ljust(7)} #{c['name']}  #{year}  #{platforms}"
    end
  end

  if wants_cover
    result = nil
    usable.each do |src|
      if src.is_a?(IgdbSource)
        if entry&.dig("cover_image_id")
          result = [IgdbSource.cover_url(entry["cover_image_id"]), "IGDB"]
          break
        end
        lines << "cover: IGDB has no cover art for igdb_id #{g['igdb_id']}" if entry
      else
        found = src.find(title, g["sgdb_id"])
        if found
          result = [found[0], "SteamGridDB, #{found[1]}"]
          break
        end
        lines << "cover: SteamGridDB no match"
      end
    end

    base = Games.cover_basenames(g, igdb, shared_title: shared_title).first
    if !result
      lines << "cover: FAILED, no source had one. Save one by hand (see --list)."
      failed += 1
    elsif !base
      lines << "cover: FAILED, title is logged twice so the filename is ambiguous. Pin igdb_id or set cover:."
      failed += 1
    else
      ext = File.extname(URI(result[0]).path).delete(".").downcase
      ext = "jpg" unless Games::EXTS.include?(ext)
      rel = "#{Games::COVER_DIR}/#{base}.#{ext}"

      if DRY_RUN
        lines << "cover: would save from #{result[1]} -> #{rel}"
        fetched += 1
      elsif FileUtils.mkdir_p(IMG_DIR) && download(result[0], File.join(ROOT, rel))
        lines << "cover: saved #{(File.size(File.join(ROOT, rel)) / 1024.0).round}KB from #{result[1]} -> #{rel}"
        fetched += 1
      else
        lines << "cover: FAILED download #{result[0]}"
        failed += 1
      end
    end
  end

  platform = Games.platforms(g).join(Games::PLATFORM_JOIN)
  puts "- #{[title, (platform unless platform.empty?), g['year']].compact.join(', ')}"
  lines.each { |l| puts "    #{l}" }
end

puts "\n#{fetched} cover(s) fetched, #{failed} failed"
