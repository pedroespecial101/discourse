# frozen_string_literal: true

require_relative "base"
require "csv"
require "digest/sha1"
require "fileutils"
require "open-uri"
require "set"

class TalbotocSmileyRepair
  REPORT_DIR = ENV["TALBOTOC_REPORT_DIR"]
  DRY_RUN = ENV.fetch("DRY_RUN", "1") != "0"
  TOPIC_IDS =
    ENV["TALBOTOC_REPAIR_TOPIC_IDS"].to_s.split(",").filter_map { |id| id.strip.presence&.to_i }
  TOPIC_SLUGS =
    ENV["TALBOTOC_REPAIR_TOPIC_SLUGS"].to_s.split(",").filter_map { |slug| slug.strip.presence }
  LIMIT = ENV["TALBOTOC_REPAIR_LIMIT"]&.to_i
  IMPORT_PREFIX = "talbotoc"
  EMOJI_GROUP = "talbotoc"
  EMOJI_NAME_PREFIX = "talbotoc_smiley"
  SMILEY_URL_PATTERN = %r{https?://groups\.tapatalk-cdn\.com/smilies/[^\s\]\[)"'<]+}i

  def initialize(
    report_dir: REPORT_DIR,
    dry_run: DRY_RUN,
    topic_ids: TOPIC_IDS,
    topic_slugs: TOPIC_SLUGS,
    limit: LIMIT
  )
    @report_dir =
      report_dir.presence ||
        "/shared/import/talbotoc/reports/smiley-repair-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
    @dry_run = dry_run
    @topic_ids = topic_ids
    @topic_slugs = topic_slugs
    @limit = limit
    @summary = Hash.new(0)
    @smiley_map = {}
    @download_dir = File.join(@report_dir, "downloads")

    FileUtils.mkdir_p(@report_dir)
    FileUtils.mkdir_p(@download_dir) if !@dry_run
    @processed_post_ids = processed_post_ids
  end

  def run
    puts "TalbotOC smiley repair"
    puts "Report dir: #{@report_dir}"
    puts "Mode: #{@dry_run ? "DRY_RUN" : "LIVE"}"
    puts "Topic filter: #{@topic_ids.join(",")}" if @topic_ids.present?
    puts "Slug filter: #{@topic_slugs.join(",")}" if @topic_slugs.present?

    build_smiley_map

    open_reports do |reports|
      posts_to_scan.find_each.with_index do |post, index|
        next if @processed_post_ids.include?(post.id)

        repair_post(post, reports)
        if (index + 1) % 500 == 0
          puts "processed=#{index + 1} changed=#{@summary[:changed]} errors=#{@summary[:errors]}"
        end
      end
    end

    File.write(File.join(@report_dir, "summary.json"), JSON.pretty_generate(@summary))
    puts @summary.inspect
  end

  private

  def posts_to_scan
    scope =
      Post
        .joins("INNER JOIN post_custom_fields pcf_import_id ON pcf_import_id.post_id = posts.id")
        .where("pcf_import_id.name = ?", "import_id")
        .where("pcf_import_id.value LIKE ?", "#{IMPORT_PREFIX}:post:%")
        .where(post_type: Post.types[:regular])
        .where("posts.raw LIKE ?", "%groups.tapatalk-cdn.com/smilies%")
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

  def build_smiley_map
    observed = Hash.new { |hash, key| hash[key] = { count: 0, source_url: nil } }

    posts_to_scan.find_each do |post|
      post.raw.to_s.scan(SMILEY_URL_PATTERN).each do |url|
        filename = smiley_filename(url)
        next if filename.blank?

        observed[filename][:count] += 1
        observed[filename][:source_url] ||= url
      end
    end

    write_smiley_map(observed, existing_smiley_map)
  end

  def existing_smiley_map
    path = File.join(@report_dir, "smiley_map.csv")
    return {} if !File.exist?(path)

    CSV
      .read(path, headers: true)
      .each_with_object({}) do |row, map|
        filename = row["filename"].presence
        next if filename.blank?

        map[filename] = {
          emoji_name: row["emoji_name"],
          status: row["download_status"],
          custom_emoji_id: row["custom_emoji_id"],
          upload_id: row["upload_id"],
          message: row["message"],
        }
      end
  end

  def write_smiley_map(observed, existing_map)
    path = File.join(@report_dir, "smiley_map.csv")
    CSV.open(path, "w") do |csv|
      csv << %w[
        filename
        source_url
        emoji_name
        usage_count
        download_status
        custom_emoji_id
        upload_id
        message
      ]

      observed.sort_by { |filename, data| [-data[:count], filename] }.each do |filename, data|
        existing = existing_map[filename]
        emoji_name = existing&.dig(:emoji_name) || emoji_name_for(filename)
        status, custom_emoji, message =
          if reusable_existing_mapping?(existing)
            existing_custom_emoji(existing, emoji_name)
          else
            register_custom_emoji(emoji_name, filename, data[:source_url])
          end
        @smiley_map[filename] = { emoji_name: emoji_name, status: status }
        @summary[:unique_smileys] += 1
        @summary[:registered_smileys] += 1 if status == "registered" || status == "existing"
        @summary[:unregistered_smileys] += 1 if status == "failed"

        csv << [
          filename,
          data[:source_url],
          emoji_name,
          data[:count],
          status,
          custom_emoji&.id,
          custom_emoji&.upload_id,
          message,
        ]
      end
    end
    Emoji.clear_cache if !@dry_run
  end

  def emoji_name_for(filename)
    stem = File.basename(filename.to_s, ".*").sub(/-smiley\z/i, "")
    suffix = stem.gsub(/[^a-z0-9]+/i, "_").gsub(/\A_+|_+\z/, "").downcase
    suffix = Digest::SHA1.hexdigest(filename.to_s)[0, 10] if suffix.blank?
    "#{EMOJI_NAME_PREFIX}_#{suffix}".truncate(60, omission: "")
  end

  def reusable_existing_mapping?(existing)
    return false if existing.blank? || existing[:status] == "failed"
    return false if existing[:status] == "dry_run" && !@dry_run

    true
  end

  def existing_custom_emoji(existing, emoji_name)
    custom_emoji =
      CustomEmoji.find_by(id: existing[:custom_emoji_id]) || CustomEmoji.find_by(name: emoji_name)
    return ["existing", custom_emoji, existing[:message]] if custom_emoji.present?
    return ["dry_run", nil, existing[:message]] if @dry_run

    ["failed", nil, "Existing custom emoji mapping no longer exists"]
  end

  def register_custom_emoji(emoji_name, filename, source_url)
    existing = CustomEmoji.find_by(name: emoji_name)
    return ["existing", existing, nil] if existing.present?
    return ["dry_run", nil, nil] if @dry_run

    download_path = File.join(@download_dir, filename)
    File.open(download_path, "wb") do |file|
      URI.open(source_url, read_timeout: 30) { |remote| IO.copy_stream(remote, file) }
    end

    upload =
      File.open(download_path, "rb") do |file|
        UploadCreator
          .new(file, filename, type: "custom_emoji")
          .create_for(Discourse::SYSTEM_USER_ID)
      end

    return ["failed", nil, upload.errors.full_messages.join(", ")] if !upload.persisted?

    custom_emoji =
      CustomEmoji.create!(
        name: emoji_name,
        upload: upload,
        group: EMOJI_GROUP,
        user_id: Discourse::SYSTEM_USER_ID,
      )
    ["registered", custom_emoji, nil]
  rescue => e
    ["failed", nil, "#{e.class}: #{e.message}"]
  end

  def open_reports
    changed_path = File.join(@report_dir, "changed_posts.csv")
    exceptions_path = File.join(@report_dir, "exceptions.csv")
    audit_path = File.join(@report_dir, "audit_posts.csv")

    CSV.open(changed_path, File.exist?(changed_path) ? "a" : "w") do |changed|
      CSV.open(exceptions_path, File.exist?(exceptions_path) ? "a" : "w") do |exceptions|
        CSV.open(audit_path, File.exist?(audit_path) ? "a" : "w") do |audit|
          changed << %w[post_id topic_id post_number source_post_id url replacements] if File.empty?(changed_path)
          exceptions << %w[post_id topic_id source_post_id kind message] if File.empty?(exceptions_path)
          if File.empty?(audit_path)
            audit << %w[
              post_id
              topic_id
              post_number
              source_post_id
              smiley_urls
              known_smileys
              unresolved_smileys
              replacements
            ]
          end
          yield({ changed: changed, exceptions: exceptions, audit: audit })
        end
      end
    end
  end

  def processed_post_ids
    path = File.join(@report_dir, "audit_posts.csv")
    return Set.new if !File.exist?(path)

    CSV.read(path, headers: true).filter_map { |row| row["post_id"]&.to_i }.to_set
  end

  def repair_post(post, reports)
    source_post_id = source_post_id(post)
    original_raw = post.raw.to_s
    stats = Hash.new(0)
    repaired_raw = repair_smileys(original_raw, stats)
    unresolved_filenames = Array(stats[:unresolved_filenames]).sort

    reports[:audit] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      stats[:smiley_urls],
      stats[:known_smileys],
      stats[:unresolved_smileys],
      stats[:replacements],
    ]
    if unresolved_filenames.present?
      reports[:exceptions] << [
        post.id,
        post.topic_id,
        source_post_id,
        "unresolved_smileys",
        unresolved_filenames.join("|"),
      ]
    end

    @summary[:posts_scanned] += 1
    @summary[:posts_with_smileys] += 1 if stats[:smiley_urls].positive?
    @summary[:smiley_urls] += stats[:smiley_urls]
    @summary[:known_smileys] += stats[:known_smileys]
    @summary[:unresolved_smileys] += stats[:unresolved_smileys]
    @summary[:replacements] += stats[:replacements]

    return if repaired_raw == original_raw

    @summary[:changed] += 1
    reports[:changed] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      post.full_url,
      stats[:replacements],
    ]

    return if @dry_run

    PostRevisor.new(post).revise!(
      post.user,
      { raw: repaired_raw },
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

  def repair_smileys(raw, stats)
    stats[:unresolved_filenames] = Set.new if !stats[:unresolved_filenames].is_a?(Set)

    raw.gsub(%r{\[img\]\s*(#{SMILEY_URL_PATTERN})\s*\[/img\]}i) do
      replacement_for(Regexp.last_match[1], stats) || Regexp.last_match[0]
    end.gsub(%r{!\[[^\]]*\]\((#{SMILEY_URL_PATTERN})\)}i) do
      replacement_for(Regexp.last_match[1], stats) || Regexp.last_match[0]
    end.gsub(%r{<img\b[^>]*\bsrc=(["'])(#{SMILEY_URL_PATTERN})\1[^>]*>}i) do
      replacement_for(Regexp.last_match[2], stats) || Regexp.last_match[0]
    end.gsub(SMILEY_URL_PATTERN) do |url|
      replacement_for(url, stats) || url
    end
  end

  def replacement_for(url, stats)
    stats[:smiley_urls] += 1
    filename = smiley_filename(url)
    mapping = @smiley_map[filename]
    if mapping.present? && mapping[:status] != "failed"
      stats[:known_smileys] += 1
      stats[:replacements] += 1
      ":#{mapping[:emoji_name]}:"
    else
      stats[:unresolved_smileys] += 1
      stats[:unresolved_filenames] << filename
      nil
    end
  end

  def smiley_filename(url)
    File.basename(URI.parse(url).path)
  rescue URI::InvalidURIError
    File.basename(url.to_s.split(/[?\s\]\[)"'<]/).first.to_s)
  end

  def source_post_id(post)
    post.custom_fields["import_id"].to_s.split(":").last
  end
end

TalbotocSmileyRepair.new.run if $PROGRAM_NAME == __FILE__
