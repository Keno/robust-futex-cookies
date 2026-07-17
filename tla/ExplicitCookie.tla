--------------------------- MODULE ExplicitCookie ---------------------------
(***************************************************************************)
(* Robust futex with explicit owner cookies (ROBUST_LIST_COOKIE), as used *)
(* by the rfmutex "explicit" implementation with registry or OFD cookie   *)
(* allocation.                                                             *)
(*                                                                         *)
(* The model contains one mutex, a cookie allocator whose lease is a      *)
(* second robust list entry (the registry slot), threads which attach     *)
(* (claim a cookie), acquire/release the mutex and may die at any point,  *)
(* and the kernel exit time cleanup. The cleanup is deliberately split    *)
(* into separate steps - pending op, lease slot entry, mutex entry - so   *)
(* that the walk order is part of the modeled protocol: the cookie        *)
(* becomes reusable as soon as the *slot* entry was processed, not when   *)
(* the whole walk finished.                                                *)
(*                                                                         *)
(* Switches:                                                               *)
(*                                                                         *)
(*   PendingFirst = TRUE models the fixed kernel: on a cookie list the    *)
(*     pending op is handled before any queued entry.                     *)
(*                                                                         *)
(*   PendingFirst = FALSE models the historical walk order (queued        *)
(*     entries, then the pending op). TLC finds the lease reuse           *)
(*     corruption: the slot entry releases the cookie, a new thread       *)
(*     claims it and acquires the lock the dead thread's stale pending    *)
(*     op refers to, and the late pending handling marks the live lock    *)
(*     FUTEX_OWNER_DIED (KenoAIStaging/robust-futex-cookies issue #1).    *)
(*                                                                         *)
(*   PendingViaHead = TRUE  models the final ABI: the pending op is       *)
(*     attributed via the thread private                                  *)
(*     robust_list_head2::list_op_pending_cookie.                         *)
(*                                                                         *)
(*   PendingViaHead = FALSE models the rejected ABI variant where the     *)
(*     pending op was attributed via the entry cookie embedded in the     *)
(*     (shared) mutex, written by every contender before its cmpxchg.     *)
(*     TLC finds the corruption: a loser overwrites the winner's entry    *)
(*     cookie while its own pending op is armed; if the loser dies, the   *)
(*     kernel misattributes the winner's lock.                            *)
(*                                                                         *)
(*   LeaseLast = TRUE models the documented user space obligation: the    *)
(*     lease slot entry is walked after every held lock entry (rfmutex     *)
(*     enqueues the slot at attach time and inserts later entries LIFO).  *)
(*                                                                         *)
(*   LeaseLast = FALSE lets the walk release the lease while held lock    *)
(*     entries are still unprocessed. TLC finds a corruption even with    *)
(*     PendingFirst: the freed cookie is claimed by a second thread whose *)
(*     own death misattributes (benignly) the first corpse's lock, which  *)
(*     lets a live thread re-acquire it while the first walk still holds  *)
(*     an unprocessed entry for it - and that stale entry cleanup then    *)
(*     wipes the live owner's lock.                                       *)
(*                                                                         *)
(*   UseAllocator = FALSE disables the allocator: threads use the fixed   *)
(*     identifier FixedId[t] with no lease at all. Duplicate FixedId      *)
(*     values model the classic TID protocol with a TID collision across  *)
(*     PID namespaces; TLC then finds the original kernel bug this        *)
(*     series fixes.                                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Threads,        \* set of thread identifiers
    Cookies,        \* allocator pool (subset of Nat \ {0})
    UseAllocator,   \* BOOLEAN: leased cookies vs fixed identifiers
    FixedId,        \* [Threads -> Nat \ {0}]: identifiers if ~UseAllocator
    PendingViaHead, \* BOOLEAN: final ABI vs rejected entry-cookie ABI
    PendingFirst,   \* BOOLEAN: fixed vs historical kernel walk order
    LeaseLast       \* BOOLEAN: slot entry ordered after all held locks

NONE == "none"

VARIABLES
    word,       \* the futex word: [own : Nat, od : BOOLEAN]
    ecookie,    \* the entry cookie slot embedded in the mutex
    pc,         \* thread program counters
    alive,      \* thread liveness
    cookie,     \* current owner identifier of the thread, 0 if none
    lease,      \* the slot entry holding the cookie is still uncleaned
    pending,    \* robust_list_head::list_op_pending armed (per thread)
    pcookie,    \* robust_list_head2::list_op_pending_cookie (per thread)
    enq,        \* mutex entry queued in the thread's robust list
    done_p,     \* kernel walk: pending op processed
    done_s,     \* kernel walk: slot (lease) entry processed
    done_e,     \* kernel walk: mutex entry processed
    owner,      \* ghost: the thread which truly holds the mutex, or NONE
    corrupt     \* ghost: kernel cleanup modified a live thread's lock

vars == <<word, ecookie, pc, alive, cookie, lease, pending, pcookie, enq,
          done_p, done_s, done_e, owner, corrupt>>

PCs == {"unattached", "idle", "acq", "acquired", "cookied", "enqueued",
        "own", "rel", "unlocked"}

TypeOK ==
    /\ word \in [own : Nat, od : BOOLEAN]
    /\ ecookie \in Nat
    /\ pc \in [Threads -> PCs]
    /\ alive \in [Threads -> BOOLEAN]
    /\ cookie \in [Threads -> Nat]
    /\ lease \in [Threads -> BOOLEAN]
    /\ pending \in [Threads -> BOOLEAN]
    /\ pcookie \in [Threads -> Nat]
    /\ enq \in [Threads -> BOOLEAN]
    /\ done_p \in [Threads -> BOOLEAN]
    /\ done_s \in [Threads -> BOOLEAN]
    /\ done_e \in [Threads -> BOOLEAN]
    /\ owner \in Threads \cup {NONE}
    /\ corrupt \in BOOLEAN

Init ==
    /\ word = [own |-> 0, od |-> FALSE]
    /\ ecookie = 0
    /\ pc = [t \in Threads |-> "unattached"]
    /\ alive = [t \in Threads |-> TRUE]
    /\ cookie = [t \in Threads |-> 0]
    /\ lease = [t \in Threads |-> FALSE]
    /\ pending = [t \in Threads |-> FALSE]
    /\ pcookie = [t \in Threads |-> 0]
    /\ enq = [t \in Threads |-> FALSE]
    /\ done_p = [t \in Threads |-> FALSE]
    /\ done_s = [t \in Threads |-> FALSE]
    /\ done_e = [t \in Threads |-> FALSE]
    /\ owner = NONE
    /\ corrupt = FALSE

(***************************************************************************)
(* Cookie allocation                                                       *)
(***************************************************************************)

\* A cookie is free while no (live or dead-but-unwalked) slot entry
\* leases it. This is exactly what the registry slot / OFD lock provide.
Free(c) == \A u \in Threads : ~(cookie[u] = c /\ lease[u])

\* Attach: claim a cookie. With the allocator the claim is leased by the
\* thread's slot entry; with fixed identifiers (TIDs) there is no lease
\* and duplicates are possible by construction.
Attach(t) ==
    /\ alive[t] /\ pc[t] = "unattached"
    /\ IF UseAllocator
       THEN \E c \in Cookies :
                /\ Free(c)
                /\ cookie' = [cookie EXCEPT ![t] = c]
                /\ lease' = [lease EXCEPT ![t] = TRUE]
       ELSE /\ cookie' = [cookie EXCEPT ![t] = FixedId[t]]
            /\ lease' = [lease EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, pending, pcookie, enq,
                   done_p, done_s, done_e, owner, corrupt>>

(***************************************************************************)
(* Lock operation                                                          *)
(***************************************************************************)

\* Arm the pending op. In the final ABI the pending cookie is thread
\* private state in the list head. In the rejected ABI the contender
\* writes its cookie into the shared entry before the cmpxchg.
StartAcq(t) ==
    /\ alive[t] /\ pc[t] = "idle"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = cookie[t]]
    /\ ecookie' = IF PendingViaHead THEN ecookie ELSE cookie[t]
    /\ pc' = [pc EXCEPT ![t] = "acq"]
    /\ UNCHANGED <<word, alive, cookie, lease, enq, done_p, done_s, done_e,
                   owner, corrupt>>

\* The cmpxchg: acquire a free (or dead) lock, preserving OWNER_DIED.
Acquire(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own = 0
    /\ word' = [own |-> cookie[t], od |-> word.od]
    /\ owner' = t
    /\ pc' = [pc EXCEPT ![t] = "acquired"]
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   done_p, done_s, done_e, corrupt>>

\* Contended: give up this attempt (waiting is modeled by retrying).
FailAcq(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own # 0
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pcookie, enq,
                   done_p, done_s, done_e, owner, corrupt>>

\* The owner writes the entry cookie (final ABI: only after acquisition,
\* when it owns the entry exclusively).
WriteEntryCookie(t) ==
    /\ alive[t] /\ pc[t] = "acquired"
    /\ ecookie' = cookie[t]
    /\ pc' = [pc EXCEPT ![t] = "cookied"]
    /\ UNCHANGED <<word, alive, cookie, lease, pending, pcookie, enq,
                   done_p, done_s, done_e, owner, corrupt>>

\* Queue the entry in the robust list. The pending op is still armed
\* until the separate disarm step: the entry can be on the list while
\* list_op_pending points at it (the kernel walk skips it there).
Enqueue(t) ==
    /\ alive[t] /\ pc[t] = "cookied"
    /\ enq' = [enq EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "enqueued"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pending, pcookie,
                   done_p, done_s, done_e, owner, corrupt>>

DisarmAcq(t) ==
    /\ alive[t] /\ pc[t] = "enqueued"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "own"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pcookie, enq,
                   done_p, done_s, done_e, owner, corrupt>>

(***************************************************************************)
(* Unlock operation                                                        *)
(***************************************************************************)

\* Arm the pending op and dequeue the entry.
StartRel(t) ==
    /\ alive[t] /\ pc[t] = "own"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = cookie[t]]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "rel"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, done_p, done_s,
                   done_e, owner, corrupt>>

\* Store 0 to the lock word (the kernel robust unlock stores the whole
\* word; the VDSO fast path cmpxchgs cookie -> 0: both end at 0).
Release(t) ==
    /\ alive[t] /\ pc[t] = "rel"
    /\ word' = [own |-> 0, od |-> FALSE]
    /\ owner' = NONE
    /\ pc' = [pc EXCEPT ![t] = "unlocked"]
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   done_p, done_s, done_e, corrupt>>

\* Disarm the pending op after the unlock.
FinishRel(t) ==
    /\ alive[t] /\ pc[t] = "unlocked"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pcookie, enq,
                   done_p, done_s, done_e, owner, corrupt>>

(***************************************************************************)
(* Death and kernel cleanup                                                *)
(*                                                                         *)
(* The walk is split into three separately scheduled steps. The two      *)
(* queued entries (slot, mutex entry) are processed in either order (the *)
(* fixed protocol must be safe regardless of list order); PendingFirst    *)
(* selects whether the pending op is processed before or after them.     *)
(***************************************************************************)

Die(t) ==
    /\ alive[t] /\ pc[t] # "unattached"
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    \* Threads without an allocator lease have no slot entry to walk
    /\ done_s' = [done_s EXCEPT ![t] = ~lease[t]]
    /\ UNCHANGED <<word, ecookie, pc, cookie, lease, pending, pcookie, enq,
                   done_p, done_e, owner, corrupt>>

\* The owner identifier the kernel uses for the dead thread's pending op.
PendingId(t) == IF PendingViaHead THEN pcookie[t] ELSE ecookie

QueuedAllowed(t) == ~PendingFirst \/ done_p[t]
PendingAllowed(t) == PendingFirst \/ (done_s[t] /\ done_e[t])

\* Process the slot entry: the kernel marks the (dead) thread's registry
\* slot FUTEX_OWNER_DIED / the OFD lock dies with the process - either
\* way the cookie lease is gone from this point on.
CleanupSlot(t) ==
    /\ ~alive[t] /\ ~done_s[t] /\ QueuedAllowed(t)
    /\ (LeaseLast => done_e[t])
    /\ done_s' = [done_s EXCEPT ![t] = TRUE]
    /\ lease' = [lease EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<word, ecookie, pc, alive, cookie, pending, pcookie, enq,
                   done_p, done_e, owner, corrupt>>

\* Process the mutex entry. The walk skips the entry when it equals
\* list_op_pending (it is attributed through the pending path then).
CleanupEntry(t) ==
    /\ ~alive[t] /\ ~done_e[t] /\ QueuedAllowed(t)
    /\ done_e' = [done_e EXCEPT ![t] = TRUE]
    /\ IF /\ enq[t] /\ ~pending[t]
          /\ word.own # 0 /\ word.own = ecookie
       THEN /\ word' = [own |-> 0, od |-> TRUE]
            \* Corruption means wiping a LIVE thread's lock. Wiping a
            \* dead thread's lock through a misattributed walk (a reused
            \* cookie matching the dead predecessor's stale word) is
            \* recovery, merely performed by the wrong dead thread.
            /\ corrupt' = (corrupt \/ (owner # NONE /\ owner # t /\ alive[owner]))
            /\ owner' = IF owner = NONE THEN NONE
                        ELSE IF owner = t \/ ~alive[owner] THEN NONE
                        ELSE owner
       ELSE UNCHANGED <<word, corrupt, owner>>
    /\ UNCHANGED <<ecookie, pc, alive, cookie, lease, pending, pcookie, enq,
                   done_p, done_s>>

\* Process the pending op.
CleanupPending(t) ==
    /\ ~alive[t] /\ ~done_p[t] /\ PendingAllowed(t)
    /\ done_p' = [done_p EXCEPT ![t] = TRUE]
    /\ IF pending[t] /\ word.own # 0 /\ word.own = PendingId(t)
       THEN /\ word' = [own |-> 0, od |-> TRUE]
            \* Corruption means wiping a LIVE thread's lock. Wiping a
            \* dead thread's lock through a misattributed walk (a reused
            \* cookie matching the dead predecessor's stale word) is
            \* recovery, merely performed by the wrong dead thread.
            /\ corrupt' = (corrupt \/ (owner # NONE /\ owner # t /\ alive[owner]))
            /\ owner' = IF owner = NONE THEN NONE
                        ELSE IF owner = t \/ ~alive[owner] THEN NONE
                        ELSE owner
       ELSE UNCHANGED <<word, corrupt, owner>>
    /\ UNCHANGED <<ecookie, pc, alive, cookie, lease, pending, pcookie, enq,
                   done_s, done_e>>

\* Recycle the thread identifier as a fresh, unattached incarnation once
\* the whole walk finished. (Cookie reuse does NOT wait for this - it
\* only waits for CleanupSlot, which is the point of the model.)
Reincarnate(t) ==
    /\ ~alive[t] /\ done_p[t] /\ done_s[t] /\ done_e[t]
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "unattached"]
    /\ cookie' = [cookie EXCEPT ![t] = 0]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pcookie' = [pcookie EXCEPT ![t] = 0]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ done_p' = [done_p EXCEPT ![t] = FALSE]
    /\ done_s' = [done_s EXCEPT ![t] = FALSE]
    /\ done_e' = [done_e EXCEPT ![t] = FALSE]
    /\ owner' = IF owner = t THEN NONE ELSE owner
    /\ UNCHANGED <<word, ecookie, lease, corrupt>>

Cleanup(t) == CleanupSlot(t) \/ CleanupEntry(t) \/ CleanupPending(t)

Next ==
    \E t \in Threads :
        \/ Attach(t)
        \/ StartAcq(t) \/ Acquire(t) \/ FailAcq(t) \/ WriteEntryCookie(t)
        \/ Enqueue(t) \/ DisarmAcq(t)
        \/ StartRel(t) \/ Release(t) \/ FinishRel(t)
        \/ Die(t) \/ Cleanup(t) \/ Reincarnate(t)

Spec == Init /\ [][Next]_vars /\ \A t \in Threads : WF_vars(Cleanup(t))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* The kernel never modifies a lock which a live thread holds.
NoCorruption == ~corrupt

\* Mutual exclusion: the ghost owner is unique by construction; every
\* thread which believes it holds the lock is the ghost owner and the
\* word carries its identifier.
Holding(t) == alive[t] /\ pc[t] \in {"acquired", "cookied", "enqueued",
                                     "own", "rel"}

Exclusion ==
    \A t \in Threads : Holding(t) => owner = t /\ word.own = cookie[t]

\* Robustness: a lock whose owner died is eventually recoverable.
Recovery ==
    \A t \in Threads :
        (owner = t /\ ~alive[t]) ~> (word.own = 0)

=============================================================================
