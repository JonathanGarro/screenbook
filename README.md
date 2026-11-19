# Watchlist

A personal Mac app that tracks saved movies and TV shows. It flags movies when their release date arrives in your region and shows when new episodes air that you have not watched yet. It is a native SwiftUI app with a small command line tool for scheduled checks. Everything stays on your machine in one SQLite file.

Built for one person. No accounts, no sync, no notarization.

Features:

- Search TMDB and save movies and shows
- Movie release dates for your region, with the digital date alongside
- Per-episode watched tracking, with "mark watched up to here"
- What's New after every check: movies released and episodes aired since last time
- Menu bar count of unwatched episodes
- Notifications for new episodes and movie releases
- Optional streaming availability (JustWatch data via TMDB)
- Markdown digest and CSV export
- A `watchlist` CLI that shares the same database

You need your own free TMDB API key. None is included in this repository.

## Setup

Requirements: macOS 14 or later and Xcode (the build script uses `/Applications/Xcode.app` automatically if Command Line Tools is the active developer directory).

1. Get a free TMDB API key: create an account at themoviedb.org, then go to Settings, API. Either the v3 "API Key" or the v4 "API Read Access Token" works.
2. Clone and build:
   ```sh
   git clone https://github.com/JonathanGarro/watchlist.git
   cd watchlist
   ./build_app.sh
   ```
   This produces `build/Watchlist.app` and `build/bin/watchlist` (the CLI).
3. Open `build/Watchlist.app` (drag it to /Applications if you like). Open Settings (Cmd+,) and paste the key.
   You can also set the key without the app:
   - `build/bin/watchlist config --api-key YOUR_KEY`, or
   - copy `.env.example` to `~/Library/Application Support/Watchlist/.env` and fill it in, or
   - export `TMDB_API_KEY` in your shell (takes priority over the file).
4. Press Cmd+N to add titles, Cmd+R to check.

The key is never stored in source. The app and CLI read `TMDB_API_KEY` from the environment first, then from the `.env` file in the data folder (written with owner-only permissions).

## Using the app

- **Sidebar**: What's New (results of the last check), Upcoming (anything with a future date), Unwatched (shows with aired episodes you have not marked), Movies, TV Shows, Everything.
- **Add (Cmd+N)**: search TMDB, pick a result, add it. For shows, tick "I'm caught up" to mark every aired episode watched so only future episodes count as new.
- **Check on open**: the app runs a check each time it opens (turn off in Settings, Checking). Details are cached for an hour, so reopening often is cheap.
- **Menu bar count**: a TV icon in the menu bar shows the total number of unwatched aired episodes. Click it for a per-show list (pick one to open it), Check Now, and Open Watchlist. While it is on, closing the window keeps the app running; Cmd+Q quits. Turn it off in Settings, Checking.
- **Notifications**: when a check finds newly aired episodes or a saved movie whose release date has arrived, macOS shows a notification per title (or one summary if there are more than four). Each episode and release is announced once. Clicking it opens the title. While the app is running it also checks every 6 hours, so notifications arrive without opening the window. These are in Settings, Notifications, with a Send Test button. Checks run by the CLI (cron or launchd) do not notify, and they mark episodes and releases as already reported, so pick one: the app's 6 hour check or a scheduled CLI job.
- **Check Now (Cmd+R)**: refreshes every title. Shift+Cmd+R bypasses the one hour cache.
- **Detail pane**: dates, status, overview, and for shows an episode list per season. Click the circle to toggle watched. Right click an episode for "Mark Watched Up to Here". The checkmark menu marks a whole season or everything aired.
- **Watchlist menu**: Write Digest (Cmd+D) writes `outputs/digest.md` and reveals it in Finder. Export CSV writes `outputs/watchlist.csv`. Show Data Folder opens the folder.
- **Settings**: API key, check on open, menu bar count, notifications and the 6 hour check, region, streaming toggle, rent/buy toggle.

## CLI commands

The CLI shares the same database and settings as the app.

```
watchlist add <search term> [--caught-up] [--pick N]
watchlist remove <tmdb_id> [--movie | --tv]
watchlist list
watchlist check [--force]
watchlist watch <tmdb_id> <season> <episode> [--unwatch]
watchlist watch <tmdb_id> --all-up-to <season> <episode>
watchlist digest [--force]
watchlist export
watchlist config [--region XX] [--streaming on|off] [--rent-buy on|off] [--check-on-open on|off] [--menu-bar on|off] [--notify on|off] [--notify-movies on|off] [--periodic on|off] [--api-key KEY]
watchlist paths
```

- `add` prints the top 10 matches and asks for a number. `--pick N` skips the prompt.
- `remove` needs `--movie` or `--tv` only when a movie and a show share the same TMDB id (TMDB ids are unique per type, not globally).
- `check` prints movies released since the last check, shows with new aired episodes since the last check, and shows that still have an unwatched backlog.
- `digest` writes `outputs/digest.md` and prints it. If a check already ran today it reuses that result, so running `check` then `digest` does not lose the "new" items. `--force` runs a fresh check.
- `--data-dir PATH` (before the command) or `WATCHLIST_DATA_DIR` points at a different data folder, handy for testing.

## Where data lives

Everything is in `~/Library/Application Support/Watchlist/`:

```
watchlist.db        sqlite database
config.json         region and streaming settings
.env                TMDB_API_KEY (if saved from the app or cli)
outputs/
  digest.md         written by digest
  watchlist.csv     written by export
```

A GUI app has no meaningful working directory, so the relative paths from the original spec (`watchlist.db`, `outputs/digest.md`) are relative to this folder instead.

### Tables

Open `watchlist.db` in any SQLite client.

- `titles`: `tmdb_id`, `media_type` ('movie' or 'tv'), `title`, `year`, `region_release_date`, `added_on`, plus `digital_release_date`, `status`, `overview`, `poster_path`, `last_aired_season/episode/date`, `next_air_season/episode/date`, `seen_season/episode` (the latest aired episode at the previous check), `release_flagged` (movie release already reported), `last_refreshed`. Primary key is (`tmdb_id`, `media_type`).
- `watched_episodes`: `tmdb_id`, `season`, `episode`, `watched_on`.
- `seasons`: `tmdb_id`, `season_number`, `episode_count`, `air_date`, `name`. Copied from the series details call; used to work out which episodes have aired.
- `api_cache`: `cache_key` (path plus sorted query, never the key), `body` (raw JSON), `fetched_at`.
- `meta`: `last_check` timestamp and `last_report` (the last check result as JSON).

## Data source notes

All data comes from the TMDB API v3 (`https://api.themoviedb.org/3`). Field names below were checked against developer.themoviedb.org on 2026-11-19.

| Use | Endpoint | Fields read |
| --- | --- | --- |
| Search | `GET /search/multi?query=` | `results[].id`, `media_type` (movie/tv kept, person dropped), `title` / `name`, `release_date` / `first_air_date`, `overview`, `poster_path` |
| Movie | `GET /movie/{id}?append_to_response=release_dates` | `title`, `release_date`, `status`, `overview`, `poster_path`, `release_dates.results[].iso_3166_1`, `.release_dates[].release_date`, `.type` |
| Show | `GET /tv/{id}` | `name`, `first_air_date`, `status`, `overview`, `poster_path`, `seasons[].season_number/episode_count/air_date/name`, `last_episode_to_air` and `next_episode_to_air` (`season_number`, `episode_number`, `air_date`) |
| Episodes | `GET /tv/{id}/season/{n}` | `episodes[].episode_number`, `season_number`, `name`, `air_date` |
| Streaming | `GET /{movie or tv}/{id}/watch/providers` | `results.{REGION}.link`, `flatrate[]`, `rent[]`, `buy[]` with `provider_name`, `logo_path`, `display_priority` |

Auth: a v3 key goes in the `api_key` query parameter. A v4 read access token (starts with `eyJ`) is sent as `Authorization: Bearer`. Both give the same access.

### Movie release date choice

TMDB stores many release dates per movie: one list per country, each entry typed 1 Premiere, 2 Theatrical (limited), 3 Theatrical, 4 Digital, 5 Physical, 6 TV. Watchlist picks one date deliberately:

1. Look only at entries for your region (default `US`).
2. Take the earliest **wide theatrical (3)** date. If there is none, fall back in order to limited theatrical (2), digital (4), physical (5), TV (6), premiere (1).
3. If the region has no entries at all, use TMDB's top level `release_date` (the primary release, often another country's date).

Wide theatrical comes before limited because a limited run in two cities is not when most people can see a movie. Festival premieres come last for the same reason. The earliest **digital (4)** date is stored separately and shown as "Digital", since for streaming-first viewing that is often the date that matters. A movie is reported once when its chosen date arrives. If the date is pushed back into the future, the flag resets and it is reported again when the new date arrives.

### TV episode logic

- Dates are TMDB's original air dates only.
- "Aired" episodes are worked out without extra calls: every episode of seasons before `last_episode_to_air`'s season (using `seasons[].episode_count`), plus episodes 1 through `last_episode_to_air.episode_number` of its season. Season 0 (specials) is ignored.
- "Unwatched" means aired and not in `watched_episodes`.
- "New since last check" means unwatched episodes later than the latest aired episode recorded at the previous check (`seen_season`/`seen_episode`). Adding a show sets that marker, so a show's back catalog is a backlog, not "new".
- The full per-season episode list (`/tv/{id}/season/{n}`) is fetched only when you open a show in the app.

### Caching and rate limits

| Response | Reused for |
| --- | --- |
| Search | 1 day |
| Movie and show details | 1 hour (so repeated checks do not refetch; `--force` bypasses) |
| Season episode lists | 6 hours |
| Watch providers | 30 days |

TMDB says its limit is "somewhere in the 40 requests per second range" and asks clients to respect HTTP 429. Watchlist waits 0.25 seconds between calls and retries a 429 up to 4 times, honoring `Retry-After` when present and otherwise backing off 1, 2, 4, 8 seconds. If the network is down, a stale cached response is used when available.

## Streaming availability (optional)

Off by default. Turn it on in Settings or with `watchlist config --streaming on`. When on:

- The detail pane shows subscription ("flatrate") services for your region. Rent and buy are hidden unless "Include rent and buy" is on.
- The digest adds a Streaming column for newly released movies and shows with unwatched episodes.
- Results are cached for 30 days.

This data comes from JustWatch through TMDB. JustWatch attribution is shown in the app and digest whenever streaming is on.

## Scheduling a daily check

Optional. The app already checks whenever it opens and every 6 hours while it runs. A scheduled job is only useful if you want the digest refreshed while the app is closed. The app has no scheduler built in, so use cron or launchd with the CLI.

First copy the CLI out of `~/Documents`. macOS privacy protection can block background jobs from running binaries stored in Documents.

```sh
mkdir -p ~/.local/bin
cp build/bin/watchlist ~/.local/bin/watchlist
```

Background jobs do not see your shell's environment variables, so save the key to the data folder (`watchlist config --api-key ...` or the app's Settings).

### cron (macOS or Linux)

`crontab -e`, then add a line to check every day at 8:00 and append the output to a log in `outputs/`:

```
0 8 * * * "$HOME/.local/bin/watchlist" check >> "$HOME/Library/Application Support/Watchlist/outputs/check.log" 2>&1
```

Swap `check` for `digest` to also rewrite `outputs/digest.md` each morning.

### launchd (macOS)

launchd is the native option, and it catches up on a missed run if the Mac was asleep at 8:00. Create `~/Library/LaunchAgents/local.personal.watchlist.plist`, replacing `YOU` with your user name (launchd does not expand `~`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.personal.watchlist</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOU/.local/bin/watchlist</string>
        <string>digest</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>8</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardOutPath</key><string>/Users/YOU/Library/Application Support/Watchlist/outputs/check.log</string>
    <key>StandardErrorPath</key><string>/Users/YOU/Library/Application Support/Watchlist/outputs/check.log</string>
</dict>
</plist>
```

Load it, and run it once to test:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.personal.watchlist.plist
launchctl kickstart gui/$(id -u)/local.personal.watchlist
```

To remove it: `launchctl bootout gui/$(id -u)/local.personal.watchlist`.

## Development

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if Command Line Tools is selected
swift build
swift test
swift run WatchlistApp      # run the app without bundling
swift run watchlist list    # run the cli
```

Layout:

```
Package.swift
build_app.sh                  builds the .app bundle and the cli
make_icon.swift               draws the app icon (run by build_app.sh)
Sources/WatchlistCore/        shared logic
  Config.swift                paths, config.json, api key lookup
  Database.swift              sqlite setup and queries
  TMDBClient.swift            api wrapper with caching and rate limit handling
  WatchlistService.swift      add, remove, check, watch, release date and episode logic
  Digest.swift                markdown digest, text tables, csv, attribution
Sources/WatchlistApp/         swiftui app
Sources/watchlist/main.swift  cli
Tests/WatchlistCoreTests/     swift testing suite with a mocked http transport (no network)
```

### Differences from the original Python spec

- Swift and SwiftUI instead of Python. Pandas is not used. Table formatting for `list`, the digest, and CSV export is done in `Digest.swift`.
- argparse is replaced by a small hand-written parser with the same commands.
- Data lives in Application Support rather than next to the script, because a Mac app has no meaningful working directory.
- pytest is replaced by Swift Testing (`swift test`).
- The titles table has extra columns (see above) so `list` and `check` work without calling the API.

## Attribution

This product uses the TMDB API but is not endorsed or certified by TMDB. Movie and TV data, images, and search come from [The Movie Database (TMDB)](https://www.themoviedb.org).

Streaming availability data is provided by [JustWatch](https://www.justwatch.com) through TMDB's watch providers endpoint.

## Future ideas (out of scope for v1)

- iOS companion app or a web UI
- Ratings, reviews, or personal notes
- Import from other watchlist apps (Trakt, TV Time, Letterboxd exports)
- Multi-user support or iCloud sync
