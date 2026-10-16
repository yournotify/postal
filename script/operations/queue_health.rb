require 'json'
c=ActiveRecord::Base.connection
c.execute('SET SESSION max_statement_time=10')
c.execute('START TRANSACTION READ ONLY')
result={at:Time.now.utc.iso8601}
result[:webhooks]=c.exec_query("SELECT COUNT(*) pending,SUM(locked_at < UTC_TIMESTAMP()-INTERVAL 15 MINUTE AND COALESCE(error,'') NOT LIKE 'Recovery review required%') stale_unreviewed,SUM(error LIKE 'Recovery review required%') historical_review,SUM(error LIKE 'postal-http-ack-v1:%') acknowledged_bookkeeping FROM webhook_requests").to_a.first
result[:messages]=c.exec_query("SELECT COUNT(*) pending,SUM(locked_at < UTC_TIMESTAMP()-INTERVAL 15 MINUTE) stale_locked FROM queued_messages").to_a.first
result[:scheduler]=c.exec_query("SELECT role,worker,acquired_at FROM worker_roles").to_a
c.execute('ROLLBACK')
puts JSON.generate(result)
exit 1 if result[:webhooks]['stale_unreviewed'].to_i>0 || result[:messages]['stale_locked'].to_i>0
