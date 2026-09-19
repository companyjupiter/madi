## What and why
<!-- What was wrong or missing, and what this changes. Link the issue. -->

## How it was checked
<!-- Commands you ran and their results. For performance, accuracy, latency or memory
     claims: the numbers, before and after, and what they were measured on. -->

## Checklist
- [ ] `apps/macos/scripts/make_app.sh` builds and `cd apps/macos && swift test` passes
- [ ] New `.swift` files are in the `make_app.sh` source list
- [ ] No new network call, account, or telemetry in the core path
- [ ] Third-party code or weights are named here and added to `NOTICE` / `THIRD_PARTY_LICENSES.md` (or none)
- [ ] I have read the [Contributor License Agreement](../blob/main/CLA.md) and I agree to it for this contribution
