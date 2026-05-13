# frozen_string_literal: true

require "sqlite3"
require "tempfile"
require_relative "../../../script/import_scripts/talbotoc"

RSpec.describe ImportScripts::Talbotoc do
  before do
    I18n.backend.store_translations(:en, { test: "Test" })
    STDOUT.stubs(:write)
  end

  let(:db_file) { Tempfile.new(%w[talbotoc .db]) }
  let(:db_path) { db_file.path }

  after { db_file.close! }

  def with_source_db
    db = SQLite3::Database.new(db_path)
    yield db
  ensure
    db&.close
  end

  def create_source_schema(db)
    db.execute <<~SQL
      CREATE TABLE forums (
        forum_id TEXT PRIMARY KEY,
        forum_name TEXT,
        parent_id TEXT,
        path TEXT,
        access_mode TEXT,
        sub_only INTEGER DEFAULT 0
      )
    SQL

    db.execute <<~SQL
      CREATE TABLE topics (
        topic_id TEXT PRIMARY KEY,
        forum_id TEXT,
        topic_title TEXT,
        total_post_num INTEGER,
        first_post_author_id TEXT,
        first_post_author_name TEXT,
        short_content TEXT,
        canonical_url TEXT,
        posts_fetched_count INTEGER DEFAULT 0,
        posts_complete INTEGER DEFAULT 0,
        is_closed INTEGER DEFAULT 0,
        post_time TEXT
      )
    SQL

    db.execute <<~SQL
      CREATE TABLE posts (
        post_id TEXT PRIMARY KEY,
        topic_id TEXT,
        forum_id TEXT,
        topic_title TEXT,
        author_id TEXT,
        author_name TEXT,
        post_time TEXT,
        position INTEGER,
        post_content TEXT,
        body_text TEXT,
        source_url TEXT
      )
    SQL

    db.execute <<~SQL
      CREATE TABLE media_assets (
        media_id TEXT PRIMARY KEY,
        source_url TEXT,
        normalized_url TEXT,
        post_id TEXT,
        status TEXT,
        local_path TEXT,
        asset_type TEXT
      )
    SQL
  end

  def seed_source_data(db, include_real_placeholder_post: false)
    db.execute(<<~SQL, ["10", "The Garage", "0", "The Garage", "guest", 1])
        INSERT INTO forums (forum_id, forum_name, parent_id, path, access_mode, sub_only)
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
    db.execute(<<~SQL, ["11", "Electrical", "10", "The Garage > Electrical", "guest", 0])
        INSERT INTO forums (forum_id, forum_name, parent_id, path, access_mode, sub_only)
        VALUES (?, ?, ?, ?, ?, ?)
      SQL

    db.execute(
      <<~SQL,
        INSERT INTO topics (
          topic_id, forum_id, topic_title, total_post_num, first_post_author_id,
          first_post_author_name, short_content, canonical_url, posts_fetched_count,
          posts_complete, post_time
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "100",
        "11",
        "Leisure battery charging",
        2,
        "1",
        "Alex",
        "Short starter excerpt",
        "https://talbotoc.com/viewtopic.php?t=100",
        2,
        1,
        "20110101T10:00:00+00:00",
      ],
    )
    db.execute(
      <<~SQL,
        INSERT INTO topics (
          topic_id, forum_id, topic_title, total_post_num, first_post_author_id,
          first_post_author_name, short_content, canonical_url, posts_fetched_count,
          posts_complete, post_time
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "200",
        "11",
        "Pending topic",
        1,
        "2",
        "Bill",
        "Known excerpt",
        "https://talbotoc.com/viewtopic.php?t=200",
        include_real_placeholder_post ? 1 : 0,
        include_real_placeholder_post ? 1 : 0,
        "20110102T10:00:00+00:00",
      ],
    )

    db.execute(
      <<~SQL,
        INSERT INTO posts (
          post_id, topic_id, forum_id, topic_title, author_id, author_name,
          post_time, position, post_content, body_text, source_url
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "1001",
        "100",
        "11",
        "Leisure battery charging",
        "1",
        "Alex",
        "20110101T10:00:00+00:00",
        1,
        "First post body",
        "First post body",
        "https://talbotoc.com/viewtopic.php?t=100&p=1001#p1001",
      ],
    )
    db.execute(
      <<~SQL,
        INSERT INTO posts (
          post_id, topic_id, forum_id, topic_title, author_id, author_name,
          post_time, position, post_content, body_text, source_url
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "1002",
        "100",
        "11",
        "Leisure battery charging",
        "2",
        "Bill",
        "20110101T11:00:00+00:00",
        2,
        "Reply body",
        "Reply body",
        "https://talbotoc.com/viewtopic.php?t=100&p=1002#p1002",
      ],
    )

    insert_pending_topic_real_post(db) if include_real_placeholder_post
  end

  def insert_pending_topic_real_post(db)
    db.execute(
      <<~SQL,
        INSERT INTO posts (
          post_id, topic_id, forum_id, topic_title, author_id, author_name,
          post_time, position, post_content, body_text, source_url
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "2001",
        "200",
        "11",
        "Pending topic",
        "2",
        "Bill",
        "20110102T10:00:00+00:00",
        1,
        "Real body has arrived",
        "Real body has arrived",
        "https://talbotoc.com/viewtopic.php?t=200&p=2001#p2001",
      ],
    )
  end

  def run_import(**kwargs)
    described_class.new(db_path: db_path, **kwargs).perform
  end

  def build_import(**kwargs)
    described_class.new(db_path: db_path, **kwargs)
  end

  def insert_media_asset(db, post_id:, source_url:, local_path: "image.jpg")
    db.execute(
      <<~SQL,
        INSERT INTO media_assets (
          media_id, source_url, normalized_url, post_id, status, local_path, asset_type
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      ["media-#{post_id}", source_url, source_url, post_id, "downloaded", local_path, "image"],
    )
  end

  def talbotoc_imported_post_count
    PostCustomField.where(
      name: "import_id",
      value: %w[
        talbotoc:post:1001
        talbotoc:post:1002
        talbotoc:post:2001
        talbotoc:topic:200:placeholder
      ],
    ).count
  end

  def duplicate_placeholder_import_id_count
    PostCustomField.where(name: "import_id", value: "talbotoc:topic:200:placeholder").count
  end

  it "imports categories, staged users, real posts, and placeholder topics" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
    end

    run_import

    expect(CategoryCustomField.exists?(name: "import_id", value: "talbotoc:forum:11")).to eq(true)
    expect(UserCustomField.exists?(name: "import_id", value: "talbotoc:user:1")).to eq(true)
    expect(User.find_by_email("talbotoc-user-1@email.invalid")).to be_staged

    expect(PostCustomField.exists?(name: "import_id", value: "talbotoc:post:1001")).to eq(true)
    expect(PostCustomField.exists?(name: "import_id", value: "talbotoc:post:1002")).to eq(true)
    expect(
      PostCustomField.exists?(name: "import_id", value: "talbotoc:topic:200:placeholder"),
    ).to eq(true)

    placeholder_topic =
      TopicCustomField.find_by!(name: "import_id", value: "talbotoc:topic:200").topic
    expect(placeholder_topic).to be_closed
    expect(placeholder_topic.first_post.raw).to include("Archive import pending")
  end

  it "is rerunnable and replaces a placeholder when the real first post arrives" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
    end

    run_import
    expect(talbotoc_imported_post_count).to eq(3)

    with_source_db do |db|
      db.execute(
        "UPDATE topics SET posts_fetched_count = 1, posts_complete = 1 WHERE topic_id = '200'",
      )
      insert_pending_topic_real_post(db)
    end

    run_import

    expect(talbotoc_imported_post_count).to eq(3)
    expect(PostCustomField.exists?(name: "import_id", value: "talbotoc:post:2001")).to eq(true)

    replaced_post = PostCustomField.find_by!(name: "import_id", value: "talbotoc:post:2001").post
    expect(replaced_post.raw).to eq("Real body has arrived")
    expect(replaced_post.topic.custom_fields[described_class::PLACEHOLDER_FIELD]).to eq("f")
  end

  it "sanitizes titles that exceed Discourse emoji limits when replacing placeholders" do
    SiteSetting.max_emojis_in_title = 1

    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
      db.execute("UPDATE topics SET topic_title = 'Happy 😀 camper 🚐 thread' WHERE topic_id = '200'")
    end

    run_import

    with_source_db do |db|
      db.execute(
        "UPDATE topics SET posts_fetched_count = 1, posts_complete = 1 WHERE topic_id = '200'",
      )
      insert_pending_topic_real_post(db)
    end

    run_import

    replaced_post = PostCustomField.find_by!(name: "import_id", value: "talbotoc:post:2001").post
    expect(replaced_post.topic.title).to eq("Happy camper thread")
  end

  it "does not create duplicate placeholders when a stale importer instance reruns" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
    end

    stale_import = build_import

    run_import
    expect(duplicate_placeholder_import_id_count).to eq(1)

    stale_import.perform

    expect(duplicate_placeholder_import_id_count).to eq(1)
    expect(TopicCustomField.where(name: "import_id", value: "talbotoc:topic:200").count).to eq(1)
  end

  it "prevents overlapping import runs" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
    end

    File.any_instance.stubs(:flock).returns(false)

    expect { described_class.new(db_path: db_path).perform }.to raise_error(
      RuntimeError,
      /Another TalbotOC import is already running/,
    )
  end

  it "falls back to the system user when an imported user mapping is stale" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
    end

    import = build_import
    import.stubs(:user_id_from_imported_user_id).with("talbotoc:user:1").returns(-1)

    expect(import.send(:post_user, { "author_id" => "1" })).to eq(Discourse.system_user)
    expect(import.send(:topic_user_id, { "first_post_author_id" => "1" })).to eq(
      Discourse::SYSTEM_USER_ID,
    )
  end

  it "skips broad media refresh in fast incremental mode" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
    end

    run_import

    described_class.any_instance.expects(:refresh_imported_post_media).never
    run_import(fast_incremental: true)
  end

  it "still embeds downloaded media on new posts in fast incremental mode" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
      db.execute(
        "UPDATE posts SET post_content = 'Photo http://example.com/photo.jpg' WHERE post_id = '1001'",
      )
      insert_media_asset(db, post_id: "1001", source_url: "http://example.com/photo.jpg")
    end

    described_class.any_instance.stubs(:upload_markdown).returns("![photo](upload://photo.jpg)")

    run_import(media_dir: "/tmp", fast_incremental: true)

    post = PostCustomField.find_by!(name: "import_id", value: "talbotoc:post:1001").post
    expect(post.raw).to eq("Photo ![photo](upload://photo.jpg)")
  end

  it "applies topic offset before limit" do
    with_source_db do |db|
      create_source_schema(db)
      seed_source_data(db)
      db.execute(<<~SQL)
          INSERT INTO topics (
            topic_id, forum_id, topic_title, total_post_num, first_post_author_id,
            first_post_author_name, short_content, canonical_url, posts_fetched_count,
            posts_complete, post_time
          )
          VALUES ('300', '11', 'Third topic', 0, '1', 'Alex', 'Third', 'https://talbotoc.com/viewtopic.php?t=300', 0, 0, '20110103T10:00:00+00:00')
        SQL
    end

    rows = build_import(limit: 1, topic_offset: 1).topic_rows

    expect(rows.map { |row| row["topic_id"] }).to eq(["200"])
  end
end
