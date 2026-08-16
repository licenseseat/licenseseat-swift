#!/usr/bin/env ruby
# frozen_string_literal: true

# Golden machine-file fixture generator.
#
# This script produces `machine_file_fixtures.json` by driving the LicenseSeat
# SERVER's own crypto code. It loads the real service from the installed gem:
#
#   .../gems/license_seat-0.9.2/lib/license_seat/services/offline_machine_file.rb
#
# and calls its private `build_plaintext_payload`, `encrypt_payload`,
# `sign_encrypted_data`, and `wrap_as_certificate` methods verbatim. Nothing in
# this file re-implements the certificate format: the armor, the canonical JSON,
# the SHA256(license_key || fingerprint) key derivation, the AES-256-GCM
# encoding, and the Ed25519 "machine/<enc>" signing message all come from the
# gem. Only the Rails-only surface is stubbed:
#
#   * ActiveSupport helpers the service calls (`Time.current`, `Integer#days`,
#     `Object#present?`/`blank?`)   -- see the SHIM section below
#   * ActiveRecord models (`License`, `Activation`, `LicensePlan`, `Product`)
#     -- replaced by plain value objects with the same reader names
#   * `generate`'s `@license.with_lock` DB transaction, activation lookup, plan
#     TTL clamping, audit-event write, and signing-key/tenant provider lookup
#     -- see gem `offline_machine_file.rb:118-153` and `:655-678`
#
# The response envelope written to each fixture mirrors
# `app/controllers/license_seat/api/v1/machine_files_controller.rb:163-180`
# (`render_machine_file_success`) byte for byte.
#
# Usage:
#   ruby Tests/LicenseSeatSDKTests/Fixtures/generate_machine_file_fixtures.rb
#
# Determinism: the Ed25519 signing key and the AES nonces are fixed seeds, so
# regenerating the file with an unchanged gem yields an identical result.

require "json"
require "time"
require "openssl"
require "base64"
require "ed25519"

GEM_ROOT = ENV.fetch(
  "LICENSE_SEAT_GEM_ROOT",
  "/Users/javi/.rbenv/versions/3.4.7/lib/ruby/gems/3.4.0/gems/license_seat-0.9.2"
)

# ---------------------------------------------------------------------------
# SHIM: the minimum ActiveSupport surface `OfflineMachineFile` touches.
# ---------------------------------------------------------------------------

class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    self if present?
  end
end

class NilClass
  def blank? = true
end

class FalseClass
  def blank? = true
end

class TrueClass
  def blank? = false
end

class Integer
  def days = self * 86_400
end

class Time
  # The service reads the wall clock through `Time.current`
  # (gem offline_machine_file.rb:257 and :342). Redirect it to a settable
  # value so an "issued in the past" fixture can be produced honestly, using
  # the same code path as a live issuance.
  class << self
    attr_accessor :fixture_now

    def current
      fixture_now || Time.now.utc
    end
  end
end

module LicenseSeat; end
require File.join(GEM_ROOT, "lib/license_seat/utils/json_utils.rb")
require File.join(GEM_ROOT, "lib/license_seat/services/offline_machine_file.rb")

# ---------------------------------------------------------------------------
# Stand-ins for the ActiveRecord objects the payload builder reads.
# Reader names match gem offline_machine_file.rb:256-349 exactly.
# ---------------------------------------------------------------------------

Product = Struct.new(:slug, keyword_init: true)
LicensePlan = Struct.new(:mode, :seat_limit, :key, keyword_init: true)
Entitlement = Struct.new(:key, :expires_at, keyword_init: true) do
  def active?(at_time:) = expires_at.nil? || expires_at > at_time
end
FakeLicense = Struct.new(
  :license_key, :status, :starts_at, :ends_at, :metadata,
  :product, :license_plan, :license_entitlements, :tenant,
  keyword_init: true
)
FakeActivation = Struct.new(:id, :activated_at, :metadata, keyword_init: true)

# Subclass that replaces ONLY the tenant/provider indirection. Every
# cryptographic method is inherited untouched from the gem.
class FixtureMachineFile < LicenseSeat::Services::OfflineMachineFile
  def initialize(signing_key_bytes:, kid:, activation:, **kwargs)
    super(**kwargs)
    @signing_key_bytes = signing_key_bytes
    @kid = kid
    # `generate` normally sets this from `validate_activation_exists!`
    # (gem offline_machine_file.rb:215-225).
    @activation = activation
  end

  # gem offline_machine_file.rb:655-678 resolves this through tenant/global
  # configuration providers; the fixture supplies the 32-byte seed directly.
  def resolve_signing_key = @signing_key_bytes

  def certificate
    plaintext = send(:build_plaintext_payload)
    encrypted = send(:encrypt_payload, plaintext)
    signed = send(:sign_encrypted_data, encrypted)
    [send(:wrap_as_certificate, signed), plaintext, signed]
  end

  # Re-sign an attacker-modified `enc` with the legitimate key. Used to build
  # the fixture that proves the AES-GCM tag is enforced independently of the
  # Ed25519 signature.
  def certificate_for(encrypted_string)
    signed = send(:sign_encrypted_data, encrypted_string)
    [send(:wrap_as_certificate, signed), signed]
  end
end

# ---------------------------------------------------------------------------
# Fixture identity
# ---------------------------------------------------------------------------

KEY_ID          = "machine-file-fixture-2026"
LICENSE_KEY     = "MF-FIXTURE-1234-5678-ABCD"
FINGERPRINT     = "fixture-machine-fingerprint-0001"
PRODUCT_SLUG    = "hustl"
ACTIVATION_ID   = "44444444-4444-4444-4444-444444444444"
PLAN_KEY        = "pro"
SDK_VERSION     = "swift-0.4.2"

# Deterministic 32-byte Ed25519 seeds (fixtures must be reproducible).
SIGNING_SEED       = ("\x11".b * 32).freeze
WRONG_SIGNING_SEED = ("\x22".b * 32).freeze

SIGNING_KEY = Ed25519::SigningKey.new(SIGNING_SEED)
WRONG_KEY   = Ed25519::SigningKey.new(WRONG_SIGNING_SEED)

ISSUED_AT  = Time.utc(2026, 8, 16, 12, 0, 0)
LONG_TTL   = 3650 # ~10 years, so the "valid" fixture does not rot
GRACE_DAYS = 3

def build_license(ends_at:)
  FakeLicense.new(
    license_key: LICENSE_KEY,
    status: "active",
    starts_at: Time.utc(2026, 1, 1),
    ends_at: ends_at,
    metadata: { "tier" => "studio", "unicode" => "Olá 👋" },
    product: Product.new(slug: PRODUCT_SLUG),
    license_plan: LicensePlan.new(mode: "hardware_locked", seat_limit: 5, key: PLAN_KEY),
    license_entitlements: [
      Entitlement.new(key: "pro", expires_at: nil),
      Entitlement.new(key: "beta-features", expires_at: Time.utc(2099, 1, 1))
    ],
    tenant: nil
  )
end

ACTIVATION = FakeActivation.new(
  id: ACTIVATION_ID,
  activated_at: Time.utc(2026, 6, 1, 9, 30, 0),
  metadata: { "device_name" => "Fixture Studio Mac", "platform" => "macos" }
)

def issue(now:, ttl_days:, grace_period_days:, ends_at:, signing_seed: SIGNING_SEED)
  Time.fixture_now = now
  service = FixtureMachineFile.new(
    signing_key_bytes: signing_seed,
    kid: KEY_ID,
    activation: ACTIVATION,
    license: build_license(ends_at: ends_at),
    fingerprint: FINGERPRINT,
    ttl_days: ttl_days,
    grace_period_days: grace_period_days,
    include_license_data: true,
    fingerprint_components: { "platform" => "macos", "platform_uuid" => "fixture-uuid" },
    sdk_version: SDK_VERSION
  )
  certificate, plaintext, signed = service.certificate
  [certificate, plaintext, signed, service]
ensure
  Time.fixture_now = nil
end

# Mirrors machine_files_controller.rb:163-180 (`render_machine_file_success`).
def api_response(certificate:, issued:, ttl_days:)
  {
    "data" => {
      "type" => "machine-files",
      "attributes" => {
        "certificate" => certificate,
        "algorithm" => LicenseSeat::Services::OfflineMachineFile::ALGORITHM,
        "ttl" => ttl_days * 24 * 60 * 60,
        "issued" => issued.iso8601,
        "expiry" => (issued + ttl_days.days).iso8601
      },
      "relationships" => {
        "license" => { "data" => { "type" => "licenses", "id" => LICENSE_KEY } },
        "machine" => { "data" => { "type" => "machines", "id" => FINGERPRINT } }
      }
    }
  }
end

cases = {}

# --- 1. valid ---------------------------------------------------------------
valid_cert, valid_plaintext, valid_signed, = issue(
  now: ISSUED_AT,
  ttl_days: LONG_TTL,
  grace_period_days: GRACE_DAYS,
  ends_at: Time.utc(2099, 1, 1)
)
cases["valid"] = {
  "description" => "Server-generated machine file, 10 year TTL, license data included.",
  "response" => api_response(certificate: valid_cert, issued: ISSUED_AT, ttl_days: LONG_TTL),
  "expected" => { "valid" => true }
}

# --- 2. expired -------------------------------------------------------------
expired_issued = ISSUED_AT - (400 * 86_400)
expired_cert, = issue(
  now: expired_issued,
  ttl_days: 30,
  grace_period_days: 0,
  ends_at: Time.utc(2099, 1, 1)
)
cases["expired"] = {
  "description" => "Issued 400 days ago with a 30 day TTL and no grace period.",
  "response" => api_response(certificate: expired_cert, issued: expired_issued, ttl_days: 30),
  "expected" => { "valid" => false, "code" => "token_expired" }
}

# --- 3. tampered signature --------------------------------------------------
# Flip one ciphertext character inside the signed `enc` string. The Ed25519
# signature covers "machine/<enc>", so this must be rejected before any
# decryption work happens.
tampered_envelope = JSON.parse(Base64.strict_decode64(valid_cert.lines[1...-1].map(&:strip).join))
tampered_enc = tampered_envelope["enc"].dup
flip_index = 5
tampered_enc[flip_index] = (tampered_enc[flip_index] == "A" ? "B" : "A")
tampered_envelope["enc"] = tampered_enc
tampered_cert = [
  "-----BEGIN MACHINE FILE-----",
  *Base64.strict_encode64(tampered_envelope.to_json).scan(/.{1,64}/),
  "-----END MACHINE FILE-----"
].join("\n")
cases["tampered_signature"] = {
  "description" => "Valid file with one ciphertext byte flipped; signature no longer covers `enc`.",
  "response" => api_response(certificate: tampered_cert, issued: ISSUED_AT, ttl_days: LONG_TTL),
  "expected" => { "valid" => false, "code" => "signature_invalid" }
}

# --- 4. tampered ciphertext, re-signed with the REAL key --------------------
# Proves the AES-GCM authentication tag is enforced on its own: the outer
# Ed25519 signature verifies, but the payload no longer authenticates.
resign_service = FixtureMachineFile.new(
  signing_key_bytes: SIGNING_SEED,
  kid: KEY_ID,
  activation: ACTIVATION,
  license: build_license(ends_at: Time.utc(2099, 1, 1)),
  fingerprint: FINGERPRINT
)
resigned_cert, = resign_service.certificate_for(tampered_enc)
cases["tampered_ciphertext_resigned"] = {
  "description" => "Ciphertext modified then re-signed with the legitimate key; GCM tag must fail.",
  "response" => api_response(certificate: resigned_cert, issued: ISSUED_AT, ttl_days: LONG_TTL),
  "expected" => { "valid" => false, "code" => "decryption_failed" }
}

# --- 5. wrong signing key ---------------------------------------------------
wrong_key_cert, = issue(
  now: ISSUED_AT,
  ttl_days: LONG_TTL,
  grace_period_days: GRACE_DAYS,
  ends_at: Time.utc(2099, 1, 1),
  signing_seed: WRONG_SIGNING_SEED
)
cases["wrong_key"] = {
  "description" => "Structurally perfect file signed by a different Ed25519 key under the same kid.",
  "response" => api_response(certificate: wrong_key_cert, issued: ISSUED_AT, ttl_days: LONG_TTL),
  "expected" => { "valid" => false, "code" => "signature_invalid" }
}

fixture = {
  "generated_by" => "Tests/LicenseSeatSDKTests/Fixtures/generate_machine_file_fixtures.rb",
  "gem" => File.basename(GEM_ROOT),
  "algorithm" => LicenseSeat::Services::OfflineMachineFile::ALGORITHM,
  "schema_version" => LicenseSeat::Services::OfflineMachineFile::SCHEMA_VERSION,
  # Standard Base64, matching the `/signing_keys/{kid}` response and the
  # public-key form every LicenseSeat SDK already accepts.
  "public_key" => Base64.strict_encode64(SIGNING_KEY.verify_key.to_bytes),
  "wrong_public_key" => Base64.strict_encode64(WRONG_KEY.verify_key.to_bytes),
  "key_id" => KEY_ID,
  "license_key" => LICENSE_KEY,
  "fingerprint" => FINGERPRINT,
  "product_slug" => PRODUCT_SLUG,
  "activation_id" => ACTIVATION_ID,
  "issued_at_unix" => ISSUED_AT.to_i,
  "expires_at_unix" => (ISSUED_AT + LONG_TTL.days).to_i,
  "grace_period_seconds" => GRACE_DAYS * 86_400,
  "cases" => cases
}

output = File.join(__dir__, "machine_file_fixtures.json")
File.write(output, "#{JSON.pretty_generate(fixture)}\n")
warn "wrote #{output} (#{cases.keys.join(', ')})"
