# frozen_string_literal: true

class WebhookDeliveryService

  ACK_PREFIX = "postal-http-ack-v1:"

  RETRIES = { 1 => 2.minutes, 2 => 3.minutes, 3 => 6.minutes, 4 => 10.minutes, 5 => 15.minutes }.freeze

  def initialize(webhook_request:)
    @webhook_request = webhook_request
  end

  def call
    logger.tagged(webhook: @webhook_request.webhook_id, webhook_request: @webhook_request.id) do
      if @webhook_request.error.to_s.start_with?(ACK_PREFIX)
        @http_result = JSON.parse(@webhook_request.error.delete_prefix(ACK_PREFIX), symbolize_names: true)
        raise "Invalid stored webhook acknowledgement" unless (200...300).cover?(@http_result[:code])

        @success = true
        @ack_persisted = true
      else
        generate_payload
        send_request
        persist_acknowledgement if success?
      end
      record_attempt
      appreciate_http_result
      update_webhook_request
    rescue StandardError
      recover_interrupted_delivery
      raise
    end
  end

  def success?
    @success == true
  end

  private

  def generate_payload
    @payload = {
      event: @webhook_request.event,
      timestamp: @webhook_request.created_at.to_f,
      payload: @webhook_request.payload,
      uuid: @webhook_request.uuid
    }.to_json
  end

  def send_request
    @http_result = Postal::HTTP.post(@webhook_request.url,
                                     sign: true,
                                     json: @payload,
                                     timeout: 5)

    @success = (@http_result[:code] >= 200 && @http_result[:code] < 300)
  end

  # Save a received 2xx before writing the separate message-history database.
  # Recovery can then complete local bookkeeping without another HTTP request.
  def persist_acknowledgement
    @webhook_request.attempts += 1 unless @ack_attempt_counted
    @ack_attempt_counted = true
    @webhook_request.error = ACK_PREFIX + {
      code: @http_result[:code], body: @http_result[:body].to_s[0, 8000]
    }.to_json
    @webhook_request.save!
    @ack_persisted = true
  end

  def recover_interrupted_delivery
    return if @webhook_request.destroyed?

    # If the first acknowledgement write failed, try to preserve it before
    # releasing the lease. Never unlock a known 2xx without its durable marker.
    persist_acknowledgement if success? && !@ack_persisted
    @webhook_request.update_columns(locked_by: nil, locked_at: nil, retry_after: 2.minutes.from_now)
  rescue StandardError => error
    logger.error "Webhook recovery could not release its lock: #{error.class}"
  end

  def record_attempt
    @webhook_request.attempts += 1 unless @ack_persisted

    if success?
      @webhook_request.retry_after = nil
    else
      @webhook_request.retry_after = RETRIES[@webhook_request.attempts]&.from_now
    end

    @attempt = @webhook_request.server.message_db.webhooks.record(
      event: @webhook_request.event,
      url: @webhook_request.url,
      webhook_id: @webhook_request.webhook_id,
      attempt: @webhook_request.attempts,
      timestamp: Time.now.to_f,
      payload: @webhook_request.payload.to_json,
      uuid: @webhook_request.uuid,
      status_code: @http_result[:code],
      body: @http_result[:body],
      will_retry: @webhook_request.retry_after.present?
    )
  end

  def appreciate_http_result
    if success?
      logger.info "Received #{@http_result[:code]} status code. That's OK."
      @webhook_request.destroy!
      @webhook_request.webhook&.update_column(:last_used_at, Time.current)
      return
    end

    logger.error "Received #{@http_result[:code]} status code. That's not OK."
    @webhook_request.error = "Couldn't send to URL. Code received was #{@http_result[:code]}"
  end

  def update_webhook_request
    return if @webhook_request.destroyed?

    if @webhook_request.retry_after
      logger.info "Will retry #{@webhook_request.retry_after} (this was attempt #{@webhook_request.attempts})"
      @webhook_request.locked_by = nil
      @webhook_request.locked_at = nil
      @webhook_request.save!
      return
    end

    logger.info "Have tried #{@webhook_request.attempts} times. Giving up."
    @webhook_request.destroy!
  end

  def logger
    Postal.logger
  end

end
