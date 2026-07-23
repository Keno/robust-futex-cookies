# libc impact of the retained FUTEX_WAITERS|0 futex word

The retained state (owner portion 0, FUTEX_WAITERS set, OWNER_DIED clear)
is created only by a FUTEX_ROBUST_UNLOCK on a >= 7.2 kernel with the
retention patch, i.e. only when at least one participant of a (pshared)
robust mutex uses the new unlock ABI. Deployments where every participant
runs a legacy libc never see it. It is the cleanly-released sibling of the
long-standing post-death state OWNER_DIED|FUTEX_WAITERS|0, which every
libc already handles.

Verified against glibc HEAD source + glibc 2.31 binary (glibc_waiters0.c)
and musl HEAD source + musl 1.2.2 binary (musl_waiters0.c):

## glibc (all robust-capable versions, 2.5..HEAD): treats it as LOCKED
- The robust lock loop acquires only from literal 0 ("if (oldval == 0)
  CAS(0 -> id|assume)"); WAITERS|0 falls through every branch (not
  OWNER_DIED, TID mismatch, WAITERS already set) into
  futex_wait(word, 0x80000000), which matches -> sleeps forever.
- pthread_mutex_lock: HANGS (verified: child still blocked after 2s).
  As a kernel-queued sleeper it also CONSUMES a wake and re-sleeps if the
  word is still WAITERS-only when woken, stranding waiters behind it.
- pthread_mutex_trylock: EBUSY on a free mutex (verified).
- pthread_mutex_timedlock: ETIMEDOUT on a free mutex (verified).
- pthread_cond_wait re-acquire: same loop (NO_INCR build) -> hangs.
- Robust PI mutexes: unaffected (kernel-arbitrated; retention never
  creates the state for PI).

## musl (robust support .. HEAD): acquires it, misreports owner death
- trylock keys on the TID portion (own = old & 0x3fffffff); own == 0 on a
  robust mutex proceeds to acquire, preserving contention via the
  _m_waiters counter (tid |= 0x80000000 when counter nonzero), so the
  wake chain survives. No hang, no strand (verified).
- But "if (old) return EOWNERDEAD": the clean retained state is reported
  as a dead owner (verified: "Previous owner died"), and the mandatory
  pthread_mutex_consistent() then fails with EINVAL because the word
  never carried OWNER_DIED (verified). No ENOTRECOVERABLE poisoning
  (unlock poisons only when OWNER_DIED is still set - verified in
  source). One-line fix: report EOWNERDEAD only when old & 0x40000000.

## bionic
No robust mutex support at all (0 matches for "robust" in
libc/bionic/pthread_mutex.cpp) - out of scope.

## ABI versioning channels
- pthread_mutex_t sharing across libc *implementations* was never
  possible (layouts differ); the compat question is same libc, different
  versions, via pshared mutexes.
- glibc HAS a fail-loud channel: kind bits 4 and 8 are unused inside the
  `__kind & 127` type mask and every dispatch switch (lock, trylock,
  timedlock, unlock) ends in "default: return EINVAL". Verified on 2.31:
  kind|=8 and kind|=4 make lock/trylock fail EINVAL. Bits >= 256
  (elision-style, outside the mask) are silently ignored (verified:
  kind|=1024 locks fine with old semantics) and are therefore NOT usable
  for negotiation. So a new-protocol opt-in flag in bit 4 or 8, set at
  init time by a new mutexattr, makes every old glibc since robust
  support refuse the object loudly instead of hanging. (Only as loud as
  the app's error checking - but robust apps must check returns anyway.)
- glibc precedent for the alternative: the 2.25 condvar rewrite broke
  cross-version pshared condvars outright; pshared across glibc versions
  is best-effort. A flag day is not unprecedented, but silent hangs are
  worse than the EINVAL-style breaks glibc has shipped before.
- Recommended staging: (1) tolerance first - treat TID-portion-0 as free,
  preserving FUTEX_WAITERS (musl minus the EOWNERDEAD misreport; a
  no-op until retention kernels + emitters exist, safe to backport);
  (2) emission later - use FUTEX_ROBUST_UNLOCK by default only for
  process-private robust mutexes (single libc by construction), and for
  pshared only under the new kind-bit opt-in; (3) possibly flip the
  pshared default once tolerant libcs are ubiquitous.
- musl has no in-object version channel (no kind validation anywhere);
  its story is the tolerance fix plus release notes.
- Kernel coupling: userspace can probe FUTEX_ROBUST_UNLOCK existence
  (vDSO symbol / ENOSYS) but cannot distinguish store-0 from retention
  semantics at runtime. Retention must therefore ship in the same
  release that first ships FUTEX_ROBUST_UNLOCK (7.2), keeping
  "flag exists => retention exists" an invariant libcs can rely on.
- Rejected alternative: retaining OWNER_DIED|FUTEX_WAITERS instead would
  avoid the glibc hang (old glibc takes the dead-owner takeover path,
  preserving WAITERS) but converts every contended unlock into an
  apparent owner death: spurious EOWNERDEAD recovery on clean state, and
  apps legitimately responding "unrecoverable" (unlock without
  consistent) poison the mutex to ENOTRECOVERABLE for all participants.

## musl: no _m_type version channel, but a lock-word sentinel

Complete _m_type consumer inventory (all robust-capable versions): C11
mtx_* compare == PTHREAD_MUTEX_NORMAL; everything else is mask tests
(&15, &3, &4, &8, &12, &128, &(8|128)) plus `_m_type > 128` in destroy
(only adds __vm_wait). Validation happens only at the attr level
(settype rejects >2, setrobust probes the kernel); init copies
attr->__attr verbatim and no object-level check exists. Unknown bits
are invisible to every deployed musl: usable as a marker for new musl,
never as a gate for old musl.

The one universal fail-loud path is in the word, not the type:
TID portion 0x3fffffff -> ENOTRECOVERABLE from every robust
lock/trylock/timedlock (checked above the EBUSY test in
trylock_owner), EPERM from unlock, EPERM/EINVAL from consistent - and
the sentinel is kernel-inert (0x3fffffff exceeds PID_MAX_LIMIT). A v2
object format could park the legacy word at the sentinel permanently
and keep the real futex word elsewhere: 64-bit musl has spare space
(__u.__i[3]/__i[4]); 32-bit would have to overlay _m_count (dead for
non-recursive kinds). The blocker is classic robust-list addressing:
robust_list_head.futex_offset is one global offset per list, so old-
and new-format objects cannot coexist on one thread's list - a
relocated word requires per-entry addressing or a second list, i.e.
the robust_list_head2 territory of the cookie series. Practical musl
story remains: one-line tolerance fix (EOWNERDEAD keyed on the
OWNER_DIED bit), backportable; its legacy failure mode is mild enough
that a loud gate is not required the way it is for glibc.

## ABI history: both libcs already assume same-version sharers

glibc events (verified at release tags):
- 2.4->2.5 (2006): kind value 16 re-pointed from a userspace-list,
  private-only robust mechanism (ROBUST_PRIVATE_*) to the kernel robust
  list protocol (ROBUST_NORMAL_*). Same enum value, new mechanism -
  sound only because 2.4 robust objects could not be process-shared.
- 2.7 (2007): PTHREAD_MUTEX_PSHARED_BIT=128 stuffed into __kind and the
  `& 127` TYPE mask introduced together with private futexes. Two-way
  pshared flag-day: <=2.6 (full-kind switch) hits default:EINVAL on any
  >=2.7-initialized pshared mutex (loud); >=2.7 treats <=2.6-initialized
  pshared mutexes (no bit 128) as PRIVATE futexes, so cross-process
  waits/wakes silently stop pairing (hangs).
- 2.18 (2013): elision bits 256/512 written into the shared __kind at
  runtime on first lock (force-elision.h) - deliberately outside &127 so
  old versions ignore them; the write was a plain (racy) store until the
  BZ#23861 atomics conversion in 2.28.
- 2.25 (2017), BZ#20985: the x86 assembly robust unlock had set the
  futex word to FUTEX_WAITERS|0 as an intermediate state since 2.5; a
  kill in the window made it permanent, the kernel would not flag
  OWNER_DIED ("0 is not equal to the TID"), and glibc's own lock paths
  could not acquire the state. Fixed by REMOVING THE PRODUCER only -
  the consumer-side hang exists to this day (verified empirically
  above). Exactly the state the retention patch institutionalizes:
  glibc invented it, shipped it for a decade, and fixed it under an
  all-sharers-upgrade assumption.
- 2.25 (2017), BZ#20973 (commit 353683a22ed8): robust wake discipline -
  a woken waiter taking over a dead owner failed to restore
  FUTEX_WAITERS, stranding other waiters. The assume_other_futex_waiters
  fix protects a mutex only when every sharer runs >=2.25; an old peer's
  takeover still drops the bit.
- 2.25: pthread_cond_t internal format rewritten wholesale; pshared
  condvars across the boundary are undefined. Shipped with no
  negotiation - the de facto policy statement.

musl events (verified in git):
- v0.7.1 (2011): robust mutexes (owner masked 0x7fffffff era).
- v1.1.5 (2014), 4220d298: lost-wake fix - pshared robust acquisitions
  must set the waiters bit because the kernel death-wake keys on it.
  Wake-discipline fix, complete only when all sharers upgraded; the
  commit message is literally about the kernel dependency our series
  cites (mval = (uval & FUTEX_WAITERS)).
- v1.1.5 (2014), d338b506: unrecoverable-status encoding reworked
  (type flag 8 semantics).
- v1.1.22 (2019), 099b89d3 + 54ca6779 (same release): recovery state
  moved from type-bit-8 to word-bit-30 (tid|0x40000000 = held by a LIVE
  owner, not yet consistent; poison 0x7fffffff), and type-bit-8
  simultaneously REDEFINED as priority inheritance. Mixed-version
  consequences are catastrophic in both directions: an old peer's
  recovery writes _m_type|=8, after which new peers dispatch the mutex
  as PI and issue FUTEX_LOCK_PI against a non-PI word; a new peer's
  recovery word tid|0x40000000 reads to old peers as a dead-owner
  takeover candidate ("own & 0x40000000" acquirable), so an old peer
  CASes bare tid over a LIVE owner - mutual exclusion violated.
- Correction to the sentinel note above: the cross-era ENOTRECOVERABLE
  poison value is 0x7fffffff (pre-1.1.22 reads own&0x7fffffff ==
  0x7fffffff, post-1.1.22 reads own&0x3fffffff == 0x3fffffff - both
  match); bare 0x3fffffff would read as a foreign live owner (EBUSY /
  wait forever) to pre-1.1.22 musl.

Verdict: process-shared mutex compatibility across libc versions has
never been a kept contract in either implementation. Both shipped
wake-discipline fixes in exactly the retention change's class (glibc
BZ#20973, musl 1.1.5) whose correctness presumes all sharers upgrade;
both re-encoded shared protocol state with zero negotiation (glibc 2.7
pshared bit, musl 1.1.22 bit reuse); and glibc itself produced
FUTEX_WAITERS|0 for a decade and resolved it by removing the producer
while consumers still hang. The retention proposal's posture
(tolerance patch + no-emission-by-default + an optional fail-loud kind
bit) is stricter than the historical practice of either libc.
