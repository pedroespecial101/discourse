# frozen_string_literal: true

require "cgi"
require "fileutils"
require "pathname"
require "sqlite3"
require "uri"
require_relative "base"

class ImportScripts::Talbotoc < ImportScripts::Base
  SOURCE_DB_PATH = ENV["TALBOTOC_DB"]
  MEDIA_DIR = ENV["TALBOTOC_MEDIA_DIR"]
  LIMIT = ENV["TALBOTOC_LIMIT"]&.to_i
  TOPIC_OFFSET = ENV["TALBOTOC_TOPIC_OFFSET"].to_i
  DRY_RUN = ENV["TALBOTOC_DRY_RUN"].present?
  SKIP_COMPLETE_TOPICS = ENV["TALBOTOC_SKIP_COMPLETE_TOPICS"].present?
  FAST_INCREMENTAL = ENV["TALBOTOC_FAST_INCREMENTAL"].present?
  LOCK_FILE = ENV["TALBOTOC_LOCK_FILE"].presence || "/tmp/talbotoc-import.lock"

  IMPORT_PREFIX = "talbotoc"
  PLACEHOLDER_FIELD = "talbotoc_placeholder_topic"
  SOURCE_URL_FIELD = "talbotoc_source_url"

  def initialize(
    db_path: SOURCE_DB_PATH,
    media_dir: MEDIA_DIR,
    limit: LIMIT,
    topic_offset: TOPIC_OFFSET,
    dry_run: DRY_RUN,
    skip_complete_topics: SKIP_COMPLETE_TOPICS,
    fast_incremental: FAST_INCREMENTAL,
    lock_file: LOCK_FILE
  )
    raise ArgumentError, "Set TALBOTOC_DB to the crawler SQLite database path" if db_path.blank?
    raise ArgumentError, "TalbotOC database not found: #{db_path}" if !File.exist?(db_path)

    super()

    @db_path = db_path
    @media_dir = media_dir
    @limit = limit
    @topic_offset = topic_offset.to_i
    @dry_run = dry_run
    @skip_complete_topics = skip_complete_topics
    @fast_incremental = fast_incremental
    @lock_file = lock_file
    @source_db = SQLite3::Database.new(@db_path)
    @source_db.results_as_hash = true
    @upload_markdown_by_media_id = {}
    @user_id_by_source_author_id = {}
    @skip_updates = true if @dry_run
  end

  def preload_i18n
    I18n.backend.store_translations(:en, test: "Test") if !I18n.exists?(:test, :en)
    super
  end

  def execute
    puts "", "Importing TalbotOC archive from #{@db_path}"

    if @dry_run
      print_dry_run_summary
      return
    end

    with_import_lock do
      SiteSetting.max_category_nesting = 3 if SiteSetting.max_category_nesting < 3

      import_categories
      import_users
      import_topics_and_posts
      import_permalinks
    end

    puts "", "Done"
  ensure
    @source_db&.close
  end

  def with_import_lock
    FileUtils.mkdir_p(File.dirname(@lock_file))

    File.open(@lock_file, File::RDWR | File::CREAT, 0o644) do |lock|
      if !lock.flock(File::LOCK_EX | File::LOCK_NB)
        raise "Another TalbotOC import is already running; lock file: #{@lock_file}"
      end

      lock.rewind
      lock.truncate(0)
      lock.write("#{Process.pid}\n")
      lock.flush

      yield
    ensure
      lock&.flock(File::LOCK_UN)
    end
  end

  def import_categories
    puts "", "Importing TalbotOC categories"

    rows = sorted_category_rows

    create_categories(rows) do |row|
      parent_category_id =
        if row["parent_id"].present? && row["parent_id"] != "0"
          category_id_from_imported_category_id(category_import_id(row["parent_id"]))
        end

      {
        id: category_import_id(row["forum_id"]),
        name: row["forum_name"],
        parent_category_id: parent_category_id,
        description: category_description(row),
        position: row["forum_id"].to_i,
        post_create_action: ->(category) { persist_category_metadata(category, row) },
      }
    end
  end

  def import_users
    puts "", "Importing TalbotOC staged users"

    rows = limited_rows(<<~SQL)
      SELECT author_id, author_name, MIN(first_seen_at) AS first_post_time
      FROM (
        SELECT author_id, author_name, post_time AS first_seen_at
        FROM posts
        WHERE author_id IS NOT NULL
          AND author_id <> ''
          AND author_name IS NOT NULL
          AND author_name <> ''
        UNION ALL
        SELECT first_post_author_id AS author_id,
               first_post_author_name AS author_name,
               post_time AS first_seen_at
        FROM topics
        WHERE first_post_author_id IS NOT NULL
          AND first_post_author_id <> ''
          AND first_post_author_name IS NOT NULL
          AND first_post_author_name <> ''
      )
      GROUP BY author_id, author_name
      ORDER BY CAST(author_id AS INTEGER), author_name
    SQL

    create_users(rows) do |row|
      import_id = user_import_id(row["author_id"])

      {
        id: import_id,
        username: username_for(row["author_name"], row["author_id"]),
        name: row["author_name"],
        email: "talbotoc-user-#{row["author_id"]}@email.invalid",
        created_at: parse_time(row["first_post_time"]) || Time.zone.now,
        staged: true,
        active: false,
        trust_level: TrustLevel[0],
        custom_fields: {
          "talbotoc_author_id" => row["author_id"],
          "talbotoc_author_name" => row["author_name"],
        },
      }
    end
  end

  def import_topics_and_posts
    puts "", "Importing TalbotOC topics and posts"

    topic_rows.each do |topic|
      posts = posts_for_topic(topic["topic_id"])

      if posts.empty?
        create_placeholder_topic(topic)
      else
        import_topic_posts(topic, posts)
      end
    end
  end

  def import_topic_posts(topic, posts)
    first_post = posts.first
    topic_id = existing_topic_id(topic["topic_id"])
    first_post_id = post_import_id(first_post["post_id"])

    if @skip_complete_topics && topic_id.present? && !placeholder_topic?(topic_id) &&
         topic_posts_already_imported?(posts)
      return
    end

    if topic_id.present? && placeholder_topic?(topic_id) && !post_already_imported?(first_post_id)
      replace_placeholder_topic(topic_id, topic, first_post)
    end

    topic_id = existing_topic_id(topic["topic_id"])

    if topic_id.blank? && !post_already_imported?(first_post_id)
      create_posts([first_post]) { |post| topic_post_params(topic, post) }
      topic_id = existing_topic_id(topic["topic_id"])
    end

    import_reply_posts(topic_id, posts.drop(1)) if topic_id.present?

    refresh_imported_post_media(posts) if !@fast_incremental
    refresh_topic_metadata(topic)
  end

  def import_reply_posts(topic_id, posts)
    create_posts(posts) do |post|
      next if post_already_imported?(post_import_id(post["post_id"]))

      reply_post_params(topic_id, post)
    end
  end

  def topic_posts_already_imported?(posts)
    posts.all? { |post| post_already_imported?(post_import_id(post["post_id"])) }
  end

  def create_placeholder_topic(topic)
    return if existing_topic_id(topic["topic_id"]).present?
    return if imported_post_id_exists?(placeholder_post_import_id(topic["topic_id"]))

    create_posts([topic]) do |row|
      {
        id: placeholder_post_import_id(row["topic_id"]),
        user_id: topic_user_id(row),
        title: topic_title(row),
        category: category_id_from_imported_category_id(category_import_id(row["forum_id"])),
        raw: placeholder_raw(row),
        created_at: parse_time(row["post_time"]) || Time.zone.now,
        closed: true,
        custom_fields: {
          SOURCE_URL_FIELD => row["canonical_url"],
        },
        post_create_action: ->(post) { mark_placeholder_topic(post.topic, row) },
      }
    end
  end

  def replace_placeholder_topic(topic_id, topic, post)
    discourse_post = Topic.find(topic_id).first_post
    user = post_user(post)
    raw = post_raw(post)

    PostRevisor.new(discourse_post).revise!(
      user,
      { raw: raw },
      skip_revision: true,
      bypass_bump: true,
      skip_validations: true,
    )

    discourse_post.update_columns(
      user_id: user.id,
      created_at: parse_time(post["post_time"]) || discourse_post.created_at,
    )
    discourse_post.custom_fields["import_id"] = post_import_id(post["post_id"])
    discourse_post.custom_fields[SOURCE_URL_FIELD] = post["source_url"]
    discourse_post.custom_fields["talbotoc_position"] = post["position"].to_s
    discourse_post.save_custom_fields

    topic_record = discourse_post.topic
    topic_record.custom_fields[PLACEHOLDER_FIELD] = false
    topic_record.save_custom_fields
    topic_record.update!(
      title: topic_title(topic),
      category_id: category_id_from_imported_category_id(category_import_id(topic["forum_id"])),
    )
    topic_record.update_status("closed", topic_closed?(topic), Discourse.system_user)

    add_post(post_import_id(post["post_id"]), discourse_post)
    add_topic(discourse_post)
  end

  def import_permalinks
    puts "", "Importing TalbotOC permalinks"

    topic_rows.each do |topic|
      topic_id = existing_topic_id(topic["topic_id"])
      next if topic_id.blank? || topic["canonical_url"].blank?

      create_permalink(topic["canonical_url"], topic_id: topic_id)
      create_permalink(URI(topic["canonical_url"]).request_uri, topic_id: topic_id)
    rescue URI::InvalidURIError
      next
    end
  end

  def print_dry_run_summary
    puts "Dry run only. No Discourse records will be changed."
    puts "Forums: #{source_count("forums")}"
    puts "Topics: #{source_count("topics")}"
    puts "Completed topics: #{source_count("topics", "posts_complete = 1")}"
    puts "Posts: #{source_count("posts")}"
    puts "Downloaded media: #{source_count("media_assets", "status = 'downloaded'")}"
  end

  def topic_rows
    query = +"SELECT * FROM topics ORDER BY CAST(topic_id AS INTEGER)"
    query << " LIMIT #{@limit.to_i}" if @limit
    query << " OFFSET #{@topic_offset}" if @topic_offset.positive?
    @source_db.execute(query)
  end

  def posts_for_topic(topic_id)
    @source_db.execute(
      "SELECT * FROM posts WHERE topic_id = ? ORDER BY position, CAST(post_id AS INTEGER)",
      topic_id.to_s,
    )
  end

  def topic_post_params(topic, post)
    {
      id: post_import_id(post["post_id"]),
      user_id: post_user(post).id,
      title: topic_title(topic),
      category: category_id_from_imported_category_id(category_import_id(topic["forum_id"])),
      raw: post_raw(post),
      created_at: parse_time(post["post_time"]) || Time.zone.now,
      closed: topic_closed?(topic),
      custom_fields: {
        SOURCE_URL_FIELD => post["source_url"],
        "talbotoc_position" => post["position"].to_s,
      },
      post_create_action: ->(created_post) { persist_topic_metadata(created_post.topic, topic) },
    }
  end

  def reply_post_params(topic_id, post)
    {
      id: post_import_id(post["post_id"]),
      topic_id: topic_id,
      user_id: post_user(post).id,
      raw: post_raw(post),
      created_at: parse_time(post["post_time"]) || Time.zone.now,
      custom_fields: {
        SOURCE_URL_FIELD => post["source_url"],
        "talbotoc_position" => post["position"].to_s,
      },
    }
  end

  def refresh_imported_post_media(posts)
    return if @media_dir.blank?

    posts.each do |source_post|
      discourse_post_id = post_id_from_imported_post_id(post_import_id(source_post["post_id"]))
      discourse_post = Post.find_by(id: discourse_post_id)
      next if discourse_post.blank?

      updated_raw = rewrite_downloaded_media(discourse_post.raw, source_post["post_id"])
      next if updated_raw == discourse_post.raw

      PostRevisor.new(discourse_post).revise!(
        discourse_post.user,
        { raw: updated_raw },
        skip_revision: true,
        bypass_bump: true,
        skip_validations: true,
      )
    end
  end

  def post_user(post)
    User.find(imported_or_system_user_id(post["author_id"]))
  end

  def topic_user_id(topic)
    imported_or_system_user_id(topic["first_post_author_id"])
  end

  def imported_or_system_user_id(source_author_id)
    @user_id_by_source_author_id.fetch(source_author_id.to_s) do
      user_id = user_id_from_imported_user_id(user_import_id(source_author_id))
      @user_id_by_source_author_id[source_author_id.to_s] = if user_id.present? &&
           User.exists?(id: user_id)
        user_id
      else
        Discourse::SYSTEM_USER_ID
      end
    end
  end

  def topic_title(topic)
    title =
      clean_text(topic["topic_title"]).presence || "Untitled TalbotOC topic #{topic["topic_id"]}"
    title = title.truncate(SiteSetting.max_topic_title_length, omission: "")

    normalize_topic_title(title, topic["topic_id"])
  end

  def normalize_topic_title(title, topic_id)
    return title if title_emoji_count(title) <= SiteSetting.max_emojis_in_title

    title_without_emoji =
      PrettyText.escape_emoji(title).to_s.gsub(Emoji::EMOJI_CODE_REGEXP, "").squish.presence

    (title_without_emoji || "Untitled TalbotOC topic #{topic_id}").truncate(
      SiteSetting.max_topic_title_length,
      omission: "",
    )
  end

  def title_emoji_count(title)
    PrettyText
      .unescape_emoji(Emoji.unicode_unescape(CGI.escapeHTML(title)))
      .to_s
      .scan(/<img.+?class\s*=\s*'(emoji|emoji emoji-custom)'/)
      .size
  end

  def topic_closed?(topic)
    topic["is_closed"].to_i == 1
  end

  def placeholder_raw(topic)
    lines = []
    lines << clean_text(topic["short_content"]).presence
    lines << ""
    lines << <<~TEXT.squish
      Archive import pending: the crawler has found this TalbotOC topic, but the full post
      content has not been fetched yet. This post will be replaced automatically on a later
      import run.
    TEXT
    lines << ""
    lines << "Original topic: #{topic["canonical_url"]}" if topic["canonical_url"].present?
    lines.compact.join("\n")
  end

  def post_raw(post)
    raw =
      clean_text(post["post_content"]).presence || clean_text(post["body_text"]).presence ||
        "(empty post)"
    rewrite_downloaded_media(raw, post["post_id"])
  end

  def rewrite_downloaded_media(raw, post_id)
    return raw if @media_dir.blank?

    media_rows_for_post(post_id).reduce(raw) do |text, media|
      markdown = upload_markdown(media)
      if markdown.present?
        text.gsub(media["source_url"], markdown).gsub(media["normalized_url"], markdown)
      else
        text
      end
    end
  end

  def upload_markdown(media)
    @upload_markdown_by_media_id[media["media_id"]] ||= begin
      local_path = media["local_path"]
      full_path =
        if local_path.present? && Pathname.new(local_path).absolute?
          local_path
        else
          File.join(@media_dir, File.basename(local_path.to_s))
        end
      if local_path.blank? || !File.exist?(full_path)
        nil
      else
        upload = create_upload(Discourse::SYSTEM_USER_ID, full_path, File.basename(full_path))

        if upload.blank? || !upload.persisted? || upload.sha1.blank?
          STDERR.puts(
            "Failed to create usable upload for TalbotOC media #{media["media_id"]}: " \
              "#{full_path} #{upload&.errors&.full_messages&.join(", ")}",
          )
          nil
        elsif media["asset_type"] == "image"
          @uploader.embedded_image_html(upload)
        else
          @uploader.attachment_html(upload, File.basename(full_path))
        end
      end
    end
  end

  def media_rows_for_post(post_id)
    @source_db.execute(<<~SQL, post_id.to_s)
        SELECT *
        FROM media_assets
        WHERE post_id = ?
          AND status = 'downloaded'
          AND local_path IS NOT NULL
      SQL
  end

  def existing_topic_id(source_topic_id)
    post_id = imported_post_id(placeholder_post_import_id(source_topic_id))
    post_id ||= imported_post_id(first_post_import_id(source_topic_id))
    post_id ? Post.find_by(id: post_id)&.topic_id : nil
  end

  def imported_post_id(import_id)
    return if import_id.blank?

    post_id_from_imported_post_id(import_id) || live_post_id_from_imported_post_id(import_id)
  end

  def imported_post_id_exists?(import_id)
    imported_post_id(import_id).present?
  end

  def live_post_id_from_imported_post_id(import_id)
    PostCustomField
      .joins(:post)
      .where(name: "import_id", value: import_id.to_s)
      .where(posts: { deleted_at: nil })
      .order(:post_id)
      .pick(:post_id)
  end

  def first_post_import_id(source_topic_id)
    @source_db
      .get_first_value(<<~SQL, source_topic_id.to_s)
        SELECT post_id
        FROM posts
        WHERE topic_id = ?
        ORDER BY position, CAST(post_id AS INTEGER)
        LIMIT 1
      SQL
      &.then { |post_id| post_import_id(post_id) }
  end

  def placeholder_topic?(topic_id)
    TopicCustomField.exists?(topic_id: topic_id, name: PLACEHOLDER_FIELD, value: "t")
  end

  def mark_placeholder_topic(topic, row)
    persist_topic_metadata(topic, row)
    topic.custom_fields[PLACEHOLDER_FIELD] = true
    topic.save_custom_fields
    topic.update_status("closed", true, Discourse.system_user)
  end

  def persist_topic_metadata(topic, row)
    topic.custom_fields["import_id"] = topic_import_id(row["topic_id"])
    topic.custom_fields[SOURCE_URL_FIELD] = row["canonical_url"]
    topic.custom_fields["talbotoc_expected_posts"] = row["total_post_num"].to_s
    topic.custom_fields["talbotoc_fetched_posts"] = row["posts_fetched_count"].to_s
    topic.save_custom_fields
  end

  def refresh_topic_metadata(topic)
    topic_id = existing_topic_id(topic["topic_id"])
    return if topic_id.blank?

    discourse_topic = Topic.find(topic_id)
    persist_topic_metadata(discourse_topic, topic)
    discourse_topic.update_status("closed", topic_closed?(topic), Discourse.system_user)
  end

  def persist_category_metadata(category, row)
    category.custom_fields[
      SOURCE_URL_FIELD
    ] = "https://talbotoc.com/viewforum.php?f=#{row["forum_id"]}"
    category.custom_fields["talbotoc_forum_path"] = row["path"]
    category.custom_fields["talbotoc_access_mode"] = row["access_mode"]
    category.save_custom_fields
  end

  def category_description(row)
    description =
      "Imported from TalbotOC forum section: #{row["path"].presence || row["forum_name"]}"
    description << "\n\nOriginal section: https://talbotoc.com/viewforum.php?f=#{row["forum_id"]}"
    description
  end

  def create_permalink(url, **target)
    normalized_url = url.to_s.sub(%r{\Ahttps?://talbotoc\.com/?}, "")
    normalized_url = normalized_url.delete_prefix("/")
    return if normalized_url.blank?

    Permalink.find_or_create_by!(url: normalized_url) do |permalink|
      target.each { |key, value| permalink.public_send("#{key}=", value) }
    end
  end

  def username_for(name, id)
    base = UserNameSuggester.suggest(clean_text(name).presence || "talbotoc_user_#{id}")
    "#{base}_#{id}".truncate(User.username_length.end, omission: "")
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value)
  rescue ArgumentError
    nil
  end

  def clean_text(value)
    CGI.unescapeHTML(value.to_s).delete("\u0000").strip
  end

  def limited_rows(sql)
    query = @limit ? "#{sql} LIMIT #{@limit.to_i}" : sql
    @source_db.execute(query)
  end

  def sorted_category_rows
    rows = limited_rows("SELECT * FROM forums ORDER BY CAST(forum_id AS INTEGER)")
    rows_by_id = rows.index_by { |row| row["forum_id"].to_s }
    sorted = []
    visited = Set.new

    visit =
      lambda do |row|
        return if row.blank? || visited.include?(row["forum_id"].to_s)

        parent_id = row["parent_id"].to_s
        visit.call(rows_by_id[parent_id]) if parent_id.present? && parent_id != "0"

        visited << row["forum_id"].to_s
        sorted << row
      end

    rows.each { |row| visit.call(row) }
    sorted
  end

  def source_count(table, where = nil)
    sql = "SELECT COUNT(*) FROM #{table}"
    sql << " WHERE #{where}" if where
    @source_db.get_first_value(sql)
  end

  def category_import_id(id)
    "#{IMPORT_PREFIX}:forum:#{id}"
  end

  def user_import_id(id)
    "#{IMPORT_PREFIX}:user:#{id}"
  end

  def topic_import_id(id)
    "#{IMPORT_PREFIX}:topic:#{id}"
  end

  def post_import_id(id)
    "#{IMPORT_PREFIX}:post:#{id}"
  end

  def placeholder_post_import_id(topic_id)
    "#{IMPORT_PREFIX}:topic:#{topic_id}:placeholder"
  end
end

ImportScripts::Talbotoc.new.perform if __FILE__ == $PROGRAM_NAME
