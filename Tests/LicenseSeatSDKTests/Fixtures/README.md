# Cross-language test fixtures

Golden artifacts produced by the LicenseSeat server's own code, so the Swift
verifiers are tested against real server output rather than against themselves.

| File | Produced by | Covers |
| --- | --- | --- |
| `ruby_signed_offline_token.json` | the Ruby offline-token signer | legacy offline tokens |
| `machine_file_fixtures.json` | `generate_machine_file_fixtures.rb` | `aes-256-gcm+ed25519` machine files |

## Regenerating the machine-file fixtures

`generate_machine_file_fixtures.rb` loads
`LicenseSeat::Services::OfflineMachineFile` from the installed `license_seat`
gem and calls its own `build_plaintext_payload`, `encrypt_payload`,
`sign_encrypted_data`, and `wrap_as_certificate` methods, so the certificate
bytes are exactly what the API issues. Only the Rails-only surface (ActiveSupport
helpers, ActiveRecord models, the DB transaction, and the tenant signing-key
provider) is stubbed; the script's header documents each stub with the gem
`file:line` it stands in for.

```sh
ruby Tests/LicenseSeatSDKTests/Fixtures/generate_machine_file_fixtures.rb
# override the gem location if it is installed elsewhere
LICENSE_SEAT_GEM_ROOT=/path/to/license_seat-0.9.2 ruby …
```

Requires the `ed25519` gem. Output is deterministic apart from the AES nonce,
and covers one valid artifact plus four that must each be rejected for a
different reason: expired, tampered signature, tampered ciphertext re-signed
with the legitimate key, and signed by the wrong key.
