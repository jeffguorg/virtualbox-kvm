---
name: virtualbox-kvm
description: Maintain and diagnose the physical-host Linux x86 KVM path of this VirtualBox patch repository, including read-only bug triage, source upgrades, approved feature work, patch round trips, and pinned-ISO headless smoke testing.
---

# VirtualBox KVM workflow

Use this skill for work in this repository. The supported main path is a
physical Linux x86 host running VirtualBox's KVM backend. Do not present
Hyper-V, GUI, or Guest Additions validation as performed or required. Existing
GUI integration code remains in scope for preservation even though GUI testing
is excluded.

## Route the request

| Request | Required reference | Primary result |
| --- | --- | --- |
| Crash, boot failure, regression, or unexpected behavior | `references/bug-triage.md` | Privacy-conscious, read-only diagnosis with matched evidence |
| New upstream source or patch-base migration | `references/upgrade.md` | Fresh baseline, classified conflicts, semantic review, equivalence evidence |
| New behavior or changed contract | `references/feature.md` | Approved specification, explicit decisions, scoped implementation |
| Build or runtime validation | `references/testing.md` | Relevant checks plus the pinned headless KVM smoke path |

Read more than one reference when a request crosses boundaries. For example, an
upgrade that changes behavior also needs the feature decision process, and a
runtime fix needs both triage and testing.

## Stable handoff rules

1. Establish the approved goal and scope before editing. Investigation is
   read-only by default.
2. Keep root `patches/` canonical and packaging patch entries as symlinks.
   Package version and source selection belong to `packaging/arch/PKGBUILD`.
3. Build source baselines with `scripts/init-source.sh`; export local work to a
   new or empty staging directory with `scripts/export-patches.sh`.
4. Use `scripts/roundtrip-patches.sh` to compare reference and candidate patch
   sets. Successful application alone is insufficient.
5. Follow `references/testing.md` for runtime evidence. The main smoke test is
   headless and uses the approved, pinned, verified Alpine `virt` ISO. A latest
   ISO may add optional, non-gating information but cannot replace the pin.
6. Report facts separately from hypotheses. State exact commands and files,
   unrun checks, privacy limitations, decisions, and blockers.

The scripts never acquire sources or patches from the network. Obtain and
verify official inputs through the approved acquisition process first, then
pass local paths to the scripts.
