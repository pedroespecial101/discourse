# TalbotOC Next-Stage Migration Runbook

This runbook covers the migration stage after the crawler has produced enough
media to make the imported forum content meaningful, but before final cutover.
It is written so a smaller agent can execute it with minimal new decisions.

## Current Signal

- Treat the current state as `full import complete` for the purposes of the
  main migration pass.
- Topics and posts are current enough for this stage, with a small trailing
  incremental backlog to be imported later.
- Media is mostly present now; keep the remaining older inaccessible files as a
  tracked backlog unless a sampled topic shows they are high value.
- Do not wait for 100% media completion before continuing with reconciliation
  work.

## Stage Order

1. Freeze the current source snapshot.
2. Run a full non-fast media reconciliation import.
3. Audit and fix post content quality issues.
4. Audit user/profile metadata.
5. Rebake and reindex changed content.
6. Classify the remaining missing media.
7. Resume incrementals later for the trailing topic/post updates.
8. Defer redirects and storage migration until cutover decisions are final.

## 1. Freeze The Source

- Verify the TalbotOC import lock is free before starting.
- Copy or snapshot the current crawler SQLite database and the media directory.
- Record the current source counts for topics, posts, downloaded media, and
  missing media.
- Record the current Discourse counts for imported TalbotOC topics, posts,
  placeholder topics, uploads, and duplicate import IDs.
- Keep the snapshot path and import log path together for later audit.

## 2. Run The Full Reconciliation Import

- Use the normal incremental wrapper, not fast mode.
- Run inside the Discourse app/container environment with the committed TalbotOC
  importer and the expected Ruby/Bundler versions.
- Use the current source DB and media snapshot paths.
- Do not set `TALBOTOC_FAST_INCREMENTAL`.
- Only use `TALBOTOC_SKIP_COMPLETE_TOPICS=1` for recovery from an interrupted
  run.
- Keep missing files as source URLs or placeholders for now rather than blocking
  the import.

Recommended command shape:

```bash
TALBOTOC_SOURCE_DB="/shared/import/talbotoc/live/talbotoc_archive.db" \
TALBOTOC_SOURCE_MEDIA_DIR="/shared/import/talbotoc/live/archive_media" \
TALBOTOC_WORK_DIR="/shared/import/talbotoc/incremental" \
bash script/import_scripts/talbotoc_incremental.sh
```

## 3. Fix Content Quality

- Revisit imported posts that now have downloaded media and rewrite their raw
  content to use Discourse uploads.
- Convert clear sequential image runs into `[grid]...[/grid]` image grids after
  the source image URLs have become uploads.
- Preserve meaningful smileys/emojis, especially default Tapatalk emoticons,
  and map them to Discourse equivalents where possible.
- Fix quotes so imported posts use native Discourse quote syntax when a quoted
  post can be resolved, or username-only attribution when it cannot.
- Investigate the imported `Open` / `Closed` short-post artefacts and ensure
  they do not remain as visible normal posts or affect recency, counts, or
  bumping.
- Keep a manual review list for ambiguous cases instead of transforming them
  blindly.

## 4. Audit Profile Metadata

- Inventory which legacy profile fields are present in the crawler data:
  avatars, profile pictures, about/bio text, signatures, location, website,
  social links, titles, and any other visible profile metadata.
- Map fields into the supported Discourse structures that already exist in the
  importer.
- Separate the rest into a gap report with one of these statuses:
  - `imported`
  - `partially imported`
  - `not available from source`
  - `unsafe to import automatically`
- Treat avatars/profile images as part of the media reconciliation pass and
  validate their upload references separately from ordinary post media.

## 5. Rebuild Derived State

- Rebake changed posts after media rewrites, quote rewrites, smiley changes, and
  image-grid changes.
- Refresh any upload references or optimized images that depend on changed
  uploads.
- Re-run the supported consistency, rebake, and search refresh tasks in the
  target Discourse environment.
- Confirm topic timestamps, bump ordering, reply counts, and placeholder/topic
  state look sensible after the rebake.
- Sample imported topics across older, newer, media-heavy, and placeholder-
  replaced content before considering the pass complete.

## 6. Classify The Remaining Missing Media

- Do not block the stage on the older inaccessible files.
- Classify the unresolved media into:
  - `safe to ignore for now`
  - `worth retrying later`
  - `manual or high value`
- Prefer manual review only for high-value topics or media that materially
  changes the meaning of a post.
- Keep source URLs and topic IDs in the report so the backlog can be retried
  later without rediscovering the same records.

## 7. Resume Incrementals Later

- After the full reconciliation pass is accepted, continue with normal
  incrementals for the newer 4/5 day backlog.
- Use `TALBOTOC_FAST_INCREMENTAL=1` only for frequent catch-up runs while the
  source is still moving.
- Run one final normal non-fast import before any cutover rehearsal so late
  arriving media can be refreshed into older posts.
- Keep the incremental wrapper and the full reconciliation pass separate in the
  run log.

## 8. Defer Cutover Work

- Do not implement 301 redirects yet.
- Do not move to S3/R2/Cloudflare storage yet unless the hosting decision is
  already final.
- When the switch is confirmed, add a separate redirect inventory and storage
  migration plan:
  - old topic URLs
  - old post URLs
  - category URLs
  - user/profile URLs
  - media URLs
- Decide redirect hosting only when the final deployment shape is known.

## Validation Checklist

- The full reconciliation import completes without creating duplicate TalbotOC
  topic or placeholder import IDs.
- Re-importing a small sample does not duplicate posts or topics.
- Posts with downloaded media show Discourse uploads instead of raw source
  links.
- Sequential image runs are converted to image grids only when clearly safe.
- Meaningful Tapatalk/default smileys are preserved or mapped.
- Quotes are either resolved to native quote syntax or fall back to username
  attribution.
- Open/Closed artefacts are removed or neutralized.
- Profile metadata is either imported or listed in the gap report.
- The missing media backlog is classified and reported.
- Rebaked content shows sane bumping, counts, and chronology.

## Assumptions

- The current import state is good enough to start a full reconciliation pass.
- The last small batch of topics/posts will be imported later through normal
  incrementals.
- Most of the work in this stage is operational and content-reconciliation work
  rather than schema or code changes.
- Final cutover, redirects, and object storage are intentionally out of scope
  for this stage.
