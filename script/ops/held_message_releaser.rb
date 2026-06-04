# frozen_string_literal: true

limit = Integer(ENV.fetch("YN_HELD_MESSAGE_RELEASER_LIMIT", "100")) rescue 100
limit = [[limit, 1].max, 1000].min
min_age_minutes = Integer(ENV.fetch("YN_HELD_MESSAGE_RELEASER_MIN_AGE_MINUTES", "15")) rescue 15
min_age_minutes = [[min_age_minutes, 0].max, 1440].min
dry_run = ENV.fetch("YN_HELD_MESSAGE_RELEASER_DRY_RUN", "0").to_s == "1"
allow_pattern = Regexp.new(ENV.fetch("YN_HELD_MESSAGE_RELEASER_ALLOW_PATTERN", "send limit"), Regexp::IGNORECASE)
block_pattern = /suppression list|credential is configured to hold|development mode|likely spam|domain no longer exist|doesn't have an RCPT/i
connection = ActiveRecord::Base.connection

def quote_ident(value)
  "`#{String(value).gsub('`', '``')}`"
end

released = 0
selected = 0
skipped = 0
errors = 0

Server.find_each do |server|
  break if released >= limit

  message_db_name = server.message_db.database_name
  remaining = limit - released
  cutoff = (Time.current - min_age_minutes.minutes).to_i
  sql = <<~SQL
    SELECT m.id, COALESCE(d.details, '') AS details
      FROM #{quote_ident(message_db_name)}.messages m
      JOIN (
        SELECT message_id, MAX(id) AS delivery_id
          FROM #{quote_ident(message_db_name)}.deliveries
         WHERE status = 'Held'
         GROUP BY message_id
      ) latest_held ON latest_held.message_id = m.id
      JOIN #{quote_ident(message_db_name)}.deliveries d
        ON d.id = latest_held.delivery_id
      LEFT JOIN queued_messages q
        ON q.server_id = #{Integer(server.id)}
       AND q.message_id = m.id
     WHERE m.status = 'Held'
       AND m.scope = 'outgoing'
       AND m.raw_table IS NOT NULL
       AND m.timestamp <= #{Integer(cutoff)}
       AND q.id IS NULL
     ORDER BY m.id ASC
     LIMIT #{Integer(remaining * 5)}
  SQL

  connection.select_all(sql).each do |row|
    break if released >= limit

    details = String(row["details"] || "")
    unless details.match?(allow_pattern) && !details.match?(block_pattern)
      skipped += 1
      next
    end

    selected += 1
    next if dry_run

    begin
      message = server.message_db.message(Integer(row["id"]))
      unless message&.raw_message? && message.status == "Held" && message.scope == "outgoing"
        skipped += 1
        next
      end

      if QueuedMessage.where(server_id: server.id, message_id: message.id).exists?
        skipped += 1
        next
      end

      message.add_to_message_queue(manual: true)
      released += 1
    rescue StandardError => e
      errors += 1
      Rails.logger.error("held_message_releaser failed server=#{server.id} message=#{row['id']}: #{e.class}: #{e.message}")
    end
  end
end

puts "held_message_releaser selected=#{selected} released=#{released} skipped=#{skipped} errors=#{errors} dry_run=#{dry_run} min_age_minutes=#{min_age_minutes} limit=#{limit}"