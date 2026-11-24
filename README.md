# Screenbook

A Mac app for everything you watch. It tracks movies and TV shows you care about (release dates for your region, new episodes, a 30-day calendar, what you can watch now), keeps a library of everything you have seen, and lets you write reviews that live in your Obsidian vault as plain markdown notes. It is a native SwiftUI app with a small command line tool, plus an iPhone companion for checking off episodes and adding titles on the go. Your data lives in one SQLite file and your vault, and syncs between your devices through your own iCloud account.

**Website:** https://screenbook.app · **Download:** [Screenbook.dmg](https://github.com/JonathanGarro/screenbook/releases/latest/download/Screenbook.dmg) (signed and notarized, updates itself)

No accounts beyond your own iCloud, and no analytics. Bring your own free TMDB key.

Features:

- Search TMDB and save movies and shows
- Movie release dates for your region, with the digital date alongside
- Per-episode watched tracking, with "mark watched up to here"
- What's New after every check: movies released and episodes aired since last time
- Menu bar count of unwatched episodes
- Notifications for new episodes and movie releases
- Optional streaming availability (JustWatch data via TMDB)
- Alerts when a saved title arrives on a streaming service you subscribe to
- Ask Claude: chat about what to watch, grounded in your ratings (optional, with your own Anthropic API key)
- Write reviews (movies, or TV by season) and send them to Obsidian as notes
- Markdown digest and CSV export
- A `screenbook` CLI that shares the same database
- An iPhone app: What's New, To Watch, your library, episode checkmarks, and adding titles
- iCloud sync between your Mac and iPhone, including your TMDB key (end-to-end encrypted)

You need your own free TMDB API key. None is included in this repository.

## Setup

Requirements: macOS 14 or later.

1. **Download** [Screenbook.dmg](https://github.com/JonathanGarro/screenbook/releases/latest/download/Screenbook.dmg), open it, and drag Screenbook to Applications. It is signed and notarized, and keeps itself up to date (Settings, Updates). Or build it yourself (step 2).
2. Get a free TMDB API key: create an account at themoviedb.org, then go to Settings, API. Either the v3 "API Key" or the v4 "API Read Access Token" works.

### Building from source

Needs Xcode (the build script uses `/Applications/Xcode.app` automatically if Command Line Tools is the active developer directory).

   ```sh
   git clone https://github.com/JonathanGarro/screenbook.git
   cd screenbook
   ./build_app.sh
   ```
   This produces `/Applications/Screenbook.app` and `build/bin/screenbook` (the CLI).
   If your keychain has an Apple Development signing identity (any free Apple account set up in Xcode has one), the script signs with it, so macOS treats every rebuild as the same app and remembers permissions such as access to a vault in Documents. Without one it signs ad hoc, and macOS may ask for folder access again after each rebuild. Set `SIGN_IDENTITY` to pick a different identity, or `SIGN_IDENTITY=-` for ad hoc.
Then open Screenbook, open Settings (Cmd+,), and paste the key.
   You can also set the key without the app:
   - `build/bin/screenbook config --api-key YOUR_KEY`, or
   - copy `.env.example` to `~/Library/Application Support/Screenbook/.env` and fill it in, or
   - export `TMDB_API_KEY` in your shell (takes priority over the file).
Press Cmd+N to add titles, Cmd+R to check.

The key is never stored in source. The app and CLI read `TMDB_API_KEY` from the environment first, then from the `.env` file in the data folder (written with owner-only permissions).

## Using the app

- **Sidebar**: What's New, To Watch (everything you can watch now: shows with unwatched aired episodes and released movies you have not seen), Library, Reviews, Insights. Adding a title selects it, switching to the Library view it belongs in if needed.
- **What's New**: the list shows what arrived since the last check and a date-by-date **Coming Up** list; the main area is a calendar of the next 30 days with every TV episode (from the season's episode list, not only the next one) and movie release (in theaters or digital). Click an entry to open the title; the calendar button in the toolbar returns. Stopped titles, watched movies, and shows marked all episodes out are left off.
- **Library**: every watchlist title plus everything you have reviewed in Obsidian, one row per movie or show. Filter by **Type** (All, Movies, TV) and **Status** (All, Waiting, Watched, Stopped), and search by title (a search covers every status). What you can watch now has its own **To Watch** item in the sidebar, so Library does not repeat it as a filter; it still appears under All. **Waiting** is shows you are caught up on and movies not out yet, soonest first; **Stopped** is paused titles; Watched holds movies you watched, shows that ended with nothing left, and your whole review history. A title known only from reviews opens a lighter page with its poster, details, your reviews (Edit Review, Open in Obsidian), and **Add to Watchlist**, which adds it back with the reviewed seasons marked watched. History titles are not checked for new releases, so checks stay fast. Notes in your movie and TV folders that are not linked to a TMDB title yet also appear (marked "not linked") so search finds them; open one and choose **Link to TMDB...** to pick the title (search by name, or paste an IMDb link or ID when TMDB spells the title differently), optionally renaming the note, which adds its `watchlist_id`.
- **Add (Cmd+N)**: search TMDB, pick a result, add it. For shows, tick "I'm caught up" to mark every aired episode watched so only future episodes count as new.
- **Check on open**: the app runs a check each time it opens (turn off in Settings, Checking). Details are cached for an hour, so reopening often is cheap.
- **Menu bar count**: a TV icon in the menu bar shows the total number of unwatched aired episodes. Click it for a per-show list (pick one to open it), Check Now, and Open Screenbook. While it is on, closing the window keeps the app running; Cmd+Q quits. Turn it off in Settings, Checking.
- **Notifications**: when a check finds newly aired episodes or a saved movie whose release date has arrived, macOS shows a notification per title (or one summary if there are more than four). Each episode and release is announced once. Clicking it opens the title. While the app is running it also checks every 6 hours, so notifications arrive without opening the window. These are in Settings, Notifications, with a Send Test button. Checks run by the CLI (cron or launchd) do not notify, and they mark episodes and releases as already reported, so pick one: the app's 6 hour check or a scheduled CLI job.
- **Stop Watching**: in a title's toolbar or right-click menu. The title keeps its watched episodes and reviews but leaves Unwatched, Upcoming, What's New, the menu bar count, notifications, and checks, and moves to **Stopped** in the sidebar. **Resume** brings it back; anything that aired meanwhile shows as unwatched without a burst of new-episode alerts. Movies get **Stop Tracking**. **Remove** is still the permanent delete.
- **Check Now (Cmd+R)**: refreshes every title. Shift+Cmd+R bypasses the one hour cache.
- **Detail pane**: dates, status, overview, and for shows an episode list per season. Click the circle to toggle watched. Right click an episode for "Mark Watched Up to Here". The checkmark menu marks a whole season or everything aired.
- **Tools menu**: Write Digest (Cmd+D) writes `outputs/digest.md` and reveals it in Finder. Export CSV writes `outputs/watchlist.csv`. Show Data Folder opens the folder.
- **My streaming services**: in Settings, tick the services you pay for. Each check then looks up your saved movies and shows on them (at most once a day per title), notifies you when one arrives on a service, and lists it under **Now on Your Services** in What's New. A title already on a service when you pick it, or when you first add it, is recorded quietly, so only real arrivals are announced. Watched movies and stopped titles are skipped. Only subscription, free, and ad-supported offers count, not rentals or purchases.
- **Ask Claude**: a chat in the sidebar for deciding what to watch. Each chat starts by giving Claude your ratings, your watchlist, and the streaming services you picked, and Claude can search TMDB, check where a title streams, read one of your reviews when it helps, and add a title to your watchlist after you confirm. It is off until you paste an Anthropic API key in Settings, Claude (or set `ANTHROPIC_API_KEY`). What Claude sees is sent to Anthropic under your key and billed to it, usually a few cents per chat. Chats are saved on this Mac and listed beside the conversation; Claude names each one after its first exchange, right-click one to rename or delete it, and Settings, Claude has Clear Chat History. Reopening a chat continues it with the same profile it started with. It uses Claude Opus 5.5 at medium effort, with prompt caching so follow-ups are cheap.
- **Settings**: the gear at the bottom of the sidebar, or Cmd+,. API key, check on open, menu bar count, notifications and the 6 hour check, region, streaming toggle, rent/buy toggle.

## iPhone app

The iPhone app is a companion to the Mac app: it covers watching, not writing. Reviews, Obsidian, Insights, and the CLI stay on the Mac.

- **What's New**: shows with unwatched episodes, the most recently aired first, and a **Coming Up** list for the next 60 days. The tab badge counts shows with something new. Pull down to check TMDB.
- **To Watch**: the same list as on the Mac, filtered by All, TV, or Movies.
- **Library**: every title, with search and a filter menu for status (To Watch, Waiting, Watched, Stopped) and type.
- **Add** (the search tab): search TMDB and add a title. For a show, pick **Start from the Beginning** or **I'm Caught Up**.
- **Title page**: for a show, pick a season and tap episodes to check them off; touch and hold one for **Mark Watched Up to Here**. The ellipsis menu marks a whole season and toggles **All Episodes Are Out**. Movies get a Watched switch. Every title has Stop Watching and Remove.
- **Settings** (the gear on What's New): your TMDB key, iCloud sync status with **Sync Now**, and **Check TMDB Now**.

The app opens to the first season you have not finished and checks TMDB when it comes to the front if it has been more than three hours. It needs iOS 18 or later. It is not on the App Store or TestFlight yet; see [Building the iPhone app](#building-the-iphone-app) to install it from source.

## iCloud sync

The Mac and iPhone apps sync through the private CloudKit database in your own iCloud account. Nothing goes through a server of ours, and no one else can see your data.

What syncs:

- Your watchlist: which titles you track, when you added them, watched dates for movies, stopped titles, and the all episodes out setting.
- Watched episodes.
- Your TMDB key, in an end-to-end encrypted field, so a new device works without pasting it. Save a different key on any device and it reaches the others.

What does not:

- Reviews and anything Obsidian. They stay on the Mac.
- TMDB details (episodes, posters, overviews, air dates). Each device fetches its own, using the synced key.
- Which episodes and releases were already announced, so each device notifies on its own schedule.

Changes usually arrive within seconds through iCloud push notifications. A device also checks for changes when it comes to the front, and the Mac every five minutes as a fallback. If the same title changes on two devices before they sync, the later change wins; watched episodes merge, but unchecking an episode is not undone by an older check from another device.

Sync is in the Mac app from version 0.1.4. The Mac app's Settings shows sync status and a **Sync Now** button. Without iCloud, or in a build signed without the iCloud entitlement, Screenbook works as before, on that device only.

## Reviews and Obsidian

Write reviews in Screenbook and send them to an Obsidian vault as notes.

- **Movies** are reviewed one to one. Click **Mark Watched** on a movie (the date is editable), then **Write Review**.
- **Shows** are reviewed by season. In a show's episode list, pick the season and click **Review Season**.
- The editor has the note title, a half-star rating, finished date, rewatch, connected to, and a series index for movies. The finished date defaults to the day you marked the movie watched, or the day you checked off the season's last episode.
- **Save Draft** keeps it in Screenbook (Reviews in the sidebar). **Send to Obsidian** writes the note; sending again updates it. If a note with that name already exists, or you edited the sent note in Obsidian, Screenbook asks before replacing it.

Notes look like this:

```
---
type: Film
rating: 4.5
stars: ★★★★½
finished_on: 2025-05-02
connected_to:
film_series_index:
rewatch: false
imdb_id: tt31193180
imdb_link: https://www.imdb.com/title/tt31193180/
imdb_rating: '7.6'
imdb_votes: 288,689
metascore: '84'
rotten_tomatoes: 97%
my_rating_delta: -7
watchlist_id: movie-1233413-0
---
# Sinners

Review text.
```

Each note gets a `watchlist_id` property (`movie-<tmdb id>-0` or `tv-<tmdb id>-<season>`). Screenbook finds notes by that id, so renaming or moving a note in Obsidian does not break **Open in Obsidian**, and **Update in Obsidian** writes into the renamed note (Screenbook adopts the new title). For a note sent before ids existed, use **Locate Note...** in the review editor once; it adds the id to that note.

Season notes use `type: Television`, are titled like `Silo - Season 3` (or just the show name when TMDB marks the show as a Miniseries), link `connected_to: "[[Silo]]"`, and skip the IMDb fields. Colons in titles become " - " in file names.

Setup is in Settings, Obsidian Reviews:

- **Vault**: defaults to the vault Obsidian has open; choose another if needed.
- **Movie folder**, **TV season folder**: relative to the vault (defaults `Film` and `Television`).
- **Show index folder**: if set, a minimal index note (`type: Television`, `# Show`) is created there when a season links to a show that has none.
- **OMDb key** (optional, free at omdbapi.com): fills `imdb_rating`, `imdb_votes`, `metascore`, `rotten_tomatoes`, and `my_rating_delta` (rating x 20 minus the Rotten Tomatoes percentage). Without it those fields are left blank. `imdb_id` and `imdb_link` come from TMDB either way. The key is stored as `OMDB_API_KEY` in the same `.env` file.

### Editing in Obsidian

The note is the master copy. Screenbook syncs on launch, whenever you switch back to it, when you open a review, and from **Sync from Obsidian** (Reviews list, Tools menu, or `screenbook sync-reviews`). If a note changed since Screenbook last wrote it, Screenbook pulls in its title, rating, finished date, rewatch, connected to, series index, and text, so **Update in Obsidian** always starts from your latest version.

- If you also saved unsent edits in Screenbook (Save Draft on a sent review), the review is marked **Changed in both**; open it and choose **Use Obsidian Version** or **Keep Mine**.
- A review whose note was deleted is marked **Note missing**, with **Locate Note...** and **Remove from Screenbook**. Nothing is deleted automatically.
- Renames and moves are followed through `watchlist_id`.

### Consistent properties

Every review note uses the same properties in the same order, matching the template:

- Film: `type, rating, stars, finished_on, connected_to, film_series_index, rewatch, imdb_id, imdb_link, imdb_rating, imdb_votes, metascore, rotten_tomatoes, my_rating_delta`, then any other properties, then `watchlist_id` last.
- TV: the same through `rewatch`, then any other properties, then `watchlist_id`.

Screenbook writes notes this way when it sends or updates a review, links a note (import, Link to TMDB, Locate Note), or fills ratings; linking a movie also fills its IMDb and Rotten Tomatoes values right away. A note's type comes from its `watchlist_id` when linked, else from its folder. `screenbook tidy` (a dry run unless `--apply`, which backs up the folders first) brings every existing note in line: it adds missing properties (blank, or `rewatch: false`) and reorders, without changing any value.

### Series index

`film_series_index` is a film's place in its franchise by release order (Dune - Part Two is 2). New movie drafts get it pre-filled from the film's TMDB collection; change it in the editor for franchises you number your own way.

`screenbook audit-series` (a dry run unless `--apply`) adds a blank `film_series_index` to every movie and TV note missing it, right after `connected_to`, and fills blank indexes from TMDB collections. Values you already set are never changed; ones that differ from TMDB's order are listed. `--skip "Note A,Note B"` leaves chosen notes blank, and `--keys-only` only adds the missing property. TMDB collections sometimes include spin-offs or unofficial entries, so review the list before applying.

### Insights

**Insights** in the sidebar plots every rated movie review: your rating across (0 to 5 stars, scaled to 0 to 100) against an outside score up (Rotten Tomatoes critics score or IMDb user rating, toggled at the top). On the dashed 45 degree line you agree; below it you liked the movie more, above it less. The plot is always square.

- Dots are colored by your three most common primary genres, with the rest in gray. A scatter plot only keeps three colors distinguishable for color-blind readers, so the **Genre** menu highlights any single genre instead of adding colors.
- Hover a dot for the title, both scores, and the gap; click it to open the review. The list beside the chart shows the same movies, sortable by biggest difference, liked more, liked less, or title.
- Scores come from your notes' `imdb_rating` and `rotten_tomatoes` properties (see Fill IMDb and Rotten Tomatoes), genres from TMDB. TV seasons are not plotted because their notes have no outside scores.

### Importing existing reviews

Already have review notes in Obsidian? **Tools > Import Reviews from Obsidian...** (or `screenbook import-reviews`) links them:

1. Screenbook reads every note in the movie and TV folders and matches each one to TMDB. Movies with an `imdb_id` match exactly; the rest match by title. TV notes named `Show - Season N` map to that season; a note named just for the show counts as season 1. A year in the name, like `A Christmas Carol (2019)`, is used as a hint.
2. You review the matches before anything is written. **Matched** notes are included. **Check** means a best guess (several titles share the name, the closest match has a different title, no release date, or the show does not have that season); tick it if it is right, or click **Fix** to search for the right title. **No match** notes are skipped.
   **Fix** can also rename the note: tick **Rename the note in Obsidian** and edit the suggested name (TMDB's title). On import the file is renamed, its `# heading` follows, and every `[[Old Name]]` link in the vault is updated, keeping folder prefixes, `#headings`, and `|aliases`, like a rename inside Obsidian. If another note shares the old name, links are left alone because they are ambiguous, and Screenbook will not rename onto a name that already exists. Notes whose links change are included in the backup.
3. On import, a zip backup of both folders goes to `outputs/`, each included note gets a `watchlist_id` property (nothing else changes), and each becomes a sent review in Screenbook with its rating, date, and text. Shows that are still running can be added to the watchlist, marked watched through the last season you reviewed. Movies are not added.

The CLI version is a dry run unless you pass `--apply` (`--include-check` also imports the best guesses).

When you later update an imported review from Screenbook, properties Screenbook would leave blank (such as `imdb_rating` without an OMDb key) and properties it does not manage keep their existing values.

### IMDb, Metascore, and Rotten Tomatoes

With an OMDb key, movie notes get `imdb_id`, `imdb_link`, `imdb_rating`, `imdb_votes`, `metascore`, `rotten_tomatoes`, and `my_rating_delta`, in the same format as a typical OMDb-to-frontmatter script. Films are looked up by IMDb id (from TMDB), not by title, so similarly named films do not get mixed up. The review editor shows the scores next to your stars, with the delta updating as you change the rating.

**Tools > Fill IMDb and Rotten Tomatoes...** (or `screenbook fill-ratings`, a dry run unless `--apply`) fills those properties in every linked movie note where they are blank or missing, without touching anything else. Tick "refresh" (or `--refresh`) to also update scores that are already filled. TV notes are left alone. OMDb results are cached for 30 days.

The first send may trigger a macOS prompt to let Screenbook access the folder your vault is in.

## CLI commands

The CLI shares the same database and settings as the app.

```
screenbook add <search term> [--caught-up] [--pick N]
screenbook remove <tmdb_id> [--movie | --tv]
screenbook stop <tmdb_id> [--movie | --tv]
screenbook resume <tmdb_id> [--movie | --tv]
screenbook list
screenbook check [--force]
screenbook watch <tmdb_id> <season> <episode> [--unwatch]
screenbook watch <tmdb_id> --all-up-to <season> <episode>
screenbook available <tmdb_id> on|off
screenbook import-reviews [--apply] [--include-check] [--add-shows on|off]
screenbook fill-ratings [--apply] [--refresh]
screenbook sync-reviews
screenbook tidy [--apply]
screenbook link "<note name>" <imdb link or id>
screenbook audit-series [--apply] [--keys-only] [--skip "Note A,Note B"]
screenbook digest [--force]
screenbook export
screenbook config [--region XX] [--streaming on|off] [--rent-buy on|off] [--check-on-open on|off] [--menu-bar on|off] [--notify on|off] [--notify-movies on|off] [--periodic on|off] [--api-key KEY]
screenbook paths
```

- `add` prints the top 10 matches and asks for a number. `--pick N` skips the prompt.
- `remove` needs `--movie` or `--tv` only when a movie and a show share the same TMDB id (TMDB ids are unique per type, not globally).
- `check` prints movies released since the last check, shows with new aired episodes since the last check, and shows that still have an unwatched backlog.
- `digest` writes `outputs/digest.md` and prints it. If a check already ran today it reuses that result, so running `check` then `digest` does not lose the "new" items. `--force` runs a fresh check.
- `--data-dir PATH` (before the command) or `SCREENBOOK_DATA_DIR` points at a different data folder, handy for testing.

## Where data lives

Everything is in `~/Library/Application Support/Screenbook/`:

```
watchlist.db        sqlite database
config.json         region and streaming settings
.env                TMDB_API_KEY (if saved from the app or cli, or synced from iCloud)
outputs/
  digest.md         written by digest
  watchlist.csv     written by export
```

The iPhone app keeps the same files (without reviews) in its own Application Support folder.

A GUI app has no meaningful working directory, so the relative paths from the original spec (`watchlist.db`, `outputs/digest.md`) are relative to this folder instead.

### Tables

Open `watchlist.db` in any SQLite client.

- `titles`: `tmdb_id`, `media_type` ('movie' or 'tv'), `title`, `year`, `region_release_date`, `added_on`, plus `digital_release_date`, `status`, `overview`, `poster_path`, `last_aired_season/episode/date`, `next_air_season/episode/date`, `seen_season/episode` (the latest aired episode at the previous check), `release_flagged` (movie release already reported), `last_refreshed`, `watched_on` (movies), `all_available` (tv streaming drop override), `stopped_on` (stopped watching; progress kept). Primary key is (`tmdb_id`, `media_type`).
- `watched_episodes`: `tmdb_id`, `season`, `episode`, `watched_on`.
- `seasons`: `tmdb_id`, `season_number`, `episode_count`, `air_date`, `name`. Copied from the series details call; used to work out which episodes have aired.
- `reviews`: `tmdb_id`, `media_type`, `season` (0 for movies), `note_title`, `rating`, `finished_on`, `body`, `rewatch`, `connected_to`, `series_index`, `exported_at`, `export_path`, `updated_at`, `local_edits` (saved in Screenbook since the last send).
- `api_cache`: `cache_key` (path plus sorted query, never the key), `body` (raw JSON), `fetched_at`.
- `streaming_seen`: `tmdb_id`, `media_type`, `provider_id`. Which of your services each title was on at the last look, so arrivals are announced once (provider 0 marks a title that has been looked up). Kept per device, not synced.
- `chats`: saved Ask Claude conversations: `id`, `title`, `renamed` (named by you, so the automatic name never replaces it), `system` (the profile prompt the chat started with), `messages` (the API conversation as JSON), `items` (the bubbles on screen), `created_at`, `updated_at`. Kept per device, not synced.
- `meta`: `last_check` timestamp and `last_report` (the last check result as JSON), plus sync bookkeeping: `sync_state` (the CloudKit engine's saved state), `sync_env` (Development or Production), `sync_seeded`, and `sync_key` (a hash of the last synced TMDB key, never the key).
- `sync_outbox`: local changes waiting to go to iCloud, one row per record (`record_name`, `is_delete`, `changed_at`). Database triggers fill it whenever a title or watched episode changes.
- `sync_system_fields`: CloudKit's bookkeeping for each record, so saves update the existing record instead of conflicting.

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

TMDB stores many release dates per movie: one list per country, each entry typed 1 Premiere, 2 Theatrical (limited), 3 Theatrical, 4 Digital, 5 Physical, 6 TV. Screenbook picks one date deliberately:

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

### Streaming drops

TMDB records original broadcast dates only. A show that aired weekly in its home country but landed all at once on a streaming service (for example a BBC show on Netflix US) will look like it is still airing. Tick **All episodes are out** in the show's episode list (or `screenbook available <tmdb_id> on`) and every episode TMDB lists counts as released: none are greyed out, they count toward unwatched, and "Mark Season Watched" includes them. Turning it on does not trigger new-episode notifications for the episodes already listed.

### Caching and rate limits

| Response | Reused for |
| --- | --- |
| Search | 1 day |
| Movie and show details | 1 hour (so repeated checks do not refetch; `--force` bypasses) |
| Season episode lists | 6 hours |
| Watch providers | 30 days |

TMDB says its limit is "somewhere in the 40 requests per second range" and asks clients to respect HTTP 429. Screenbook waits 0.25 seconds between calls and retries a 429 up to 4 times, honoring `Retry-After` when present and otherwise backing off 1, 2, 4, 8 seconds. If the network is down, a stale cached response is used when available.

## Streaming availability (optional)

Off by default. Turn it on in Settings or with `screenbook config --streaming on`. When on:

- The detail pane shows subscription ("flatrate") services for your region. Rent and buy are hidden unless "Include rent and buy" is on.
- The digest adds a Streaming column for newly released movies and shows with unwatched episodes.
- Results are cached for 30 days.

This data comes from JustWatch through TMDB. JustWatch attribution is shown in the app and digest whenever streaming is on.

## Scheduling a daily check

Optional. The app already checks whenever it opens and every 6 hours while it runs. A scheduled job is only useful if you want the digest refreshed while the app is closed. The app has no scheduler built in, so use cron or launchd with the CLI.

First copy the CLI out of `~/Documents`. macOS privacy protection can block background jobs from running binaries stored in Documents.

```sh
mkdir -p ~/.local/bin
cp build/bin/screenbook ~/.local/bin/screenbook
```

Background jobs do not see your shell's environment variables, so save the key to the data folder (`screenbook config --api-key ...` or the app's Settings).

### cron (macOS or Linux)

`crontab -e`, then add a line to check every day at 8:00 and append the output to a log in `outputs/`:

```
0 8 * * * "$HOME/.local/bin/screenbook" check >> "$HOME/Library/Application Support/Screenbook/outputs/check.log" 2>&1
```

Swap `check` for `digest` to also rewrite `outputs/digest.md` each morning.

### launchd (macOS)

launchd is the native option, and it catches up on a missed run if the Mac was asleep at 8:00. Create `~/Library/LaunchAgents/io.github.jonathangarro.screenbook.plist`, replacing `YOU` with your user name (launchd does not expand `~`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>io.github.jonathangarro.screenbook</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOU/.local/bin/screenbook</string>
        <string>digest</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>8</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardOutPath</key><string>/Users/YOU/Library/Application Support/Screenbook/outputs/check.log</string>
    <key>StandardErrorPath</key><string>/Users/YOU/Library/Application Support/Screenbook/outputs/check.log</string>
</dict>
</plist>
```

Load it, and run it once to test:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.jonathangarro.screenbook.plist
launchctl kickstart gui/$(id -u)/io.github.jonathangarro.screenbook
```

To remove it: `launchctl bootout gui/$(id -u)/io.github.jonathangarro.screenbook`.

## Development

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if Command Line Tools is selected
swift build
swift test
swift run WatchlistApp      # run the app without bundling
swift run screenbook list    # run the cli
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
  Reviews.swift               review drafts, obsidian note format and export, omdb
  Import.swift                importing existing obsidian review notes
  Sync.swift                  pulling obsidian edits back into reviews
  Series.swift                series index from tmdb collections
  Insights.swift              data for the ratings comparison chart
  Tidy.swift                  standard note properties and order
  SyncStore.swift             sync outbox, triggers, and applying changes from other devices
  CloudSync.swift             cloudkit sync engine: sending, fetching, conflicts, the tmdb key
  Streaming.swift             alerts when saved titles arrive on your streaming services
  Assistant.swift             ask claude: streamed replies, fallback handling, the taste profile prompt
Sources/WatchlistApp/         swiftui mac app
Sources/screenbook/main.swift cli
iOS/                          swiftui iphone app, using WatchlistCore
Xcode/project.yml             xcodegen project for the iphone app and icloud provisioning
Tests/WatchlistCoreTests/     swift testing suite with a mocked http transport (no network)
```

### iCloud signing

CloudKit needs a provisioning profile, which a plain `swift build` cannot make. Xcode creates it once from `Xcode/project.yml` (needs [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a paid Apple Developer team; change the team ID, bundle ID, and `CloudSync.containerID` to your own):

```sh
cd Xcode && xcodegen generate
xcodebuild -project ScreenbookApps.xcodeproj -scheme ScreenbookProvisioning \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

`build_app.sh` then finds the profile, embeds it, and signs the app with the iCloud entitlements. It prints whether sync is on. Builds signed for development use CloudKit's Development environment and releases use Production, which keep separate data. Before the first release with sync, deploy the schema in the CloudKit Console (Deploy Schema Changes), or released apps cannot save.

### Building the iPhone app

Plug in your iPhone, turn on Developer Mode (Settings, Privacy & Security), and find its ID with `xcrun devicectl list devices`. Then:

```sh
cd Xcode && xcodegen generate
xcodebuild -project ScreenbookApps.xcodeproj -scheme ScreenbookPhone -configuration Debug \
    -destination 'id=<device id>' -derivedDataPath ../build/phone \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <device id> ../build/phone/Build/Products/Debug-iphoneos/Screenbook.app
```

Building for the device registers it with your team the first time. You can also open `ScreenbookApps.xcodeproj` in Xcode and run the ScreenbookPhone scheme. A debug build syncs with the Development environment, so pair it with a Mac app from `./build_app.sh`, not a release.

### Releasing

`./build_app.sh --release` signs with your Developer ID certificate and the hardened runtime, notarizes and staples the app and then a dmg, and writes `dist/appcast.xml`, the Sparkle update feed, signed with the key in your keychain. Publish with `gh release create v<version> dist/Screenbook.dmg dist/appcast.xml`, using the version in `VERSION`. See the top of `build_app.sh` for the one-time notary and Sparkle key setup.

### Differences from the original Python spec

- Swift and SwiftUI instead of Python. Pandas is not used. Table formatting for `list`, the digest, and CSV export is done in `Digest.swift`.
- argparse is replaced by a small hand-written parser with the same commands.
- Data lives in Application Support rather than next to the script, because a Mac app has no meaningful working directory.
- pytest is replaced by Swift Testing (`swift test`).
- The titles table has extra columns (see above) so `list` and `check` work without calling the API.

## Attribution

This product uses the TMDB API but is not endorsed or certified by TMDB. Movie and TV data, images, and search come from [The Movie Database (TMDB)](https://www.themoviedb.org).

Streaming availability data is provided by [JustWatch](https://www.justwatch.com) through TMDB's watch providers endpoint.

## License

MIT. See [LICENSE](LICENSE). TMDB and JustWatch data are subject to their own terms; bring your own TMDB API key.

## Future ideas (out of scope for v1)

- A web UI
- Import from other watchlist apps (Trakt, TV Time, Letterboxd exports)
- Multi-user support
- The iPhone app on TestFlight, and new-episode notifications on iPhone
