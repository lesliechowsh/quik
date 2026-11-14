# Quik engineering rules

## Use proven solutions

If the same task fails three times, stop and search before trying again. Prefer, in order: an Apple system API or command, a stable open-source library, then your own implementation. Do not ship a hand-rolled subset of something that already exists.

Write down why the existing option was rejected when you do implement it yourself.

## Verify against the real artifact

Build, launch, and inspect the running app. A compile pass is not a verification. The checks live in `scripts/ui-check.sh` and `scripts/verify-experience.sh`; rerun them after UI or metric changes.

## Measure, then claim

Every performance number in docs or UI needs its measurement method and its limiting factor. See `docs/metric-validation.md`.
