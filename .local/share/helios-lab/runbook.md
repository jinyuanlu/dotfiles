# Helios lab runbook

The hands-on part of the lab: read RFD 26, run DTrace, walk stacks with MDB.
Nothing here is scripted. You type it, read what comes back, and change it.

- **Where:** in the guest. `helios-lab ssh` logs you in as `ubuntu`. Root
  comes through `pfexec`.
- **When:** after `helios-lab up` has printed `guest ready`. `helios-lab
  status` tells you whether the host is running.
- **Ending a command:** an aggregation (`@...`) prints when you press Ctrl-C.
  `tick-Ns { exit(0); }` ends it on its own.

`$ ` marks a guest prompt. A Mac prompt is labelled `(Mac)`.

---

## 0. RFD 26, while the seed downloads

The first `helios-lab up` spends about 5 minutes on its `seed` stage, a 2.4 GB
download, verify and unpack of the Helios image. It prints the link when that
stage starts. Read it then:

**RFD 26, "Host Operating System & Hypervisor":**
<https://rfd.shared.oxide.computer/rfd/0026>

The host is `rfd.shared.oxide.computer`. `rfds.oxide.computer` does not
resolve.

Read it for the criteria Oxide weighed in choosing a host OS and hypervisor.
Note which of them steps 1 and 2 let you check for yourself on a live system.

---

## 1. DTrace: five one-liners

DTrace needs privilege, so every one-liner runs under `pfexec`. All five
come verbatim from Brendan Gregg's collection (references below).

Start by checking that DTrace answers. This check ends by itself after
3 seconds:

```sh
$ pfexec dtrace -q -n 'syscall:::entry { @[execname] = count(); } tick-3s { exit(0); }'
```

On the spike's guest (`helios-3.0.23976`) it printed one line per process
name with its system-call count. The ready screen suggests the same probe
without `-q` and the timer, ended by Ctrl-C:

```sh
$ pfexec dtrace -n 'syscall:::entry { @[execname] = count(); }'
```

### 1.1 System calls by process

```sh
$ pfexec dtrace -n 'syscall:::entry { @num[pid,execname] = count(); }'
```

**What to look for:** on Ctrl-C, one row per process (PID, name, count),
sorted with the busiest last. On an idle guest, expect your own session's
`sshd` and `dtrace` itself among the busiest. To see a row climb, run
something in a second `helios-lab ssh`.

### 1.2 New processes, with their arguments

```sh
$ pfexec dtrace -n 'proc:::exec-success { trace(curpsinfo->pr_psargs); }'
```

**What to look for:** one line per successful `exec`, as it happens. Each line
shows the CPU, the probe and the new process's command line. Run `ls /` or
`uname -a` in a second session and watch them appear. `pr_psargs` holds
at most 80 characters, so long command lines are cut off.

### 1.3 Files opened, by process

```sh
$ pfexec dtrace -n 'syscall::open*:entry { printf("%s %s",execname,copyinstr(arg0)); }'
```

**What to look for:** one line per open, naming the process and the path.

**Caveat: `open*` versus `openat`.** On current illumos, libc implements
`open(2)` on top of `openat(2)`. The system call the probe sees is then
`openat` or `openat64`. Its first argument (`arg0`) is a directory
descriptor, usually `AT_FDCWD`, not a path, and its second (`arg1`) is the
path. So the one-liner above may print `invalid address` errors instead of
paths. First list which probes the wildcard matches:

```sh
$ pfexec dtrace -ln 'syscall::open*:entry'
```

If they are only `openat` and `openat64`, trace the path in `arg1`:

```sh
$ pfexec dtrace -n 'syscall::openat*:entry { printf("%s %s", execname, copyinstr(arg1)); }'
```

### 1.4 User stacks of one process, sampled at 99 Hz

```sh
$ pfexec dtrace -n 'profile-99 /pid == 189 && arg1/ { @[ustack()] = count(); }'
```

`189` is only the example's PID. Put a real one in its place, from `pgrep`:

```sh
$ pgrep -n sshd                      # the newest sshd: your own session
$ sh -c 'while :; do :; done' &      # or a process that is always on CPU
$ echo $!                            # its PID; kill it when done
```

`arg1` is the user-mode program counter. It is non-zero only when the sample
caught the process in user code, so kernel time is left out.

**What to look for:** on Ctrl-C, the distinct user stacks with how often each
was sampled, the hottest last. The busy loop gives a few stacks inside the
shell's interpreter, with large counts. A sleeping process gives few samples
or none, because it is rarely on CPU.

### 1.5 Kernel stacks, all CPUs, for 60 seconds, to a file

```sh
$ pfexec dtrace -x stackframes=100 -n 'profile-199 /arg0/ { @[stack()] = count(); } tick-60s { exit(0); }' -o out.stacks
```

This samples kernel stacks at 199 Hz on every CPU (`arg0` is the kernel
program counter, non-zero only in the kernel). It keeps up to 100 frames, ends
after 60 s and writes `out.stacks` in the current directory.

**What to look for:** `out.stacks` lists each distinct kernel stack with its
sample count. An idle guest is mostly the idle loop. Run a load (the busy loop
from 1.4, or `find / > /dev/null 2>&1`) during the 60 s to see real work. This is
the input to a CPU flame graph (Gregg's `stackcollapse.pl` and
`flamegraph.pl`). To get the file onto the Mac:

```sh
(Mac) helios-lab ssh guest cat out.stacks > out.stacks
```

### Adapting a one-liner to a single PID

Add a `$target` predicate and attach with `-p`:

```sh
$ pfexec dtrace -n 'syscall:::entry /pid == $target/ { @[probefunc] = count(); }' -p PID
```

This counts that one process's system calls by name. DTrace exits when the
process does, or on Ctrl-C. `-c 'command'` in place of `-p PID` starts the
command and traces it from the start.

---

## 2. MDB: walk a process's stacks

### 2.1 A user process

Make a process that sits still, then print its stack. This needs no
privilege for your own processes:

```sh
$ sleep 600 &
$ echo ::stack | mdb -p $!
```

On the spike's guest this printed a stack through libc's `__nanosleep`,
`main`, `_start_crt` and `_start`: a process asleep in `nanosleep(3C)`.

Interactively:

```sh
$ mdb -p <pid>
> ::stack          # the stack backtrace, innermost frame first
> $C               # the same walk, with each frame's frame pointer
> $q               # detach; the process continues
```

While MDB is attached the process is stopped. `mdb -o nostop -p <pid>`
attaches without stopping it, so the stack may change under you.
Cross-check with `pstack`, which reads the stack through `/proc`:

```sh
$ pstack <pid>
```

### 2.2 Kernel threads

`mdb -k` opens the live kernel. It needs `pfexec`, and it is read-only
unless you add `-w`. Don't add it.

Every kernel thread of every `sshd`, each with its stack and arguments:

```sh
$ echo '::pgrep sshd | ::walk thread | ::findstack -v' | pfexec mdb -k
```

On the spike's guest each thread read `swtch`, `cv_wait_sig_swap_core`,
`poll_common`, `pollsys`: an `sshd` asleep in `poll(2)`, waiting for input.

Then widen the view:

```sh
$ echo ::stacks | pfexec mdb -k                 # every kernel thread, grouped by identical stack, with counts
$ echo '::stacks -c pollsys' | pfexec mdb -k    # only the stacks that pass through pollsys
$ echo '::ps -f' | pfexec mdb -k                # the kernel's process table, with full arguments
```

Compare `::stacks` against what 1.5 sampled. `::stacks` shows where threads
*wait*; the profile shows where CPUs *run*.

---

## 3. Long runs and the idle stop

The host stops itself after `HELIOS_LAB_IDLE_MINUTES` (default 60) with no
SSH session. It stops; it never terminates. The guest shuts down with it, so
**work left running in a disconnected session ends**: a `nohup` build, a
long `dtrace -o` capture, an `mdb` session.

Before you disconnect from something long:

```sh
(Mac) helios-lab keep 3h      # at most 12h
(Mac) helios-lab keep off     # back to the idle rule
(Mac) helios-lab status       # shows when the host will stop
```

Every open session counts as activity, whether it is `helios-lab ssh` to the
guest or the host, or `helios-lab console`. A session whose Mac went to sleep
stops counting within about 3 minutes. After a stop, `helios-lab up` restarts
in about 40 seconds with the guest intact.

---

## 4. References

- illumos Dynamic Tracing Guide: <https://illumos.org/books/dtrace/>
- illumos Modular Debugger Guide: <https://illumos.org/books/mdb/>
- `mdb(1)`: <https://illumos.org/man/1/mdb>
- Helios: <https://github.com/oxidecomputer/helios>
- helios-engvm, which builds this guest: <https://github.com/oxidecomputer/helios-engvm>
- Brendan Gregg's DTrace one-liners: <https://www.brendangregg.com/DTrace/dtrace_oneliners.txt>
  (with <https://www.brendangregg.com/dtrace.html> and
  <https://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html>)
- RFD 26: <https://rfd.shared.oxide.computer/rfd/0026>

---

## 5. What this unblocks

Once Helios boots, DTrace and MDB have run on the live system and RFD 26 has
been read, the illumos driver deep-read and the illumos build have a system
to work on.

**Resize before the build.** The guest is 3 vCPU, 8 GiB and a 60G disk on an
m8i.xlarge host (4 vCPU, 16 GiB). That is enough for tracing, but small for
building illumos. Nothing resizes in place yet:

- The host type applies only at create, and the policy withholds the
  permission to change a stopped instance's type.
- The guest's sizing (`host/engvm-lab.sh`) applies only to a newly created
  guest. A verified guest is never recreated; `status` reports the mismatch.

So today a bigger lab means starting over, and the guest disk is lost:

```sh
(Mac) helios-lab destroy                  # preview
(Mac) helios-lab destroy --yes
(Mac) HELIOS_LAB_INSTANCE_TYPE=m8i.2xlarge helios-lab up    # ≈$0.55/hr running
```

`helios-lab resize` is planned follow-up work.
