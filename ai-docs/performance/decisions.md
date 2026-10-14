# Decisions log

Newest last. "User" means the repository owner. "Agent" means the reviewing
agent, deciding within the scope the user set.

## 2026-10-14

**Scope (user).** Analyse and optimise rules_dart and rules_flutter for
performance on large monorepos. A separate cloud agent works on rules_dart. This
review works on rules_flutter. Haiku agents do the code and verification work.

**No double work (user).** The two reviews coordinate through their `ai-docs/`
folders and direct messages to the cloud session. rules_flutter's needs from
rules_dart go in `asks-for-rules-dart.md`.

**Phase 0 first (user).** e2e against rules_dart `main`, then a Flutter
benchmark with a recorded baseline, before any optimisation lands.

**Reuse rules_dart's harness (agent).** Same scenarios and result shape, so
numbers from the two reviews can be read side by side. The harness stays a
set of reference scripts in `ai-docs/`, as rules_dart's does, not repository
tooling.

**Bazel 9.3.0 is housekeeping, not a performance item (agent).** It passes the
root suite but needs every lockfile refreshed. Its changes help remote and disk
caches, not these rules. Bump it in step with rules_dart when the user
schedules it. 10.0.0rc1 is parked until 10.0 final.

**Toolchain shape (open, user to decide).** The user asked why rules_flutter
has its own toolchain rather than using and extending rules_dart's.
`findings.md` "Two Dart SDKs in every Flutter workspace" has the facts. The
agent recommends plan item T:

- Flutter's bundled Dart becomes a rules_dart `dart_toolchain`, so every
  Flutter workspace has one Dart.
- A Flutter toolchain remains, but only for the engine artifacts. Those vary by
  target platform and are Flutter's, so they don't belong in `DartSdkInfo`.
