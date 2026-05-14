# frozen_string_literal: true

require "csv"
require "fileutils"

class TalbotocTopicStatusRepair
  REPORT_DIR = ENV["TALBOTOC_REPORT_DIR"]
  DRY_RUN = ENV.fetch("DRY_RUN", "1") != "0"
  START_AT = ENV.fetch("TALBOTOC_STATUS_REPAIR_START", "2026-05-01")
  END_AT = ENV.fetch("TALBOTOC_STATUS_REPAIR_END", "2026-05-07")
  BATCH_SIZE = ENV.fetch("TALBOTOC_STATUS_REPAIR_BATCH_SIZE", "1000").to_i
  ACTION_CODES = %w[closed.enabled closed.disabled]
  IMPORT_PREFIX = "talbotoc:topic:%"

  def initialize(
    report_dir: REPORT_DIR,
    dry_run: DRY_RUN,
    start_at: START_AT,
    end_at: END_AT,
    batch_size: BATCH_SIZE
  )
    @report_dir =
      report_dir.presence ||
        "/shared/import/talbotoc/reports/topic-status-repair-" \
          "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
    @dry_run = dry_run
    @start_at = Time.zone.parse(start_at)
    @end_at = Time.zone.parse(end_at)
    @batch_size = batch_size.positive? ? batch_size : 1000
    @summary = Hash.new(0)

    FileUtils.mkdir_p(@report_dir)
  end

  def run
    puts "TalbotOC topic status repair"
    puts "Report dir: #{@report_dir}"
    puts "Mode: #{@dry_run ? "DRY_RUN" : "LIVE"}"
    puts "Window: #{@start_at.utc.iso8601} to #{@end_at.utc.iso8601}"

    candidate_ids = candidate_scope.order(:id).pluck(:id)
    topic_ids = Post.where(id: candidate_ids).distinct.pluck(:topic_id)
    closed_states = Topic.where(id: topic_ids).pluck(:id, :closed).to_h

    @summary[:candidate_posts] = candidate_ids.size
    @summary[:candidate_topics] = topic_ids.size
    @summary[:closed_topics_before] = closed_states.count { |_topic_id, closed| closed }

    write_candidate_report(candidate_ids)
    write_topic_report(topic_ids, closed_states, before: true)

    delete_candidates(candidate_ids, topic_ids, closed_states) unless @dry_run

    write_topic_report(topic_ids, closed_states, before: false)
    @summary[:closed_topics_after] = Topic.where(id: topic_ids, closed: true).count
    @summary[:remaining_candidates] = candidate_scope.count

    File.write(File.join(@report_dir, "summary.json"), JSON.pretty_generate(@summary))
    puts @summary.inspect
  end

  private

  def candidate_scope
    Post
      .joins("INNER JOIN topics t ON t.id = posts.topic_id")
      .joins("INNER JOIN topic_custom_fields tcf_import_id ON tcf_import_id.topic_id = t.id")
      .where("tcf_import_id.name = ?", "import_id")
      .where("tcf_import_id.value LIKE ?", IMPORT_PREFIX)
      .where(post_type: Post.types[:small_action], action_code: ACTION_CODES)
      .where("posts.created_at >= ? AND posts.created_at < ?", @start_at, @end_at)
  end

  def write_candidate_report(candidate_ids)
    path = File.join(@report_dir, "candidate_posts.csv")
    CSV.open(path, "w") do |csv|
      csv << %w[
        post_id
        topic_id
        post_number
        action_code
        post_created_at
        topic_closed
        topic_posts_count
        topic_highest_post_number
        topic_import_id
        url
      ]

      Post
        .where(id: candidate_ids)
        .joins(:topic)
        .joins(
          "INNER JOIN topic_custom_fields tcf_import_id ON " \
            "tcf_import_id.topic_id = posts.topic_id AND tcf_import_id.name = 'import_id'",
        )
        .order(:topic_id, :post_number)
        .pluck(
          "posts.id",
          "posts.topic_id",
          "posts.post_number",
          "posts.action_code",
          "posts.created_at",
          "topics.closed",
          "topics.posts_count",
          "topics.highest_post_number",
          "tcf_import_id.value",
          "topics.slug",
        )
        .each do |post_id, topic_id, post_number, action_code, created_at, closed, posts_count,
                  highest, import_id, slug|
          @summary[action_code] += 1
          csv << [
            post_id,
            topic_id,
            post_number,
            action_code,
            created_at,
            closed,
            posts_count,
            highest,
            import_id,
            Discourse.base_url + "/t/#{slug}/#{topic_id}/#{post_number}",
          ]
        end
    end
  end

  def write_topic_report(topic_ids, closed_states, before:)
    path = File.join(@report_dir, before ? "topics_before.csv" : "topics_after.csv")
    CSV.open(path, "w") do |csv|
      csv << %w[
        topic_id
        topic_import_id
        classification
        closed_preserved
        action_count
        enabled_count
        disabled_count
        min_action_at
        max_action_at
        topic_closed
        posts_count
        highest_post_number
        last_posted_at
        last_post_user_id
      ]

      action_stats_by_topic(topic_ids).each do |row|
        topic = Topic.find_by(id: row.topic_id)
        next if topic.blank?

        classification = classify_topic(row)
        @summary["topics_#{classification}"] += 1 if before
        csv << [
          row.topic_id,
          row.import_id,
          classification,
          closed_states[row.topic_id] == topic.closed,
          row.action_count,
          row.enabled_count,
          row.disabled_count,
          row.min_action_at,
          row.max_action_at,
          topic.closed,
          topic.posts_count,
          topic.highest_post_number,
          topic.last_posted_at,
          topic.last_post_user_id,
        ]
      end
    end
  end

  def action_stats_by_topic(topic_ids)
    return [] if topic_ids.blank?

    DB.query(
      <<~SQL,
      SELECT
        posts.topic_id,
        tcf_import_id.value AS import_id,
        COUNT(*) AS action_count,
        SUM(CASE WHEN posts.action_code = 'closed.enabled' THEN 1 ELSE 0 END) AS enabled_count,
        SUM(CASE WHEN posts.action_code = 'closed.disabled' THEN 1 ELSE 0 END) AS disabled_count,
        MIN(posts.created_at) AS min_action_at,
        MAX(posts.created_at) AS max_action_at
      FROM posts
      INNER JOIN topic_custom_fields tcf_import_id
        ON tcf_import_id.topic_id = posts.topic_id
       AND tcf_import_id.name = 'import_id'
      WHERE posts.topic_id IN (:topic_ids)
        AND posts.post_type = :small_action
        AND posts.action_code IN (:action_codes)
        AND posts.created_at >= :start_at
        AND posts.created_at < :end_at
      GROUP BY posts.topic_id, tcf_import_id.value
      ORDER BY posts.topic_id
    SQL
      topic_ids: topic_ids,
      small_action: Post.types[:small_action],
      action_codes: ACTION_CODES,
      start_at: @start_at,
      end_at: @end_at,
    )
  end

  def classify_topic(row)
    enabled_count = row.enabled_count.to_i
    disabled_count = row.disabled_count.to_i

    if enabled_count.positive? && disabled_count.positive?
      "close_and_reopen"
    elsif enabled_count.positive?
      "closed_only"
    elsif disabled_count.positive?
      "reopen_only"
    else
      "unexpected"
    end
  end

  def delete_candidates(candidate_ids, topic_ids, closed_states)
    candidate_ids.each_slice(@batch_size).with_index do |batch, index|
      cleanup_post_dependents(batch)
      deleted = Post.where(id: batch).delete_all
      @summary[:deleted_posts] += deleted
      puts "deleted=#{@summary[:deleted_posts]} batch=#{index + 1}" if (index + 1) % 10 == 0
    end

    topic_ids.each_slice(@batch_size) do |batch|
      batch.each { |topic_id| Topic.reset_highest(topic_id) }
      batch.each do |topic_id|
        Topic.where(id: topic_id).update_all(closed: closed_states[topic_id])
      end
    end
  end

  def cleanup_post_dependents(post_ids)
    delete_where(PostCustomField, post_id: post_ids)
    delete_where(PostAction, post_id: post_ids)
    delete_where(PostStat, post_id: post_ids)
    delete_where(PostDetail, post_id: post_ids)
    delete_where(PostRevision, post_id: post_ids)
    delete_where(PostTiming, post_id: post_ids)
    delete_where(PostSearchData, post_id: post_ids)
    delete_where(PostHotlinkedMedia, post_id: post_ids)
    delete_where(GroupMention, post_id: post_ids)
    delete_where(UploadReference, target_type: "Post", target_id: post_ids)
    delete_where(Reviewable, target_type: "Post", target_id: post_ids)
    delete_where(Bookmark, bookmarkable_type: "Post", bookmarkable_id: post_ids)
    delete_where(UserAction, target_post_id: post_ids)

    PostReply
      .where("post_id IN (:post_ids) OR reply_post_id IN (:post_ids)", post_ids: post_ids)
      .delete_all
    TopicLink
      .where("post_id IN (:post_ids) OR link_post_id IN (:post_ids)", post_ids: post_ids)
      .delete_all
  end

  def delete_where(model, conditions)
    return if !model.table_exists?
    return if conditions.keys.any? { |column| !model.column_names.include?(column.to_s) }

    model.where(conditions).delete_all
  end
end

TalbotocTopicStatusRepair.new.run if __FILE__ == $PROGRAM_NAME
