# frozen_string_literal: true

require "base64"
require "digest"
require "openssl"
require "uri"
require "yaml"

module Postal
  class TrackingLink

    VERSION = 1
    KEY_BYTES = 32
    NONCE_BYTES = 12
    TAG_BYTES = 16
    HEADER_BYTES = 2
    MAX_TOKEN_LENGTH = 8_192

    class Error < Postal::Error
    end

    class ConfigurationError < Error
    end

    class InvalidToken < Error
    end

    class TokenTooLong < Error
    end

    Keyring = Data.define(:active_id, :keys)

    class << self

      def encode(url, server_token:)
        destination = validate_destination(url)
        active_id, key = active_key
        nonce = OpenSSL::Random.random_bytes(NONCE_BYTES)
        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.encrypt
        cipher.key = key
        cipher.iv = nonce
        cipher.auth_data = authenticated_data(server_token)
        ciphertext = cipher.update(destination) + cipher.final
        token = Base64.urlsafe_encode64(
          [VERSION, active_id].pack("CC") + nonce + ciphertext + cipher.auth_tag(TAG_BYTES),
          padding: false
        )
        raise TokenTooLong, "Encrypted tracking link exceeds #{MAX_TOKEN_LENGTH} characters" if token.bytesize > MAX_TOKEN_LENGTH

        token
      end

      def decode(token, server_token:)
        token = token.to_s
        raise InvalidToken, "Invalid encrypted tracking link" if token.empty? || token.bytesize > MAX_TOKEN_LENGTH

        raw = Base64.urlsafe_decode64(padded_base64(token))
        minimum_length = HEADER_BYTES + NONCE_BYTES + TAG_BYTES + 1
        raise InvalidToken, "Invalid encrypted tracking link" if raw.bytesize < minimum_length

        version, key_id = raw.unpack("CC")
        raise InvalidToken, "Unsupported encrypted tracking link version" unless version == VERSION

        key = keyring.keys[key_id]
        raise InvalidToken, "Unknown encrypted tracking link key" unless key

        nonce = raw.byteslice(HEADER_BYTES, NONCE_BYTES)
        ciphertext_length = raw.bytesize - HEADER_BYTES - NONCE_BYTES - TAG_BYTES
        ciphertext = raw.byteslice(HEADER_BYTES + NONCE_BYTES, ciphertext_length)
        tag = raw.byteslice(-TAG_BYTES, TAG_BYTES)

        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.decrypt
        cipher.key = key
        cipher.iv = nonce
        cipher.auth_tag = tag
        cipher.auth_data = authenticated_data(server_token)
        validate_destination(cipher.update(ciphertext) + cipher.final)
      rescue ArgumentError, OpenSSL::Cipher::CipherError, URI::InvalidURIError
        raise InvalidToken, "Invalid encrypted tracking link"
      end

      def fingerprint(token)
        "e#{VERSION}:#{Digest::SHA256.hexdigest(token.to_s)}"
      end

      def keyring_path
        ENV.fetch(
          "POSTAL_TRACKING_LINK_KEYS_PATH",
          File.join(File.dirname(Postal.config_file_path), "tracking-keys.yml")
        )
      end

      def keyring
        @keyring ||= load_keyring
      end

      def reset_keyring!
        @keyring = nil
      end

      private

      def active_key
        ring = keyring
        [ring.active_id, ring.keys.fetch(ring.active_id)]
      end

      def authenticated_data(server_token)
        "postal-tracking-link:#{VERSION}:#{server_token}"
      end

      def padded_base64(value)
        value + ("=" * ((4 - (value.length % 4)) % 4))
      end

      def validate_destination(url)
        value = url.to_s
        uri = URI.parse(value)
        unless %w[http https].include?(uri.scheme&.downcase) && uri.host && !uri.host.empty?
          raise InvalidToken, "Tracking destination must be an absolute HTTP or HTTPS URL"
        end

        value
      end

      def load_keyring
        path = keyring_path
        raise ConfigurationError, "Tracking link keyring is missing at #{path}" unless File.file?(path)

        document = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
        active_id = Integer(document.fetch("active"))
        unless active_id.between?(0, 255)
          raise ConfigurationError, "Active tracking link key ID must be between 0 and 255"
        end

        keys = document.fetch("keys").each_with_object({}) do |(raw_id, raw_key), result|
          key_id = Integer(raw_id)
          raise ConfigurationError, "Tracking link key ID must be between 0 and 255" unless key_id.between?(0, 255)

          key = Base64.strict_decode64(raw_key.to_s)
          raise ConfigurationError, "Tracking link key #{key_id} must decode to #{KEY_BYTES} bytes" unless key.bytesize == KEY_BYTES

          result[key_id] = key
        rescue ArgumentError
          raise ConfigurationError, "Tracking link key #{raw_id.inspect} is not valid Base64"
        end

        raise ConfigurationError, "Active tracking link key #{active_id} is missing" unless keys.key?(active_id)

        Keyring.new(active_id: active_id, keys: keys.freeze)
      rescue ArgumentError, KeyError, TypeError, Psych::Exception => e
        raise ConfigurationError, "Invalid tracking link keyring at #{path}: #{e.message}"
      end

    end

  end
end
