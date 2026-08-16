# Privacy

Glide Translate is local-first, but translating necessarily sends the text you
submit to the provider you select. The provider's displayed destination class
is part of the authorization decision for every request.

## Capture and explicit actions

Manual input does not require Accessibility permission and does not read the
clipboard.

Mouse and optional keyboard automatic capture use macOS Accessibility APIs.
They are disabled by default and require all of the following: completed
onboarding, Accessibility permission, global automatic capture enabled, the
specific trigger enabled, and the source application present in the automatic
capture allowlist.

The global shortcut is an explicit action. It first attempts selection capture.
If the optional shortcut-only clipboard fallback is enabled, Glide Translate
may synthesize Command-C and read the resulting plain text from the system
pasteboard. This can replace the current pasteboard contents; the app does not
claim to restore them. The fallback refuses unsafe states such as Secure Input,
concurrent fallback work, or an unchanged/invalid pasteboard result.

## Provider destinations and transmission

Providers are classified as:

- **Local (this Mac):** a loopback, on-device destination such as the default
  Ollama configuration.
- **Local Network:** an off-device destination on the local network.
- **Cloud:** an off-device public-network destination.
- **Unresolved or changed:** a destination that cannot be safely authorized.

Local Network and Cloud configurations require an explicit destination
confirmation. Automatic capture to an off-device provider also requires
authorization for the source application. If the destination changes or
cannot be revalidated, the request stops for reconfirmation.

Authorized source text, prompt instructions, language choices, and model
request parameters are sent only to the selected provider. There is no
implicit provider fallback.

## Local storage and Keychain

Provider metadata and preferences are stored in the app's Application Support
data. Provider credentials and encryption keys are stored with macOS Keychain
services. Custom presets are encrypted at rest.

Translation history is off by default. When enabled, only completed
translations are offered to history; excluded source applications are skipped.
The encrypted record contains source text, result text, timestamp, preset,
language choices, and provider destination class. AES-GCM protects each record,
with its key stored in Keychain.

History defaults to 30-day retention and 1,000 records. Retention is validated
to 1–365 days and the maximum count to 1–10,000 records. Maintenance deletes
older/excess records. Search decrypts records locally and matches source/result
text; it is not sent to a provider.

## Logs and diagnostic export

Local unified logs contain bounded categories such as capture outcome,
provider class/health, sanitized failure, duration, history outcome, and
permission state. They do not intentionally include selected text, prompts,
responses, source application identifiers, window titles, endpoints, model
names, credentials, or stack traces.

Diagnostic export is user initiated. The app first previews a category-only
JSON report, then asks for a save destination. It includes schema/app version,
OS major version, architecture category, permission category, default provider
class, component health categories, and recent outcome counts. It excludes
content, identifiers, endpoints/models, credentials, log extracts, local
paths, user/device names, stack traces, and the exact OS build.

Glide Translate contains no analytics/telemetry service and performs no
automatic update checks. Network traffic is limited to provider operations the
user configures and authorizes.

## Reset and deletion limits

The in-app privacy reset pauses capture, cancels/drains translation work,
closes storage, deletes history and its key, deletes encrypted custom presets
and their key, deletes provider metadata and credentials, resets preferences,
clears runtime caches, and unregisters launch-at-login and the shortcut. A
partial failure is reported by stage and can be retried; completion is not
claimed while a stage remains failed.

Keychain items can outlive deletion of ordinary app files. Use the in-app reset
before removing the app when you want it to attempt deletion of its Keychain
credentials and keys.

## Limitations

Accessibility behavior varies by source application and selected control.
Secure Input and unsupported accessibility trees can prevent capture. The
application compatibility matrix is still awaiting manual validation; no
universal capture compatibility is claimed. See
[Compatibility](docs/compatibility.md).
