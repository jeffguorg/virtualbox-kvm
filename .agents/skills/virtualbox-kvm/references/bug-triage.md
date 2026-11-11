# Bug triage

## Boundaries and privacy

Diagnose the physical-host Linux x86 KVM path. Do not expand the investigation
into Hyper-V, GUI, or Guest Additions testing. Preserve GUI integration while
reading or changing shared code.

Read-only collection is the default. Starting or stopping a VM, modifying its
configuration, changing sysctl values, altering shell limits, installing
packages, enabling debuginfod, or changing coredump handlers requires explicit
approval. Use existing artifacts before requesting a reproduction.

Logs and core files can contain hostnames, user names, VM names, UUIDs, device
paths, IP and MAC addresses, command lines, credentials, guest memory, and disk
contents. Collect the minimum necessary, keep artifacts local, redact before
sharing, and never upload a core or log merely because it was requested in a
template. Ask before disclosure and describe the redactions.

## Establish the environment

Record facts without changing them:

- Architecture, kernel, distribution, package build, exact VirtualBox command,
  and whether execution is directly on the physical host.
- CPU virtualization and relevant feature flags, `/dev/kvm` ownership and
  permissions, loaded KVM modules, and effective user/group identity.
- Kernel command line and split-lock mitigation state when relevant to the
  failure.
- VM configuration, storage and network attachment types, and whether the same
  configuration previously worked with the same package build.
- Other active virtualization users only as environmental evidence; do not
  reconfigure or stop them during read-only triage.

Useful read-only sources include `uname`, `lscpu`, `/proc/cmdline`,
`/proc/cpuinfo`, `/dev/kvm`, `lsmod`, `VBoxManage showvminfo`, and the system
journal. A permission error is itself evidence; do not bypass it with a host
configuration change.

## Collect and correlate logs

Start with the affected VM's `Logs/VBox.log`, rotated VM logs, front-end stderr,
and `VBoxSVC` logs. Add kernel and service-journal records only for the relevant
interval. Preserve original timestamps and identify the clock or timezone when
correlating sources.

Look for the selected execution backend, NEM/KVM initialization, VM-exit and
interrupt errors, assertion or signal information, device attachment failures,
and the first transition from normal operation to failure. Distinguish the first
causal error from later shutdown noise. Do not treat a matching error string as
proof of the same root cause without the surrounding sequence.

## Coredump settings and files

Inspect rather than modify:

- `/proc/sys/kernel/core_pattern`, the crashing process's core-size limit, its
  working directory, and service-specific core limits.
- Existing files named by the configured core handler or pattern.
- `coredumpctl list` and `coredumpctl info` where systemd-coredump is in use.
- Package or service journals that explain why a dump was truncated, rejected,
  or written elsewhere.

A relative `core_pattern` is interpreted using process and handler semantics,
not assumed to be relative to the repository. A piped pattern names a handler,
not an ordinary core-file directory. If no dump exists, report the observed
limit and handler configuration; do not enable dumping globally as a triage
shortcut. Any approved reproduction limit should be scoped to a disposable
subprocess rather than persisted.

## Match binaries and debug symbols

Before trusting a backtrace, associate the core with the exact executable and
libraries from the crashing package build. Record executable paths, package or
build identity, and ELF build IDs with tools such as `file`, `readelf -n`, or
`coredumpctl info`. Debug symbols must match those build IDs; similarly named
or same-version binaries are not sufficient evidence.

Use local matching symbols and a local debugger for stack inspection. Do not
enable network symbol downloads without approval. Mark frames as unresolved
when symbols are absent or mismatched, and do not infer a source-level fix from
an unreliable backtrace. Treat debugger output from a core as sensitive in the
same way as the core itself.

## Report

Separate:

1. **Observed facts** with paths, command output, and build identifiers.
2. **Working hypothesis** and the evidence for and against it.
3. **Minimal next observation** that would discriminate between explanations.
4. **Reproduction or fix proposal**, which requires its own approval and test
   scope.

Do not claim a fix from a clean rebuild, a disappearing crash with unmatched
symbols, or a successful run on a different backend.
