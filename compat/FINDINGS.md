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
