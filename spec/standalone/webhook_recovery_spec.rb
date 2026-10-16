# frozen_string_literal: true
# Runs without Rails, database credentials or a network connection.
require 'active_support/all'
require 'json'
require 'ostruct'
require 'rspec'
require_relative '../../lib/postal/process_identity'
require_relative '../../app/services/webhook_delivery_service'

module Postal
  module HTTP; end
  def self.logger; end
end

RSpec.describe 'Webhook delivery recovery' do
  let(:history) { double('history', record: true) }
  let(:webhook) { double('webhook', update_column: true) }
  let(:logger) { double('logger', info: nil, error: nil) }
  let(:request) do
    r = OpenStruct.new(id: 1, webhook_id: 2, event: 'MessageSent', created_at: Time.now,
      payload: {message: {id: 3}}, uuid: 'stable-event', url: 'https://example.test/hook',
      attempts: 0, error: nil, locked_at: Time.now, locked_by: 'worker',
      server: OpenStruct.new(message_db: OpenStruct.new(webhooks: history)), webhook: webhook)
    def r.save!; true; end
    def r.destroy!; self.deleted = true; end
    def r.destroyed?; deleted == true; end
    def r.update_columns(values); values.each { |key, value| self[key] = value }; end
    r
  end
  before do
    allow(Postal).to receive(:logger).and_return(logger)
    allow(logger).to receive(:tagged).and_yield
    allow(Postal::HTTP).to receive(:post).and_return(code: 200, body: 'OK')
  end

  it 'finishes an acknowledged callback after history failure without sending it twice' do
    allow(history).to receive(:record).and_raise(StandardError, 'database unavailable')
    expect { WebhookDeliveryService.new(webhook_request: request).call }.to raise_error('database unavailable')
    expect(request.locked_at).to be_nil
    expect(request.attempts).to eq(1)
    expect(request.retry_after).to be > Time.now
    allow(history).to receive(:record).and_return(true)
    WebhookDeliveryService.new(webhook_request: request).call
    expect(Postal::HTTP).to have_received(:post).once
    expect(request.destroyed?).to be(true)
    expect(request.attempts).to eq(1)
  end

  it 'does not unlock a known successful callback if acknowledgement persistence fails' do
    allow(request).to receive(:save!).and_raise(StandardError, 'main database unavailable')
    expect { WebhookDeliveryService.new(webhook_request: request).call }.to raise_error('main database unavailable')
    expect(request.locked_at).not_to be_nil
    expect(history).not_to have_received(:record)
  end

  it 'preserves the existing retry limits for HTTP failures' do
    allow(Postal::HTTP).to receive(:post).and_return(code: 500, body: 'retry')
    WebhookDeliveryService.new(webhook_request: request).call
    expect(request.attempts).to eq(1)
    expect(request.locked_at).to be_nil
    expect(request.retry_after).to be_within(1.second).of(2.minutes.from_now)
    request.attempts = 5
    WebhookDeliveryService.new(webhook_request: request).call
    expect(request.destroyed?).to be(true)
    expect(request.attempts).to eq(6)
  end

  it 'releases the lease after an exception before an HTTP result' do
    allow(Postal::HTTP).to receive(:post).and_raise(StandardError, 'transport interrupted')
    expect { WebhookDeliveryService.new(webhook_request: request).call }.to raise_error('transport interrupted')
    expect(request.locked_at).to be_nil
    expect(request.destroyed?).to be(false)
  end

  it 'does not send again when deletion fails after a 2xx' do
    allow(request).to receive(:destroy!).and_raise(StandardError, 'delete interrupted')
    expect { WebhookDeliveryService.new(webhook_request: request).call }.to raise_error('delete interrupted')
    allow(request).to receive(:destroy!).and_call_original
    WebhookDeliveryService.new(webhook_request: request).call
    expect(Postal::HTTP).to have_received(:post).once
    expect(request.destroyed?).to be(true)
  end

  it 'has stable and different identities for workers with the same host and PID' do
    allow(Socket).to receive(:gethostname).and_return('shared-host')
    allow(Process).to receive(:pid).and_return(9)
    first = Object.new.extend(Postal::ProcessIdentity)
    second = Object.new.extend(Postal::ProcessIdentity)
    expect(first.process_name).to eq(first.process_name)
    expect(first.process_name).not_to eq(second.process_name)
    expect(first.process_name).to start_with('host:shared-host pid:9 boot:')
  end
end
