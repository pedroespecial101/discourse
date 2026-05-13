# frozen_string_literal: true

require "csv"
require "fileutils"
require "pathname"
require "sqlite3"
require "uri"
require_relative "base/uploader"

class TalbotocMediaRepair
  SOURCE_DB = ENV["TALBOTOC_DB"]
  MEDIA_DIR = ENV["TALBOTOC_MEDIA_DIR"]
  REPORT_DIR = ENV["TALBOTOC_REPORT_DIR"]
  DRY_RUN = ENV.fetch("DRY_RUN", "1") != "0"
  TOPIC_IDS =
    ENV["TALBOTOC_REPAIR_TOPIC_IDS"].to_s.split(",").filter_map { |id| id.strip.presence&.to_i }
  TOPIC_SLUGS =
    ENV["TALBOTOC_REPAIR_TOPIC_SLUGS"].to_s.split(",").filter_map { |slug| slug.strip.presence }
  LIMIT = ENV["TALBOTOC_REPAIR_LIMIT"]&.to_i
  IMPORT_PREFIX = "talbotoc"
  REAL_EXTERNAL_MEDIA_PATTERN =
    %r{https?://(?:attachment\.tapatalk-cdn\.com|(?:(?!groups\.tapatalk-cdn\.com/smilies)[^/\s]+\.tapatalk-cdn\.com)|[^/\s]*postimg[^/\s]*|[^/\s]*photobucket[^/\s]*|[^/\s]*servimg[^/\s]*|[^/\s]*ibb\.co)[^\s\])"<]+}i

  def initialize(
    db_path: SOURCE_DB,
    media_dir: MEDIA_DIR,
    report_dir: REPORT_DIR,
    dry_run: DRY_RUN,
    topic_ids: TOPIC_IDS,
    topic_slugs: TOPIC_SLUGS,
    limit: LIMIT
  )
    raise ArgumentError, "Set TALBOTOC_DB" if db_path.blank?
    raise ArgumentError, "TalbotOC database not found: #{db_path}" if !File.exist?(db_path)
    raise ArgumentError, "Set TALBOTOC_MEDIA_DIR" if media_dir.blank?

    @db_path = db_path
    @media_dir = media_dir
    @report_dir =
      report_dir.presence ||
        "/shared/import/talbotoc/reports/media-repair-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
    @dry_run = dry_run
    @topic_ids = topic_ids
    @topic_slugs = topic_slugs
    @limit = limit
    @source_db = SQLite3::Database.new(@db_path)
    @source_db.results_as_hash = true
    @uploader = ImportScripts::Uploader.new
    @upload_markdown_by_path = {}
    @summary = Hash.new(0)

    FileUtils.mkdir_p(@report_dir)
    @processed_post_ids = processed_post_ids
  end

  def run
    puts "TalbotOC media repair"
    puts "DB: #{@db_path}"
    puts "Media dir: #{@media_dir}"
    puts "Report dir: #{@report_dir}"
    puts "Mode: #{@dry_run ? "DRY_RUN" : "LIVE"}"
    puts "Topic filter: #{@topic_ids.join(",")}" if @topic_ids.present?
    puts "Slug filter: #{@topic_slugs.join(",")}" if @topic_slugs.present?

    open_reports do |reports|
      posts_to_scan.each_with_index do |post, index|
        next if @processed_post_ids.include?(post.id)

        repair_post(post, reports)
        if (index + 1) % 500 == 0
          puts "processed=#{index + 1} changed=#{@summary[:changed]} errors=#{@summary[:errors]}"
        end
      end
    end

    File.write(File.join(@report_dir, "summary.json"), JSON.pretty_generate(@summary))
    puts @summary.inspect
  ensure
    @source_db&.close
  end

  private

  def posts_to_scan
    scope =
      Post
        .joins("INNER JOIN post_custom_fields pcf_import_id ON pcf_import_id.post_id = posts.id")
        .where("pcf_import_id.name = ?", "import_id")
        .where("pcf_import_id.value LIKE ?", "#{IMPORT_PREFIX}:post:%")
        .where(post_type: Post.types[:regular])
        .order(:id)

    if @topic_ids.present? || @topic_slugs.present?
      scope = scope.joins(:topic)
      predicates = []
      values = []
      if @topic_ids.present?
        predicates << "posts.topic_id IN (?)"
        values << @topic_ids
      end
      if @topic_slugs.present?
        predicates << "topics.slug IN (?)"
        values << @topic_slugs
      end
      scope = scope.where(predicates.join(" OR "), *values)
    end
    scope = scope.limit(@limit) if @limit.present? && @limit.positive?
    scope
  end

  def open_reports
    changed_path = File.join(@report_dir, "changed_posts.csv")
    exceptions_path = File.join(@report_dir, "exceptions.csv")
    classified_path = File.join(@report_dir, "classified_posts.csv")

    CSV.open(changed_path, File.exist?(changed_path) ? "a" : "w") do |changed|
      CSV.open(exceptions_path, File.exist?(exceptions_path) ? "a" : "w") do |exceptions|
        CSV.open(classified_path, File.exist?(classified_path) ? "a" : "w") do |classified|
          if File.empty?(changed_path)
            changed << %w[post_id topic_id post_number source_post_id url action upload_count]
          end
          if File.empty?(exceptions_path)
            exceptions << %w[post_id topic_id source_post_id kind message]
          end
          if File.empty?(classified_path)
            classified << %w[
              post_id
              topic_id
              post_number
              source_post_id
              bucket
              downloaded_media
              upload_refs
              real_external_urls
              smiley_urls
            ]
          end
          yield({ changed: changed, exceptions: exceptions, classified: classified })
        end
      end
    end
  end

  def processed_post_ids
    path = File.join(@report_dir, "classified_posts.csv")
    return Set.new if !File.exist?(path)

    CSV.read(path, headers: true).filter_map { |row| row["post_id"]&.to_i }.to_set
  end

  def repair_post(post, reports)
    source_post_id = source_post_id(post)
    return if source_post_id.blank?

    media_rows = media_rows_for_post(source_post_id)
    downloaded_rows = dedupe_media_rows(media_rows.select { |row| downloaded_media_row?(row) })
    raw = post.raw.to_s
    original_raw = raw.dup
    real_external_urls = raw.scan(REAL_EXTERNAL_MEDIA_PATTERN).uniq
    smiley_urls = raw.scan(%r{https?://groups\.tapatalk-cdn\.com/smilies/[^\s\])"<]+}i).uniq
    upload_refs = raw.scan(%r{upload://}).size
    actions = []

    raw = unwrap_legacy_img_markdown(raw)
    actions << "unwrap_legacy_img" if raw != original_raw

    downloaded_rows.each do |row|
      raw = replace_inline_media(raw, row, actions, reports, post, source_post_id)
    end

    if downloaded_rows.present? && raw.scan(%r{upload://}).size < downloaded_rows.size
      missing_markdown = missing_media_markdown(raw, downloaded_rows, reports, post, source_post_id)
      if missing_markdown.present?
        raw = "#{raw.rstrip}\n\n#{missing_markdown.join("\n")}\n"
        actions << "append_metadata_media"
      end
    end

    bucket =
      classify_post(
        media_rows: media_rows,
        downloaded_rows: downloaded_rows,
        raw: raw,
        original_raw: original_raw,
        real_external_urls: real_external_urls,
        smiley_urls: smiley_urls,
        upload_refs: upload_refs,
      )

    reports[:classified] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      bucket,
      downloaded_rows.size,
      upload_refs,
      real_external_urls.size,
      smiley_urls.size,
    ]
    @summary[bucket] += 1

    return if raw == original_raw

    @summary[:changed] += 1
    reports[:changed] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      post.full_url,
      actions.uniq.join("|"),
      raw.scan(%r{upload://}).size,
    ]

    return if @dry_run

    PostRevisor.new(post).revise!(
      post.user,
      { raw: raw },
      skip_revision: true,
      bypass_bump: true,
      skip_validations: true,
    )
  rescue => e
    @summary[:errors] += 1
    reports[:exceptions] << [
      post.id,
      post.topic_id,
      source_post_id,
      "error",
      "#{e.class}: #{e.message}",
    ]
  end

  def source_post_id(post)
    post.custom_fields["import_id"].to_s.split(":").last
  end

  def media_rows_for_post(source_post_id)
    @source_db.execute(<<~SQL, source_post_id.to_s)
        SELECT *
        FROM media_assets
        WHERE post_id = ?
        ORDER BY media_id
      SQL
  end

  def downloaded_media_row?(row)
    row["status"] == "downloaded" && row["local_path"].present? &&
      row["asset_type"] != "smiley_or_low_value" && File.exist?(full_media_path(row))
  end

  def dedupe_media_rows(rows)
    rows
      .group_by { |row| dedupe_key(row) }
      .values
      .map { |group| group.max_by { |row| media_quality_score(row) } }
  end

  def dedupe_key(row)
    local_path = row["local_path"].to_s
    return "path:#{local_path}" if local_path.present? && duplicate_local_path?(row)

    basename =
      begin
        File.basename(URI.parse(row["source_url"].to_s).path)
      rescue StandardError
        File.basename(row["source_url"].to_s)
      end
    basename = basename.downcase.sub(/_i(?=\.[a-z0-9]+\z)/, "")
    "source:#{basename.presence || row["source_url"]}"
  end

  def duplicate_local_path?(row)
    row["local_path"].present? &&
      @source_db.get_first_value(
        "SELECT COUNT(*) FROM media_assets WHERE post_id = ? AND local_path = ?",
        row["post_id"].to_s,
        row["local_path"].to_s,
      ).to_i > 1
  end

  def media_quality_score(row)
    basename = File.basename(row["source_url"].to_s)
    score = 0
    score += 10 if basename !~ /_i\.[a-z0-9]+\z/i
    score +=
      begin
        File.size(full_media_path(row))
      rescue StandardError
        0
      end
    score
  end

  def replace_inline_media(raw, row, actions, reports, post, source_post_id)
    return raw if !inline_media_present?(raw, row)

    markdown = upload_markdown(row, reports, post, source_post_id)
    return raw if markdown.blank?

    [row["source_url"], row["normalized_url"], row["final_url"]].compact_blank.uniq.each do |url|
      escaped = Regexp.escape(url)
      raw = raw.gsub(%r{\[img\]#{escaped}\[/img\]}i, markdown)
      raw = raw.gsub(url, markdown)
    end
    actions << "replace_inline_url" if raw.include?(markdown)
    raw
  end

  def missing_media_markdown(raw, rows, reports, post, source_post_id)
    rows.filter_map do |row|
      markdown = upload_markdown(row, reports, post, source_post_id)
      next if markdown.blank?

      upload = @upload_markdown_by_path[full_media_path(row)]&.first
      next if upload && raw.include?("upload://#{upload.base62_sha1}")
      next if raw.include?(markdown)

      markdown
    end
  end

  def upload_markdown(row, reports, post, source_post_id)
    path = full_media_path(row)
    @upload_markdown_by_path[path] ||= begin
      if @dry_run
        [nil, dry_run_markdown(row, path)]
      else
        upload = @uploader.create_upload(Discourse::SYSTEM_USER_ID, path, File.basename(path))
        if upload.blank? || !upload.persisted? || upload.sha1.blank?
          reports[:exceptions] << [post.id, post.topic_id, source_post_id, "upload_failed", path]
          [nil, nil]
        else
          markdown =
            if row["asset_type"] == "image"
              @uploader.embedded_image_html(upload)
            else
              @uploader.attachment_html(upload, File.basename(path))
            end
          [upload, markdown]
        end
      end
    end
    @upload_markdown_by_path[path].last
  end

  def dry_run_markdown(row, path)
    filename = File.basename(path)
    if row["asset_type"] == "image"
      "![#{filename}](dry-run-upload://#{filename})"
    else
      "[#{filename}|attachment](dry-run-upload://#{filename})"
    end
  end

  def inline_media_present?(raw, row)
    [row["source_url"], row["normalized_url"], row["final_url"]].compact_blank.uniq.any? do |url|
      raw.include?(url)
    end
  end

  def full_media_path(row)
    local_path = row["local_path"].to_s
    if local_path.present? && Pathname.new(local_path).absolute?
      local_path
    else
      File.join(@media_dir, File.basename(local_path))
    end
  end

  def unwrap_legacy_img_markdown(raw)
    raw.gsub(%r{\[img\]\s*(!\[[^\]]*\]\(upload://[^)]+\))\s*\[/img\]}i, "\\1")
  end

  def classify_post(
    media_rows:,
    downloaded_rows:,
    raw:,
    original_raw:,
    real_external_urls:,
    smiley_urls:,
    upload_refs:
  )
    return :unavailable_media if media_rows.any? && downloaded_rows.empty?
    return :legacy_img_wrapper if original_raw.match?(%r{\[img\].*upload://.*\[/img\]}im)
    return :legacy_inline_url if real_external_urls.present?
    return :metadata_only_missing if downloaded_rows.present? && upload_refs.zero?
    return :partial_media if downloaded_rows.size > upload_refs && upload_refs.positive?
    return :smiley_only if smiley_urls.present?
    return :converted_ok if upload_refs.positive?

    :no_media
  end
end

TalbotocMediaRepair.new.run
