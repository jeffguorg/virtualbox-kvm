# Testing

## Evidence ladder

Use the narrowest checks that exercise the change, then add broader checks when
risk crosses components:

1. Review the diff and patch ordering; inspect semantic impact even when patches
   apply cleanly.
2. Run `bash -n` on shell scripts and ShellCheck when available.
3. Exercise source initialization, patch export, and round-trip comparison with
   disposable local fixtures.
4. Configure and build the intended source configuration; run focused upstream
   or repository tests for affected code.
5. For runtime-affecting changes, perform the physical-host headless KVM smoke
   test below.

Record commands and observed results in the change report, not as snapshots in
these documents. Do not claim an unrun or inaccessible check.

## Pinned guest input

The main runtime smoke uses the approved, pinned, verified Alpine `virt` ISO.
The pin and its expected SHA-256 digest come from the approved test-run inputs,
not from a latest-release lookup. Acquire it through the approved official
channel, verify it before use, and pass the local file to the test harness:

```bash
printf '%s  %s\n' "$ALPINE_VIRT_ISO_SHA256" "$ALPINE_VIRT_ISO" | sha256sum -c -
```

Both variables must identify the same approved pin. Helper scripts do not
perform this acquisition or any other network access.

A latest Alpine `virt` ISO may be run only as optional additional comparison.
It is non-gating, must be reported separately, and must never replace the
pinned run or turn an unexpected latest-only failure into an unreviewed main
requirement.

## Physical-host headless KVM smoke

Run directly on the intended physical Linux x86 host with the newly built
VirtualBox binaries. Use a disposable VM definition and local temporary paths.
No GUI session, Guest Additions, or Hyper-V validation is involved.

### Preflight

- Confirm the host architecture, KVM device access, effective user, and expected
  VirtualBox binary paths.
- Confirm the pinned ISO checksum and keep the ISO read-only.
- Ensure the disposable VM name and output paths do not already belong to
  another VM or workload.
- Do not change host bridge, coredump, sysctl, or other persistent settings for
  the smoke test.

### Disposable VM shape

Create and register a new VM, then configure a minimal machine with:

- a suitable 64-bit Linux guest type, one or more supported vCPUs, and modest
  memory;
- DVD boot from the pinned Alpine `virt` ISO;
- no required disk installation and no Guest Additions image;
- no host networking mutation; a disconnected adapter is sufficient for the
  base KVM smoke;
- a headless console or serial logging arrangement supported by the approved
  harness so boot evidence can be captured without GUI testing.

Use `VBoxManage createvm`, `modifyvm`, `storagectl`, and `storageattach` for the
disposable definition. Start it with `VBoxHeadless --startvm`. Consult the built
tree's own command help for supported option spelling rather than copying
options from another package build.

### Acceptance evidence

- The expected built front end starts the intended VM and selects the KVM/NEM
  execution path; corroborate this in `VBox.log` rather than inferring it from a
  running process alone.
- The pinned ISO progresses through Linux boot to the expected Alpine login or
  harness-ready state without a KVM assertion, crash, or unexpected power-off.
- The guest remains operational long enough to perform the approved minimal
  console check, then shuts down cleanly through the harness.
- Logs contain no new relevant NEM/KVM failure, and any pre-existing warning is
  identified rather than ignored.

A successful process launch without guest-boot evidence is not a completed
smoke test. A run using another hypervisor, another host architecture, a GUI,
or Guest Additions does not satisfy this path.

Clean up only disposable resources created by the test, after confirming their
identity. Preserve logs needed for the report and apply the privacy rules in
`bug-triage.md` before sharing them.

## Patch workflow checks

For patch-only equivalence, run `scripts/roundtrip-patches.sh` against a vanilla
source repository and explicit reference and candidate directories. Success
requires identical `HEAD^{tree}` values and recursive no-dereference equality
of content, file types, modes, and symlinks. Inputs remain untouched and
temporary clones are removed on both success and failure.

When intentional behavior differs, a round-trip mismatch is a review signal,
not something to bypass. Inspect and explain the difference against the
approved specification.
