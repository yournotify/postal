# frozen_string_literal: true

limit = Integer(ENV.fetch("YN_SUPPRESSED_QUEUE_CLEANER_LIMIT", "2000")) rescue 2000
limit = [[limit, 1].max, 10_000].min
locker = Postal.locker_name_with_suffix("suppressed-cleaner-#{Process.pid}")
lock_time = Time.current
connection = ActiveRecord::Base.connection
recipient_type = connection.quote("recipient")
outgoing_scope = connection.quote("outgoing")

def quote_ident(value)
  "`#{String(value).gsub('`', '``')}`"
end

cleaned = 0
selected = 0
errors = 0

Server.find_each do |server|
  message_db_name = server.message_db.database_name
  sql = <<~SQL
    SELECT q.id
      FROM queued_messages q
      JOIN #{quote_ident(message_db_name)}.messages m
        ON m.id = q.message_id
      JOIN #{quote_ident(message_db_name)}.suppressions s
        ON s.type = #{recipient_type}
       AND s.address = m.rcpt_to
       AND s.keep_until >= UNIX_TIMESTAMP(NOW())
     WHERE q.server_id = #{Integer(server.id)}
       AND q.manual = 0
       AND q.locked_by IS NULL
       AND q.locked_at IS NULL
       AND m.scope = #{outgoing_scope}
     ORDER BY q.id ASC
     LIMIT #{limit}
  SQL

  ids = connection.select_values(sql).map(&:to_i).select(&:positive?)
  next if ids.empty?

  selected += ids.length
  QueuedMessage.where(id: ids, locked_by: nil, locked_at: nil).update_all(locked_by: locker, locked_at: lock_time)

  QueuedMessage.where(id: ids, locked_by: locker, locked_at: lock_time).find_each do |queued_message|
    begin
      message = queued_message.message
      unless message && message.scope == "outgoing"
        queued_message.update_columns(locked_by: nil, locked_at: nil)
        next
      end

      suppression = queued_message.server.message_db.suppression_list.get(:recipient, message.rcpt_to)
      unless suppression
        queued_message.update_columns(locked_by: nil, locked_at: nil)
        next
      end

      reason = String(suppression["reason"] || "suppressed")
      message.create_delivery(
        "Held",
        details: "Recipient (#{message.rcpt_to}) is on the suppression list (reason: #{reason})"
      )
      queued_message.destroy
      cleaned += 1
    rescue StandardError => e
      errors += 1
      begin
        queued_message.update_columns(locked_by: nil, locked_at: nil) unless queued_message.destroyed?
      rescue StandardError
        nil
      end
      Rails.logger.error("suppressed_queue_cleaner failed queued_message=#{queued_message.id}: #{e.class}: #{e.message}")
    end
  end
end

QueuedMessage.where(locked_by: locker, locked_at: lock_time).update_all(locked_by: nil, locked_at: nil)
puts "suppressed_queue_cleaner selected=#{selected} cleaned=#{cleaned} errors=#{errors}"