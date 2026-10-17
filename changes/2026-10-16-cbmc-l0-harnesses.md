- **CBMC harnesses for the rest of the pure L0 platform layer (ADR-0053 M7).** `runtime/platform/tests/cbmc_l0_harness.c`
  adds bounded harnesses for `double_to_exp`, `parse_double`, `now_millis`, `monotonic_millis`, `error_message`, `init` /
  `arg` / `arg_count`, `policy_load`, `path_absolute`, and the handle validation (generation, liveness) of monitors and
  threads as a bounded state machine (the table logic, not the interleavings); `tools/verify_platform.sh` runs them with
  the existing ones (`REQUIRE_CBMC=1` stays on in CI).
