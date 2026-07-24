# frozen_string_literal: true

Server.find_each do |server|
  limit_mb = server.raw_message_retention_size.to_i
  next if limit_mb <= 0

  database = server.message_db
  limit_bytes = limit_mb * 1024 * 1024
  before_bytes = database.total_size
  removed_tables = []

  if before_bytes > limit_bytes
    removed_tables = database.provisioner.remove_raw_tables_until_less_than_size(limit_bytes)
  end

  after_bytes = database.total_size
  puts [
    "server=#{server.permalink}",
    "limit_mb=#{limit_mb}",
    "before_bytes=#{before_bytes}",
    "after_bytes=#{after_bytes}",
    "removed_tables=#{removed_tables.join(',')}",
  ].join(" ")
rescue StandardError => e
  warn "server=#{server.permalink} error=#{e.class}: #{e.message}"
  raise
end
