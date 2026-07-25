# frozen_string_literal: true

require "rails_helper"

describe Postal::MessageParser do
  let(:server) { create(:server) }

  it "should not do anything when there are no tracking domains" do
    expect(server.track_domains.size).to eq 0
    message = create_plain_text_message(server, "Hello world!", "test@example.com")
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be false
    expect(parser.tracked_links).to eq 0
    expect(parser.tracked_images).to eq 0
  end

  it "should replace links in messages" do
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain)
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.new_body).to match(/^Hello world! https:\/\/click\.#{message.domain.name}/)
    expect(parser.tracked_links).to eq 1
  end

  it "uses an explicitly configured static default tracking domain" do
    allow(Postal::Config.dns).to receive(:default_track_domain).and_return("track.smtp.example.com")
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")

    parser = Postal::MessageParser.new(message)

    expect(parser.actioned?).to be true
    expect(parser.new_body).to include("Hello world! https://track.smtp.example.com/")
    expect(parser.tracked_links).to eq 1
    expect(server.track_domains).to be_empty
  end

  it "prefers a verified sender-specific tracking domain over the static default" do
    allow(Postal::Config.dns).to receive(:default_track_domain).and_return("track.smtp.example.com")
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain)

    parser = Postal::MessageParser.new(message)

    expect(parser.new_body).to include("Hello world! https://click.#{message.domain.name}/")
  end

  it "ignores an invalid configured default tracking hostname" do
    allow(Postal::Config.dns).to receive(:default_track_domain).and_return("https://unsafe.example.com/path")
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")

    parser = Postal::MessageParser.new(message)

    expect(parser.actioned?).to be false
    expect(parser.tracked_links).to eq 0
  end
end
