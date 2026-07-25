# frozen_string_literal: true

require_relative "postal/tracking_link"

class TrackingMiddleware

  TRACKING_PIXEL = File.read(Rails.root.join("app", "assets", "images", "tracking_pixel.png"))

  def initialize(app = nil)
    @app = app
  end

  def call(env)
    unless env["HTTP_X_POSTAL_TRACK_HOST"].to_i == 1
      return @app.call(env)
    end

    request = Rack::Request.new(env)

    case request.path
    when /\A\/img\/([a-z0-9-]+)\/([a-z0-9-]+)/i
      server_token = ::Regexp.last_match(1)
      message_token = ::Regexp.last_match(2)
      dispatch_image_request(request, server_token, message_token)
    when /\A\/([a-z0-9-]+)\/([a-z0-9_-]+)\z/i
      server_token = ::Regexp.last_match(1)
      link_token = ::Regexp.last_match(2)
      dispatch_redirect_request(request, server_token, link_token)
    else
      [200, {}, ["Hello."]]
    end
  end

  private

  def dispatch_image_request(request, server_token, message_token)
    message_db = get_message_db_from_server_token(server_token)
    if message_db.nil?
      return [404, {}, ["Invalid Server Token"]]
    end

    begin
      message = message_db.message(token: message_token)
      message.create_load(request)
    rescue Postal::MessageDB::Message::NotFound
      # This message has been removed, we'll just continue to serve the image
    rescue StandardError => e
      # Somethign else went wrong. We don't want to stop the image loading though because
      # this is our problem. Log this exception though.
      Sentry.capture_exception(e) if defined?(Sentry)
    end

    if request.params["src"].nil?
      headers = {}
      headers["Content-Type"] = "image/png"
      headers["Content-Length"] = TRACKING_PIXEL.bytesize.to_s
      [200, headers, [TRACKING_PIXEL]]
    else
      [400, {}, ["Invalid/missing source image"]]
    end
  end

  def dispatch_redirect_request(request, server_token, link_token)
    message_db = get_message_db_from_server_token(server_token)
    if message_db.nil?
      return [404, {}, ["Invalid Server Token"]]
    end

    destination = Postal::TrackingLink.decode(link_token, server_token: server_token)
    fingerprint = Postal::TrackingLink.fingerprint(link_token)
    link = message_db.select(:links, where: { token: fingerprint }, limit: 1).first

    if link && link["message_id"]
      begin
        message = message_db.message(link["message_id"])
        time = Time.now.to_f
        message_db.update(:messages, { clicked: time }, where: { id: link["message_id"] })
        message_db.insert(:clicks, {
          message_id: link["message_id"],
          link_id: link["id"],
          ip_address: request.ip,
          user_agent: request.user_agent,
          timestamp: time
        })

        WebhookRequest.trigger(message_db.server, "MessageLinkClicked", {
          message: message.webhook_hash,
          url: destination,
          token: link_token,
          ip_address: request.ip,
          user_agent: request.user_agent
        })
      rescue Postal::MessageDB::Message::NotFound
        # Message retention has removed analytics metadata. The encrypted link
        # remains independently redirectable.
      end
    end

    [307, { "Location" => destination }, ["Redirected to: #{destination}"]]
  rescue Postal::TrackingLink::InvalidToken
    [404, {}, ["Invalid link"]]
  end

  def get_message_db_from_server_token(token)
    return unless server = ::Server.find_by_token(token)

    server.message_db
  end

end
