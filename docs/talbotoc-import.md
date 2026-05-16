# TalbotOC Importer

The TalbotOC importer lives at `script/import_scripts/talbotoc.rb` and reads the
SQLite archive produced by the TalbotOC crawler.

This is the current agent-facing TalbotOC import runbook. Historical migration
stage notes and dated validation samples are archived in
`docs/archive/talbotoc-next-stage-migration-2026-05.md`.

## Container command context

On production-style hosts (for example `pedroserve02-a1`), run operational
commands from `/var/discourse` and execute Rails or rake commands in the `app`
container as the `discourse` OS user with `RAILS_ENV=production`.

Using `docker exec app ...` as root without setting `RAILS_ENV=production` can
produce misleading authentication/database errors (for example
`ActiveRecord::NoDatabaseError` against `discourse`) or development-gem load
errors (`debug/prelude`).

Recommended wrapper:

```bash
docker exec app bash -lc 'su - discourse -c '\''cd /var/www/discourse && RAILS_ENV=production <command>'\'''
```

## Local validation

Use Ruby 3.4.7 and Bundler 2.6.4, matching `Gemfile.lock`. The importer depends
on SQLite support, so install the optional generic import bundle group:

```bash
bundle config set --local with generic_import
bundle install
```

Run focused checks with:

```bash
bin/lint docs/talbotoc-import.md script/import_scripts/talbotoc.rb spec/script/import_scripts/talbotoc_spec.rb
bin/rspec spec/script/import_scripts/talbotoc_spec.rb
```

## Environment variables

- `TALBOTOC_DB`: required path to `talbotoc_archive.db`.
- `TALBOTOC_MEDIA_DIR`: optional path to downloaded archive media.
- `TALBOTOC_LIMIT`: optional limit for subset validation runs.
- `TALBOTOC_TOPIC_OFFSET`: optional topic offset for subset validation runs.
- `TALBOTOC_DRY_RUN`: when present, prints source counts without importing.
- `TALBOTOC_FAST_INCREMENTAL`: when present, imports topics/posts/placeholders
  but skips the broad media refresh for already imported posts.
- `TALBOTOC_SKIP_COMPLETE_TOPICS`: optional recovery speed-up for interrupted
  runs. When present, topics whose posts are already fully imported are skipped
  instead of being rechecked for media rewrites.
- `TALBOTOC_LOCK_FILE`: optional import lock path. Defaults to
  `/tmp/talbotoc-import.lock`; on the server use a shared path such as
  `/shared/import/talbotoc/talbotoc-import.lock`.

Example dry run:

```bash
TALBOTOC_DB="/path/to/talbotoc_archive.db" TALBOTOC_DRY_RUN=1 ruby script/import_scripts/talbotoc.rb
```

Example subset import:

```bash
TALBOTOC_DB="/path/to/talbotoc_archive.db" \
TALBOTOC_MEDIA_DIR="/path/to/archive_media" \
TALBOTOC_LIMIT=25 \
ruby script/import_scripts/talbotoc.rb
```

Example fast incremental subset:

```bash
TALBOTOC_DB="/path/to/talbotoc_archive.db" \
TALBOTOC_MEDIA_DIR="/path/to/archive_media" \
TALBOTOC_TOPIC_OFFSET=100 \
TALBOTOC_LIMIT=1000 \
TALBOTOC_FAST_INCREMENTAL=1 \
ruby script/import_scripts/talbotoc.rb
```

After a real import, inspect the available maintenance tasks in the target
Discourse environment with `bundle exec rake --tasks | grep -Ei
"import|consistency|rebake"`. On the current TalbotOC deployment there is no
`import:ensure_consistency` task, so use the available Discourse tasks and
validation queries instead.

## Validation flow

1. Run a dry run against the current crawler database and record the source
   counts.
2. Run a small local subset import with `TALBOTOC_LIMIT`.
3. Rerun the same subset and confirm imported counts do not increase.
4. Confirm placeholder behavior with the focused spec before relying on crawler
   data that may still be incomplete.
5. Run with `TALBOTOC_MEDIA_DIR` when downloaded media is available. Missing
   files are left as source URLs so later reruns can rewrite them after the
   crawler catches up.

## Incremental imports

Use `script/import_scripts/talbotoc_incremental.sh` for repeated imports while
the crawler is still running. It snapshots the crawler SQLite database before
running the importer, optionally syncs media, uses the TalbotOC import lock, and
prints source/imported counts.

Example from inside the Discourse app container:

```bash
docker exec app bash -lc 'su - discourse -c '\''cd /var/www/discourse && \
TALBOTOC_SOURCE_DB="/shared/import/talbotoc/live/talbotoc_archive.db" \
TALBOTOC_SOURCE_MEDIA_DIR="/shared/import/talbotoc/live/archive_media" \
TALBOTOC_WORK_DIR="/shared/import/talbotoc/incremental" \
RAILS_ENV=production \
bash script/import_scripts/talbotoc_incremental.sh'\'''
```

For recovery after an interrupted run, `TALBOTOC_SKIP_COMPLETE_TOPICS=1` can be
added temporarily. Do not use that flag for normal incremental imports because
it skips media refreshes for already imported posts.

For high-volume catch-up while the crawler is still running, use
`TALBOTOC_FAST_INCREMENTAL=1`. Fast mode still embeds downloaded media when a
post is newly created or when a placeholder is replaced, but it does not revisit
already imported posts to rewrite media that arrived later. Run normal
incremental imports without fast mode periodically, after large crawl
milestones, and before final cutover to refresh older posts whose media became
available after their first import.

A cron or systemd timer can call the wrapper every 30 minutes during testing
after a few manual incremental runs have completed cleanly. The automation
should run inside the app container and should not run full rebakes after every
incremental pass.

For dated sample results, see the archived TalbotOC notes.

## Rebuild survival

The canonical TalbotOC importer source is this Discourse repo commit, not the
live container filesystem. A Discourse container rebuild can replace
`/var/www/discourse/script/import_scripts`, so after any rebuild:

1. Start the rebuilt `app` container.
2. Recopy `script/import_scripts/talbotoc.rb` and
   `script/import_scripts/talbotoc_incremental.sh` from the committed source or
   persistent server override directory.
3. Run `ruby -c script/import_scripts/talbotoc.rb` and
   `bash -n script/import_scripts/talbotoc_incremental.sh` inside the container.
4. Run a dry-run incremental wrapper check before any full import.

Recommended server-side override location:

```text
/opt/appdata/discourse/importer-overrides/
```

Keep that directory in sync with the committed repo files until the TalbotOC
importer is no longer needed or is deployed through a maintained Discourse fork.

## Production checklist

Before running against the tailnet Discourse instance:

1. Take a Discourse backup on `pedroserve02-A1`.
2. Copy the latest `talbotoc_archive.db` and media directory to the server import
   path.
3. Run the dry-run summary inside the Discourse app environment.
4. Run the importer with all categories public for the first pass.
5. Inspect available maintenance tasks and run the supported consistency/rebake
   tasks for that deployment.
6. Rebake changed imported posts. On the current deployment, `rake posts:rebake`
   is available.
7. Validate category hierarchy, staged users, sample topics, post counts,
   permalinks, placeholders, and media rewrites.
8. Leave the crawler running independently and rerun the importer as more
   TalbotOC posts and media arrive.

## Content reconciliation

After the main import is current enough for operational review:

1. Run one normal non-fast incremental import against a frozen source snapshot.
2. Revisit posts whose media became available after their first import and
   rewrite their raw content to use Discourse uploads.
3. Preserve or map meaningful Tapatalk/default smileys.
4. Rewrite quotes to native Discourse quote syntax where the quoted post can be
   resolved; otherwise use username-only attribution.
5. Investigate imported `Open` / `Closed` short-post artifacts and ensure they
   do not remain as visible normal posts or affect recency, counts, or bumping.
6. Rebake changed posts and sample older, newer, media-heavy, and
   placeholder-replaced topics.
7. Keep unresolved media in a backlog with source URLs and topic IDs so it can
   be retried later without rediscovery.

## Duplicate placeholder cleanup

If interrupted imports create duplicate placeholder-only topics, keep the lowest
Discourse topic ID for each `talbotoc:topic:<id>` import ID and permanently
delete only the extra placeholder topics whose first post has the duplicated
`talbotoc:topic:<id>:placeholder` import ID and no real `talbotoc:post:%` post.
Use `PostDestroyer` with `force_destroy: true`; do not remove rows with raw SQL.
