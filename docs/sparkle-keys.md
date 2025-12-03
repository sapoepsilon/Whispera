# Sparkle Signing Keys

## Current Setup

- Public key: In `Info.plist` under `SUPublicEDKey`
- Private key: GitHub Secret `SPARKLE_PRIVATE_KEY`

## Regenerate Keys

If keys are compromised or need rotation:

```bash
# Generate new keypair (saves to macOS Keychain)
./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys

# Export private key
./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_key.txt

# Update GitHub secret
gh secret set SPARKLE_PRIVATE_KEY < sparkle_key.txt

# Delete local key file
rm sparkle_key.txt
```

Then update `SUPublicEDKey` in `Info.plist` with the new public key shown in terminal.

## View Existing Public Key

```bash
./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

## Notes

- Private key is also stored in macOS Keychain under "Sparkle Private Key"
- Users with old app versions will still auto-update (Sparkle handles key transitions)
- Never commit the private key to the repository
