#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TALBOTOC_SOURCE_DB:-}" ]]; then
  echo "Set TALBOTOC_SOURCE_DB to the crawler SQLite database path" >&2
  exit 1
fi

if [[ ! -f "${TALBOTOC_SOURCE_DB}" ]]; then
  echo "Crawler database not found: ${TALBOTOC_SOURCE_DB}" >&2
  exit 1
fi

WORK_DIR="${TALBOTOC_WORK_DIR:-/shared/import/talbotoc/incremental}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${WORK_DIR}/${RUN_ID}"
SNAPSHOT_DB="${RUN_DIR}/talbotoc_archive_snapshot.db"
MEDIA_SNAPSHOT_DIR="${WORK_DIR}/archive_media"
IMPORT_LOG="${RUN_DIR}/import.log"

mkdir -p "${RUN_DIR}"
cp "${TALBOTOC_SOURCE_DB}" "${SNAPSHOT_DB}"

IMPORT_MEDIA_DIR="${TALBOTOC_MEDIA_DIR:-}"
if [[ -n "${TALBOTOC_SOURCE_MEDIA_DIR:-}" ]]; then
  mkdir -p "${MEDIA_SNAPSHOT_DIR}"
  rsync -a "${TALBOTOC_SOURCE_MEDIA_DIR%/}/" "${MEDIA_SNAPSHOT_DIR}/"
  IMPORT_MEDIA_DIR="${MEDIA_SNAPSHOT_DIR}"
fi

{
  echo "TalbotOC incremental import ${RUN_ID}"
  echo "Snapshot DB: ${SNAPSHOT_DB}"
  [[ -n "${IMPORT_MEDIA_DIR}" ]] && echo "Media dir: ${IMPORT_MEDIA_DIR}"

  bundle exec ruby -rsqlite3 -e '
    db = SQLite3::Database.new(ARGV.fetch(0))
    puts({
      source_topics: db.get_first_value("SELECT COUNT(*) FROM topics"),
      source_posts: db.get_first_value("SELECT COUNT(*) FROM posts"),
      source_topics_with_posts: db.get_first_value("SELECT COUNT(DISTINCT topic_id) FROM posts"),
      source_downloaded_media: db.get_first_value("SELECT COUNT(*) FROM media_assets WHERE status = '\''downloaded'\''")
    }.inspect)
  ' "${SNAPSHOT_DB}"

  import_env=(
    "TALBOTOC_DB=${SNAPSHOT_DB}"
    "TALBOTOC_LOCK_FILE=${TALBOTOC_LOCK_FILE:-/shared/import/talbotoc/talbotoc-import.lock}"
  )
  [[ -n "${IMPORT_MEDIA_DIR}" ]] && import_env+=("TALBOTOC_MEDIA_DIR=${IMPORT_MEDIA_DIR}")
  [[ -n "${TALBOTOC_LIMIT:-}" ]] && import_env+=("TALBOTOC_LIMIT=${TALBOTOC_LIMIT}")
  [[ -n "${TALBOTOC_DRY_RUN:-}" ]] && import_env+=("TALBOTOC_DRY_RUN=${TALBOTOC_DRY_RUN}")
  [[ -n "${TALBOTOC_SKIP_COMPLETE_TOPICS:-}" ]] &&
    import_env+=("TALBOTOC_SKIP_COMPLETE_TOPICS=${TALBOTOC_SKIP_COMPLETE_TOPICS}")

  env "${import_env[@]}" bundle exec ruby script/import_scripts/talbotoc.rb

  bundle exec rails runner '
    duplicate_topic_imports =
      TopicCustomField
        .where(name: "import_id")
        .where("value LIKE ?", "talbotoc:topic:%")
        .group(:value)
        .having("COUNT(*) > 1")
        .count
        .length

    duplicate_placeholder_posts =
      PostCustomField
        .where(name: "import_id")
        .where("value LIKE ?", "talbotoc:topic:%:placeholder")
        .group(:value)
        .having("COUNT(*) > 1")
        .count
        .length

    puts({
      imported_topics: TopicCustomField.where(name: "import_id").where("value LIKE ?", "talbotoc:topic:%").count,
      imported_posts: PostCustomField.where(name: "import_id").where("value LIKE ?", "talbotoc:post:%").count,
      placeholder_topics: TopicCustomField.where(name: "talbotoc_placeholder_topic", value: "t").count,
      duplicate_topic_imports: duplicate_topic_imports,
      duplicate_placeholder_posts: duplicate_placeholder_posts,
      uploads: Upload.count
    }.inspect)
  '
} 2>&1 | tee "${IMPORT_LOG}"

echo "Import log: ${IMPORT_LOG}"
