# frozen_string_literal: true

require_relative "base"
require "csv"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "set"
require "sqlite3"
require "tempfile"
require "uri"

class TalbotocTapatalkCdnRescue
  SOURCE_DB = ENV["TALBOTOC_DB"].presence || "/shared/import/talbotoc/live/talbotoc_archive.db"
  REPORT_DIR = ENV["TALBOTOC_REPORT_DIR"]
  DRY_RUN = ENV.fetch("DRY_RUN", "1") != "0"
  TOPIC_IDS =
    ENV["TALBOTOC_REPAIR_TOPIC_IDS"].to_s.split(",").filter_map { |id| id.strip.presence&.to_i }
  TOPIC_SLUGS =
    ENV["TALBOTOC_REPAIR_TOPIC_SLUGS"].to_s.split(",").filter_map { |slug| slug.strip.presence }
  LIMIT = ENV["TALBOTOC_REPAIR_LIMIT"]&.to_i
  MAX_ATTEMPTS = ENV.fetch("TALBOTOC_TAPATALK_MAX_ATTEMPTS", "2").to_i
  IMPORT_PREFIX = "talbotoc"
  IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .webp].freeze
  ATTACHMENT_EXTENSIONS = %w[.mp4 .mov .m4v .pdf .doc .docx .xls .xlsx .zip].freeze
  TAPATALK_CDN_URL_PATTERN =
    %r{https?://(?!(?:groups\.)?tapatalk-cdn\.com/smilies)[^/\s\]\[)"'<]*tapatalk-cdn\.com/[^\s\]\[)"'<]+}i

  def initialize(
    db_path: SOURCE_DB,
    report_dir: REPORT_DIR,
    dry_run: DRY_RUN,
    topic_ids: TOPIC_IDS,
    topic_slugs: TOPIC_SLUGS,
    limit: LIMIT,
    max_attempts: MAX_ATTEMPTS
  )
    @db_path = db_path
    @report_dir =
      report_dir.presence ||
        "/shared/import/talbotoc/reports/tapatalk-cdn-rescue-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
    @dry_run = dry_run
    @topic_ids = topic_ids
    @topic_slugs = topic_slugs
    @limit = limit
    @max_attempts = [max_attempts, 1].max
    @uploader = ImportScripts::Uploader.new
    @url_results = {}
    @summary = Hash.new(0)
    @patterns = {
      by_status: Hash.new(0),
      by_year: Hash.new { |hash, key| hash[key] = Hash.new(0) },
      by_host: Hash.new { |hash, key| hash[key] = Hash.new(0) },
      by_extension: Hash.new { |hash, key| hash[key] = Hash.new(0) },
      by_crawler_status: Hash.new { |hash, key| hash[key] = Hash.new(0) },
    }

    FileUtils.mkdir_p(@report_dir)
    @source_db = open_source_db
    @processed_post_ids = processed_post_ids
  end

  def run
    puts "TalbotOC Tapatalk CDN rescue"
    puts "Report dir: #{@report_dir}"
    puts "Mode: #{@dry_run ? "DRY_RUN" : "LIVE"}"
    puts "Topic filter: #{@topic_ids.join(",")}" if @topic_ids.present?
    puts "Slug filter: #{@topic_slugs.join(",")}" if @topic_slugs.present?

    open_reports do |reports|
      posts_to_scan.find_each.with_index do |post, index|
        next if @processed_post_ids.include?(post.id)

        rescue_post(post, reports)
        if (index + 1) % 100 == 0
          puts "processed=#{index + 1} changed=#{@summary[:changed_posts]} rescued_urls=#{@summary[:rescued_urls]} errors=#{@summary[:errors]}"
        end
      end

      write_url_report(reports[:urls])
    end

    File.write(File.join(@report_dir, "summary.json"), JSON.pretty_generate(@summary))
    File.write(File.join(@report_dir, "patterns.json"), JSON.pretty_generate(plain_patterns))
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
        .where(
          "posts.raw ILIKE ? OR posts.cooked ILIKE ?",
          "%tapatalk-cdn.com%",
          "%tapatalk-cdn.com%",
        )
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

  def open_source_db
    return if @db_path.blank? || !File.exist?(@db_path)

    db = SQLite3::Database.new(@db_path)
    db.results_as_hash = true
    db
  rescue => e
    STDERR.puts "Could not open TalbotOC source DB for crawler status lookup: #{e.class}: #{e.message}"
    nil
  end

  def open_reports
    changed_path = File.join(@report_dir, "changed_posts.csv")
    exceptions_path = File.join(@report_dir, "exceptions.csv")
    cooked_only_path = File.join(@report_dir, "cooked_only_refs.csv")
    audit_path = File.join(@report_dir, "audit_posts.csv")
    urls_path = File.join(@report_dir, "urls.csv")

    CSV.open(changed_path, File.exist?(changed_path) ? "a" : "w") do |changed|
      CSV.open(exceptions_path, File.exist?(exceptions_path) ? "a" : "w") do |exceptions|
        CSV.open(cooked_only_path, File.exist?(cooked_only_path) ? "a" : "w") do |cooked_only|
          CSV.open(audit_path, File.exist?(audit_path) ? "a" : "w") do |audit|
            CSV.open(urls_path, "w") do |urls|
              changed << %w[post_id topic_id post_number source_post_id url replacements] if File.empty?(changed_path)
              exceptions << %w[post_id topic_id source_post_id kind url message] if File.empty?(exceptions_path)
              cooked_only << %w[post_id topic_id post_number source_post_id cooked_urls] if File.empty?(cooked_only_path)
              if File.empty?(audit_path)
                audit << %w[
                  post_id
                  topic_id
                  post_number
                  source_post_id
                  raw_urls
                  cooked_urls
                  rescued_urls
                  unavailable_urls
                  failed_urls
                ]
              end
              urls << %w[
                url
                host
                year
                extension
                crawler_status
                status
                attempts
                http_code
                content_type
                bytes
                upload_id
                message
              ]
              yield(
                {
                  changed: changed,
                  exceptions: exceptions,
                  cooked_only: cooked_only,
                  audit: audit,
                  urls: urls,
                }
              )
            end
          end
        end
      end
    end
  end

  def processed_post_ids
    path = File.join(@report_dir, "audit_posts.csv")
    return Set.new if !File.exist?(path)

    CSV.read(path, headers: true).filter_map { |row| row["post_id"]&.to_i }.to_set
  end

  def rescue_post(post, reports)
    source_post_id = source_post_id(post)
    raw = post.raw.to_s
    original_raw = raw.dup
    raw_urls = tapatalk_urls(raw)
    cooked_urls = tapatalk_urls(post.cooked.to_s)
    rescued_urls = Set.new
    unavailable_urls = Set.new
    failed_urls = Set.new

    if raw_urls.blank? && cooked_urls.present?
      reports[:cooked_only] << [post.id, post.topic_id, post.post_number, source_post_id, cooked_urls.join("|")]
      @summary[:cooked_only_posts] += 1
      post.rebake! if !@dry_run
    end

    raw_urls.each do |url|
      result = result_for_url(url)
      case result[:status]
      when "rescued", "dry_run_rescuable"
        replacement = result[:markdown]
        before = raw
        raw = replace_url_in_place(raw, url, replacement)
        rescued_urls << url if raw != before
      when "unavailable_404"
        unavailable_urls << url
      else
        failed_urls << url
      end
    end

    reports[:audit] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      raw_urls.size,
      cooked_urls.size,
      rescued_urls.size,
      unavailable_urls.size,
      failed_urls.size,
    ]

    @summary[:posts_scanned] += 1
    @summary[:posts_with_raw_tapatalk] += 1 if raw_urls.present?
    @summary[:raw_urls] += raw_urls.size
    @summary[:cooked_urls] += cooked_urls.size

    (unavailable_urls | failed_urls).each do |url|
      result = result_for_url(url)
      reports[:exceptions] << [
        post.id,
        post.topic_id,
        source_post_id,
        result[:status],
        url,
        result[:message],
      ]
    end

    return if raw == original_raw

    @summary[:changed_posts] += 1
    reports[:changed] << [
      post.id,
      post.topic_id,
      post.post_number,
      source_post_id,
      post.full_url,
      rescued_urls.size,
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
      nil,
      "#{e.class}: #{e.message}",
    ]
  end

  def result_for_url(url)
    @url_results[url] ||= begin
      result = fetch_url(url)
      record_pattern(url, result)
      @summary[result[:status].to_sym] += 1
      @summary[:rescued_urls] += 1 if result[:status] == "rescued" || result[:status] == "dry_run_rescuable"
      result
    end
  end

  def fetch_url(url)
    parsed_uri = URI.parse(url)
    ext = File.extname(parsed_uri.path).downcase
    return result(url, "unsupported_file", message: "Unsupported file extension: #{ext}") if unsupported_extension?(ext)

    last_response = nil
    last_error = nil
    attempts = 0

    @max_attempts.times do |index|
      attempts = index + 1
      sleep(rand * 0.4) if index.positive?

      download = download_once(parsed_uri)
      last_response = download[:response]
      last_error = download[:error]
      next if retryable_download?(download)

      return classify_download(url, download, attempts)
    end

    classify_download(url, { response: last_response, error: last_error }, attempts)
  rescue URI::InvalidURIError => e
    result(url, "invalid_url", message: e.message)
  end

  def download_once(uri, redirects: 0)
    raise ArgumentError, "Too many redirects" if redirects > 3

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 20) do |http|
      response = http.get(uri.request_uri, "User-Agent" => "Mozilla/5.0 TalbotOC migration")
      if response.is_a?(Net::HTTPRedirection) && response["location"].present?
        redirected = URI.join(uri.to_s, response["location"])
        return download_once(redirected, redirects: redirects + 1)
      end
      { response: response, error: nil }
    end
  rescue => e
    { response: nil, error: e }
  end

  def retryable_download?(download)
    response = download[:response]
    return true if response.blank?
    return true if response.code.to_i >= 500

    false
  end

  def classify_download(url, download, attempts)
    response = download[:response]
    error = download[:error]
    return result(url, "transient_failed", attempts: attempts, message: "#{error.class}: #{error.message}") if error
    return result(url, "transient_failed", attempts: attempts, message: "No response") if response.blank?

    http_code = response.code.to_i
    content_type = response["content-type"].to_s.split(";").first
    bytes = response.body.to_s.bytesize

    return result(url, "unavailable_404", attempts: attempts, http_code: http_code, content_type: content_type, bytes: bytes, message: "HTTP #{http_code}") if http_code == 404 || http_code == 410
    return result(url, "rate_limited", attempts: attempts, http_code: http_code, content_type: content_type, bytes: bytes, message: "HTTP #{http_code}") if http_code == 429 || http_code == 403
    return result(url, "transient_failed", attempts: attempts, http_code: http_code, content_type: content_type, bytes: bytes, message: "HTTP #{http_code}") if http_code >= 500
    return result(url, "invalid_content", attempts: attempts, http_code: http_code, content_type: content_type, bytes: bytes, message: "HTTP #{http_code}") if http_code != 200
    return result(url, "invalid_content", attempts: attempts, http_code: http_code, content_type: content_type, bytes: bytes, message: "HTML/text response") if invalid_content?(content_type, response.body)

    if @dry_run
      return result(
        url,
        "dry_run_rescuable",
        attempts: attempts,
        http_code: http_code,
        content_type: content_type,
        bytes: bytes,
        markdown: dry_run_markdown(url, content_type),
      )
    end

    create_rescue_upload(url, response.body, content_type, attempts, http_code, bytes)
  end

  def create_rescue_upload(url, body, content_type, attempts, http_code, bytes)
    filename = filename_for_url(url, content_type)
    tempfile = Tempfile.new(["talbotoc-tapatalk-cdn", File.extname(filename)])
    tempfile.binmode
    tempfile.write(body)
    tempfile.rewind

    upload = UploadCreator.new(tempfile, filename).create_for(Discourse::SYSTEM_USER_ID)
    if upload.blank? || !upload.persisted? || upload.sha1.blank?
      return result(
        url,
        "transient_failed",
        attempts: attempts,
        http_code: http_code,
        content_type: content_type,
        bytes: bytes,
        message: upload&.errors&.full_messages&.join(", ").presence || "Upload failed",
      )
    end

    markdown =
      if image_content?(content_type, filename)
        @uploader.embedded_image_html(upload)
      else
        @uploader.attachment_html(upload, filename)
      end

    result(
      url,
      "rescued",
      attempts: attempts,
      http_code: http_code,
      content_type: content_type,
      bytes: bytes,
      upload_id: upload.id,
      markdown: markdown,
    )
  ensure
    tempfile&.close!
  end

  def result(
    url,
    status,
    attempts: 0,
    http_code: nil,
    content_type: nil,
    bytes: nil,
    upload_id: nil,
    markdown: nil,
    message: nil
  )
    {
      url: url,
      status: status,
      attempts: attempts,
      http_code: http_code,
      content_type: content_type,
      bytes: bytes,
      upload_id: upload_id,
      markdown: markdown,
      message: message,
      crawler_status: crawler_status(url),
    }
  end

  def replace_url_in_place(raw, url, replacement)
    escaped = Regexp.escape(url)
    raw
      .gsub(%r{\[img\]\s*#{escaped}\s*\[/img\]}i, replacement)
      .gsub(%r{!\[[^\]]*\]\(#{escaped}\)}i, replacement)
      .gsub(%r{<img\b[^>]*\bsrc=(["'])#{escaped}\1[^>]*>}i, replacement)
      .gsub(url, replacement)
  end

  def tapatalk_urls(text)
    text.to_s.scan(TAPATALK_CDN_URL_PATTERN).uniq
  end

  def invalid_content?(content_type, body)
    return true if content_type.start_with?("text/html", "text/plain")

    body.to_s.lstrip.start_with?("<!DOCTYPE html", "<html")
  end

  def unsupported_extension?(extension)
    extension.present? && !(IMAGE_EXTENSIONS.include?(extension) || ATTACHMENT_EXTENSIONS.include?(extension))
  end

  def image_content?(content_type, filename)
    content_type.to_s.start_with?("image/") || IMAGE_EXTENSIONS.include?(File.extname(filename).downcase)
  end

  def dry_run_markdown(url, content_type)
    filename = filename_for_url(url, content_type)
    if image_content?(content_type, filename)
      "![#{filename}](dry-run-tapatalk-cdn://#{filename})"
    else
      "[#{filename}|attachment](dry-run-tapatalk-cdn://#{filename})"
    end
  end

  def filename_for_url(url, content_type)
    uri = URI.parse(url)
    filename = File.basename(uri.path)
    extension = File.extname(filename)
    if filename.blank? || extension.blank?
      extension = extension_for_content_type(content_type)
      filename = "tapatalk-cdn-#{SecureRandom.hex(8)}#{extension}"
    end
    filename
  rescue URI::InvalidURIError
    "tapatalk-cdn-#{SecureRandom.hex(8)}"
  end

  def extension_for_content_type(content_type)
    case content_type.to_s
    when "image/jpeg" then ".jpg"
    when "image/png" then ".png"
    when "image/gif" then ".gif"
    when "image/webp" then ".webp"
    when "video/mp4" then ".mp4"
    else ".bin"
    end
  end

  def crawler_status(url)
    return "unknown" if @source_db.blank?

    @source_db.get_first_value(
      "SELECT status FROM media_assets WHERE source_url = ? OR normalized_url = ? LIMIT 1",
      url,
      url,
    ).presence || "missing"
  rescue
    "unknown"
  end

  def record_pattern(url, result)
    uri = URI.parse(url)
    year = uri.path[%r{\A/(\d{4})\d{4}/}, 1] || "unknown"
    extension = File.extname(uri.path).downcase.presence || "none"
    host = uri.host || "unknown"
    status = result[:status]
    crawler = result[:crawler_status].presence || "unknown"

    @patterns[:by_status][status] += 1
    @patterns[:by_year][year][status] += 1
    @patterns[:by_host][host][status] += 1
    @patterns[:by_extension][extension][status] += 1
    @patterns[:by_crawler_status][crawler][status] += 1
  rescue
    @patterns[:by_status][result[:status]] += 1
  end

  def plain_patterns
    JSON.parse(JSON.generate(@patterns))
  end

  def write_url_report(csv)
    @url_results.values.sort_by { |result| result[:url] }.each do |result|
      uri = URI.parse(result[:url])
      csv << [
        result[:url],
        uri.host,
        uri.path[%r{\A/(\d{4})\d{4}/}, 1] || "unknown",
        File.extname(uri.path).downcase,
        result[:crawler_status],
        result[:status],
        result[:attempts],
        result[:http_code],
        result[:content_type],
        result[:bytes],
        result[:upload_id],
        result[:message],
      ]
    rescue URI::InvalidURIError
      csv << [
        result[:url],
        nil,
        nil,
        nil,
        result[:crawler_status],
        result[:status],
        result[:attempts],
        result[:http_code],
        result[:content_type],
        result[:bytes],
        result[:upload_id],
        result[:message],
      ]
    end
  end

  def source_post_id(post)
    post.custom_fields["import_id"].to_s.split(":").last
  end
end

TalbotocTapatalkCdnRescue.new.run if $PROGRAM_NAME == __FILE__
