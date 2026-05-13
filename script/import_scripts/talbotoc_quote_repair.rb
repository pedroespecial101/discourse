# frozen_string_literal: true

require "csv"
require "fileutils"

class TalbotocQuoteRepair
  REPORT_DIR = ENV["TALBOTOC_REPORT_DIR"]
  DRY_RUN = ENV.fetch("DRY_RUN", "1") != "0"
  TOPIC_IDS =
    ENV["TALBOTOC_REPAIR_TOPIC_IDS"].to_s.split(",").filter_map { |id| id.strip.presence&.to_i }
  TOPIC_SLUGS =
    ENV["TALBOTOC_REPAIR_TOPIC_SLUGS"].to_s.split(",").filter_map { |slug| slug.strip.presence }
  LIMIT = ENV["TALBOTOC_REPAIR_LIMIT"]&.to_i
  IMPORT_PREFIX = "talbotoc"
  QUOTE_TAG_PATTERN = /\[quote(?<attrs>[^\]]*?\buid\s*=\s*[^\]]*?)\]/i
  REAL_EXTERNAL_MEDIA_PATTERN =
    %r{https?://(?:attachment\.tapatalk-cdn\.com|(?:(?!groups\.tapatalk-cdn\.com/smilies)[^/\s]+\.tapatalk-cdn\.com)|[^/\s]*postimg[^/\s]*|[^/\s]*photobucket[^/\s]*|[^/\s]*servimg[^/\s]*|[^/\s]*ibb\.co)[^\s\])"<]+}i
  SMILEY_PATTERN = %r{https?://groups\.tapatalk-cdn\.com/smilies/[^\s\])"<]+}i

  def initialize(
    report_dir: REPORT_DIR,
    dry_run: DRY_RUN,
    topic_ids: TOPIC_IDS,
    topic_slugs: TOPIC_SLUGS,
    limit: LIMIT
  )
    @report_dir =
      report_dir.presence ||
        "/shared/import/talbotoc/reports/quote-repair-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
    @dry_run = dry_run
    @topic_ids = topic_ids
    @topic_slugs = topic_slugs
    @limit = limit
    @summary = Hash.new(0)
    @post_mapping_cache = {}

    FileUtils.mkdir_p(@report_dir)
    @processed_post_ids = processed_post_ids
  end

  def run
    puts "TalbotOC quote repair"
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
  end

  private

  def posts_to_scan
    scope =
      Post
        .joins("INNER JOIN post_custom_fields pcf_import_id ON pcf_import_id.post_id = posts.id")
        .where("pcf_import_id.name = ?", "import_id")
        .where("pcf_import_id.value LIKE ?", "#{IMPORT_PREFIX}:post:%")
        .where(post_type: Post.types[:regular])
        .where("posts.raw LIKE ? OR posts.raw LIKE ?", "%[quote uid=%", "%[quote=\"%")
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
    audit_path = File.join(@report_dir, "audit_posts.csv")

    CSV.open(changed_path, File.exist?(changed_path) ? "a" : "w") do |changed|
      CSV.open(exceptions_path, File.exist?(exceptions_path) ? "a" : "w") do |exceptions|
        CSV.open(audit_path, File.exist?(audit_path) ? "a" : "w") do |audit|
          if File.empty?(changed_path)
            changed << %w[
              post_id
              topic_id
              post_number
              source_post_id
              url
              quote_tags
              resolved_quote_links
              fallback_quotes
            ]
          end
          if File.empty?(exceptions_path)
            exceptions << %w[post_id topic_id source_post_id kind message]
          end
          if File.empty?(audit_path)
            audit << %w[
              post_id
              topic_id
              post_number
              source_post_id
              quote_tags
              resolved_quote_links
              fallback_quotes
              real_external_urls
              smiley_urls
              exact_open_closed
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
    repaired_raw = repair_quotes(original_raw, stats)

    reports[:audit] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      stats[:quote_tags],
      stats[:resolved_quote_links],
      stats[:fallback_quotes],
      original_raw.scan(REAL_EXTERNAL_MEDIA_PATTERN).uniq.size,
      original_raw.scan(SMILEY_PATTERN).uniq.size,
      %w[Open Closed].include?(original_raw.strip),
    ]

    @summary[:quote_tags] += stats[:quote_tags]
    @summary[:resolved_quote_links] += stats[:resolved_quote_links]
    @summary[:fallback_quotes] += stats[:fallback_quotes]
    @summary[:real_external_posts] += 1 if original_raw.match?(REAL_EXTERNAL_MEDIA_PATTERN)
    @summary[:smiley_posts] += 1 if original_raw.match?(SMILEY_PATTERN)
    @summary[:exact_open_closed_posts] += 1 if %w[Open Closed].include?(original_raw.strip)

    return if repaired_raw == original_raw

    @summary[:changed] += 1
    reports[:changed] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      post.full_url,
      stats[:quote_tags],
      stats[:resolved_quote_links],
      stats[:fallback_quotes],
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

  def repair_quotes(raw, stats)
    raw
      .gsub(QUOTE_TAG_PATTERN) do |tag|
        attrs = parse_attributes(Regexp.last_match[:attrs])
        stats[:quote_tags] += 1

        quote_attribution(attrs, stats) || tag
      end
      .then { |repaired| normalize_quote_newlines(repaired, stats) }
  end

  def quote_attribution(attrs, stats)
    quoted_post = mapped_post(attrs["post"] || attrs["post_id"])
    name = quote_name(attrs, quoted_post)
    return if name.blank?

    if quoted_post
      stats[:resolved_quote_links] += 1
      %([quote="#{name}, post:#{quoted_post.post_number}, topic:#{quoted_post.topic_id}"]\n)
    else
      stats[:fallback_quotes] += 1
      %([quote="#{name}"]\n)
    end
  end

  def normalize_quote_newlines(raw, stats)
    normalized =
      raw
        .gsub(/(\[quote(?:=[^\]]+)?\])(?!\n)/i, "\\1\n")
        .gsub(%r{(?<!\n)\[/quote\]}i, "\n[/quote]")
        .gsub(%r{(\[/quote\])(?!\n)}i, "\\1\n")

    stats[:quote_newlines_normalized] += 1 if normalized != raw
    normalized
  end

  def parse_attributes(source)
    source
      .to_s
      .scan(/(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|“([^”]*)”|([^\s\]]+))/)
      .each_with_object({}) do |(key, double_quoted, single_quoted, smart_quoted, bare), attrs|
        attrs[key.downcase] = double_quoted || single_quoted || smart_quoted || bare
      end
  end

  def quote_name(attrs, quoted_post)
    name = quoted_post&.user&.username || attrs["name"] || attrs["username"] || attrs["uid"]
    name.to_s.gsub('"', "'").squish.presence
  end

  def mapped_post(source_post_id)
    source_post_id = source_post_id.to_s
    return if source_post_id.blank?

    @post_mapping_cache.fetch(source_post_id) do
      @post_mapping_cache[source_post_id] = PostCustomField.find_by(
        name: "import_id",
        value: "#{IMPORT_PREFIX}:post:#{source_post_id}",
      )&.post
    end
  end

  def source_post_id(post)
    post.custom_fields["import_id"].to_s.split(":").last
  end
end

TalbotocQuoteRepair.new.run
