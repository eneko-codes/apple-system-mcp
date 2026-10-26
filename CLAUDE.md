# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete, and nothing is configured. Everything it reads is live state of the machine it runs on: which programs are running, who owns them, what they have open, where they listen, how they are invoked.

**Tests run against fakes** — `FakeSystemSource`, an in-memory machine with invented processes, paths and addresses. Never the owner's real process table, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**One suite is the stated exception, and it is narrow.** `DarwinSelfTests` calls the real system because a fake cannot catch a wrong unit, a mis-decoded struct or a miscounted buffer. It reads only (a) the test process itself — its own CPU time, identity, arguments and the sockets it opens — and (b) machine-wide totals that carry no names, paths or contents: core count, memory page counts, boot time, load. It must never list another process, read another process's sockets or arguments, or read a volume's name. A test that does is not allowed in that suite or anywhere else.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question. Be specific about what each tool reveals: `system_processes` names and owners every running program; `system_connections` names the programs listening on ports; `system_process` with `include_arguments` returns command lines.

**There is no temp-directory fixture for this API.** The data lives in the kernel, not in files, so `$TMPDIR` does not help; a double is the only fixture, and the ask is the only route to the real thing. This server only reads, so the one question is ever whether to read the owner's real machine state — but it is still a question, and still theirs to answer.

## What this is

A local MCP server (Swift 6, stdio transport) that reads the state of a Mac: processes, CPU, memory, network interfaces, mounted volumes and open sockets, through libproc, sysctl, Mach, `getifaddrs` and `getfsstat`. No Apple events, no helper programs, no shell, no network, no write of any kind, no user configuration.

## System interfaces

Apple publishes no online reference for libproc or the Mach host calls; their contract is the public SDK header (`$(xcrun --show-sdk-path)/usr/include`). The BSD calls have manual pages, archived [here](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/). The full index, with the symbols used and where each is declared, is in `README.md`.

## Native surface not used

Grounded in the SDK headers and in `sysctl` run on this machine, not in recollection.

- **`task_for_pid` / `task_info` on other processes.** Not probed here; except for the caller's own process they are expected to need root or debugging entitlements, and libproc returns the same figures without them.
- **Anything that stops or changes a process**: `kill`, `setpriority`, and the `proc_terminate*`, `proc_signal_*`, `proc_set_dirty`/`proc_clear_dirty`/`proc_track_dirty`, `proc_setpcontrol`, `proc_set_no_smt`, `proc_set_csm` family declared in `libproc.h` (public header, no documentation). The server is read-only by design.
- **The process environment.** `KERN_PROCARGS2` returns it after the arguments; `ProcessArguments.parse` stops at `argc` and never decodes it, because that is where tokens usually live.
- **Open-file paths** (`PROC_PIDFDVNODEPATHINFO`), **thread lists** (`PROC_PIDLISTTHREADS`, `PROC_PIDTHREADINFO`) and **memory regions** (`PROC_PIDREGIONINFO`): readable, left out as not worth the privacy cost or the surface. Only the descriptor *count* is reported.
- **Per-process network traffic.** No public function offers it; the only source found is a command-line tool, not a C interface.
- **CPU frequency and thermal state.** `hw.cpufrequency` is empty on Apple silicon and `kern.thermalstate` does not exist. `ProcessInfo.thermalState` would answer the latter; it is not used.
- **IOKit** (battery, power assertions, sensors) and **GPU and energy figures.** Out of scope for this server.
- **32-bit interface counters** from `getifaddrs` (`ifa_data` points at an `if_data` whose `ifi_ibytes` is `u_int32_t`). Interface totals come from `NET_RT_IFLIST2` and `if_data64` instead.
- **`host_statistics` with `HOST_VM_INFO`** (32-bit counters); `host_statistics64` is used.
- **`statfs64`, `fstatfs64`, `getfsstat64`, `getmntinfo64`**: deprecated since macOS 10.6 in `sys/mount.h`.
- **`MNT_WAIT` on `getfsstat`**: it can hang on a network volume that has stopped answering; `MNT_NOWAIT` is used.

## Facts easy to get wrong

- **libproc CPU times are Mach ticks**, not nanoseconds (`pti_total_user`, `ri_user_time`). On Apple silicon the ratio is 125/3. `SystemCalls.nanoseconds(fromMachTicks:)` converts; `DarwinSelfTests` fails if it stops doing so.
- **`proc_listallpids` and `proc_listchildpids` return a count of pids**, while the buffer size argument is in bytes.
- **Per-core scheduler ticks are 32 bits and wrap**, each core on its own. `Metrics` differences every core separately before adding.
- **A socket port is stored in network byte order in the low 16 bits of an `int`.**
- **Without root, only same-user processes answer** `PROC_PIDTBSDINFO`, `PROC_PIDTASKINFO`, `proc_pid_rusage`, `PROC_PIDLISTFDS` and `KERN_PROCARGS2`. `PROC_PIDT_SHORTBSDINFO` and `proc_pidpath` answer for every process. Tools show `n/a` for the rest and must say how many rows are affected.

## Commands

```bash
swift build
swift build -c release
swift test
./scripts/pack.sh
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary holds any other architecture. A universal build doubles the bundle for an architecture macOS 26 is the last release to support. Do not add an x86_64 slice back.

`SystemSource` is the only door to the machine. `DarwinSystemSource` implements it over the C interfaces; tests implement it with `FakeSystemSource`. Tools take two readings through the source and compute rates in `Metrics`, which is pure.

## Release checklist

- **Bump the version before packing.** The installer keys on the manifest `version` alone; an unchanged version under a changed build makes it offer only "Uninstall", which removes the extension.
- **Three files carry the version and must agree**: `extension/manifest.json`, `SystemMCPServer.version` in `Server.swift`, and `CFBundleShortVersionString` in `Resources/Info.plist`. `VersionTests` and `pack.sh` both check it.
- **Installing does not restart the server.** The old process keeps answering until Claude Desktop is fully quit and reopened. Check `ps` and the binary path before trusting a result.
- **Ad-hoc signing changes the code identity on every rebuild.** Expected, not a fault.
- **The text the model reads is code.** Update the server `instructions`, tool and argument descriptions and the manifest `tools` and `long_description` in the same commit as the behaviour. None of it takes effect until the client restarts. A shipped string never names another server; `CatalogueTests` greps for `-mcp`.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription`, a pid or a process name; log a fixed event, the tool name, the error's kind and a duration.
