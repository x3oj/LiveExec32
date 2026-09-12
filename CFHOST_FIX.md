# CFHost socket stream compatibility fix

This change adds `CFStreamCreatePairWithSocketToCFHost` to the guest CFNetwork
framework. It addresses the missing-symbol error reported for the legacy
`robloxmobile` executable in LiveContainer.

The guest wrapper forwards the native CFHost identity and signed 32-bit port.
The host dispatcher creates native streams, converts the Create-rule results
into owned guest proxies, and writes 32-bit output pointers. Both the guest
CFNetwork framework and native LiveExec32Shared framework must be rebuilt.

The regression test covers name-based and address-based hosts, optional read
and write outputs, adjacent-memory canaries, object lifetime, unopened stream
status, and defensive handling of invalid outputs. The existing export audit
also checks the new symbol.

## Build

Pushing this branch runs **Build LiveExec32 CFHost fix**. Its workflow is
[build-liveexec32-cfhost.yml](.github/workflows/build-liveexec32-cfhost.yml).
It uses a macOS runner to build the guest frameworks, audit exports, check
native stream behavior, run the ARM32 test through a Catalyst build, and then
rebuild and package the iOS IPA. The workflow verifies that the missing export
is present in the IPA before uploading **LiveExec32-CFHost-fixed**, containing
the IPA and `SHA256SUMS.txt`.

This workflow checks out this repository's actual build commit. The original
upstream nightly workflow is unchanged and does not run on this feature branch.

## Validation before the first Actions run

ARMv7s syntax/type checks passed against the pinned iOS 10.3 SDK. The regression
source passes `-Wall -Wextra -Werror`. The guest CFNetwork translation unit has
the same four pre-existing nonnull warnings as the upstream source and no new
diagnostics. The patch applies cleanly to base commit
`3f0390e1b2725a2d3c9ab6f3976650a5a295ffba`.

The local Linux environment cannot run the required macOS/Catalyst build. Until
the Actions run succeeds, native compilation, runtime tests, and IPA packaging
remain unverified. The Roblox/Hexagon app and the user's iPhone have not been
tested, so this change does not establish compatibility with the entire app.
