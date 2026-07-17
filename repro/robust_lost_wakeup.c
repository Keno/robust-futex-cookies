// SPDX-License-Identifier: MIT
/*
 * Reproducer: a robust futex wakeup is lost when the woken waiter is
 * killed before it can act on the wakeup and the futex was re-acquired
 * by a third task in the meantime. Plain TID robust list protocol, no
 * kernel extensions involved - this reproduces against mainline.
 *
 * The interleaving (A owner, B and C waiters, D newcomer):
 *
 *   1. A holds the futex, B and C sleep in FUTEX_WAIT:
 *      word == A_tid | FUTEX_WAITERS.
 *   2. A unlocks via the robust protocol: store 0 over the *whole*
 *      word (this wipes FUTEX_WAITERS) + FUTEX_WAKE(1). The single
 *      wakeup goes to B.
 *   3. Before B runs, D acquires through the uncontended fast path:
 *      cmpxchg(0 -> D_tid). word == D_tid, no FUTEX_WAITERS, C still
 *      asleep.
 *   4. B is killed before it can fail its acquire and re-assert
 *      FUTEX_WAITERS. B's list_op_pending still points at the futex
 *      (the lock path arms it before the wait loop - glibc does the
 *      same in pthread_mutex_lock for robust mutexes).
 *   5. B's robust exit walk runs handle_futex_death() on the pending
 *      op: the word's owner TID is D, not B. The word must not be
 *      touched (D is alive and healthy) and mainline does nothing at
 *      all - the wakeup B consumed in step 2 is lost.
 *   6. D unlocks. No FUTEX_WAITERS -> uncontended fast path, no wake.
 *      C sleeps forever although the futex is free.
 *
 * A fixed kernel replays the possibly consumed wakeup in step 5:
 * FUTEX_WAKE(1) on a pending op whose owner TID mismatches the dying
 * task. C then wakes, re-evaluates the word and re-arms FUTEX_WAITERS,
 * repairing the wakeup chain.
 *
 * The reproducer constructs the post-step-4 state deterministically
 * instead of racing steps 2-4 (every step is an independently valid
 * action, the race window only orders them):
 *
 *   - the parent plays D: it writes its own TID into the word,
 *   - a child plays C: FUTEX_WAIT on the word (with a timeout purely
 *     so the reproducer terminates - a real waiter would hang),
 *   - a second child plays B: it registers a robust list head whose
 *     list_op_pending points at the futex, then exits, triggering the
 *     robust exit walk of step 5.
 *
 * Exit status: 0 the waiter was woken (fixed kernel),
 *              1 the waiter timed out  (lost wakeup - unfixed kernel),
 *              2 setup error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/futex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define WAIT_TIMEOUT_SEC	5

static uint32_t *word;		/* MAP_SHARED futex word */

static int sys_futex(uint32_t *uaddr, int op, uint32_t val,
		     const struct timespec *timeout)
{
	return syscall(SYS_futex, uaddr, op, val, timeout, NULL, 0);
}

static void die(const char *what)
{
	perror(what);
	exit(2);
}

/* C: sleep on the word as left behind by the wiped-WAITERS unlock. */
static void waiter(uint32_t val)
{
	struct timespec ts = { .tv_sec = WAIT_TIMEOUT_SEC };

	for (;;) {
		if (!sys_futex(word, FUTEX_WAIT, val, &ts))
			exit(0);		/* woken */
		if (errno == EINTR)
			continue;
		if (errno == ETIMEDOUT)
			exit(1);		/* the lost wakeup */
		exit(2);
	}
}

/*
 * B: die with list_op_pending armed on the futex, exactly as a waiter
 * killed inside the lock path does. futex_offset is 0, so the pending
 * pointer is the futex address itself.
 */
static void dying_waiter(void)
{
	static struct robust_list_head head;

	head.list.next = &head.list;	/* empty list */
	head.futex_offset = 0;
	head.list_op_pending = (struct robust_list *)word;

	if (syscall(SYS_set_robust_list, &head, sizeof(head)))
		die("set_robust_list");
	_exit(0);			/* runs the robust exit walk */
}

/* Wait until @pid blocks (state 'S'), i.e. sits in FUTEX_WAIT. */
static void wait_until_sleeping(pid_t pid)
{
	char path[64], buf[256];
	struct timespec ts = { .tv_nsec = 1000000 };

	snprintf(path, sizeof(path), "/proc/%d/stat", pid);
	for (;;) {
		FILE *f = fopen(path, "r");
		char *state;

		if (!f || !fgets(buf, sizeof(buf), f))
			die("read child stat");
		fclose(f);
		/* field 3, after the parenthesized comm */
		state = strrchr(buf, ')');
		if (state && state[1] == ' ' && state[2] == 'S')
			break;
		nanosleep(&ts, NULL);
	}
	/* cover the gap between blocking and futex queue insertion */
	ts.tv_nsec = 100000000;
	nanosleep(&ts, NULL);
}

int main(void)
{
	pid_t waiter_pid, dying_pid, self = getpid();
	int status;

	word = mmap(NULL, sizeof(*word), PROT_READ | PROT_WRITE,
		    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (word == MAP_FAILED)
		die("mmap");

	/* D re-acquired the futex: live owner TID, FUTEX_WAITERS wiped. */
	*word = self;

	waiter_pid = fork();
	if (waiter_pid < 0)
		die("fork");
	if (!waiter_pid)
		waiter(self);
	wait_until_sleeping(waiter_pid);

	dying_pid = fork();
	if (dying_pid < 0)
		die("fork");
	if (!dying_pid)
		dying_waiter();

	/*
	 * The robust exit walk runs in do_exit() before the parent is
	 * notified, so after waitpid() any replayed wakeup has been
	 * issued.
	 */
	if (waitpid(dying_pid, &status, 0) != dying_pid)
		die("waitpid dying waiter");
	if (!WIFEXITED(status) || WEXITSTATUS(status)) {
		fprintf(stderr, "dying waiter failed: status %#x\n", status);
		return 2;
	}

	if (waitpid(waiter_pid, &status, 0) != waiter_pid)
		die("waitpid waiter");
	if (!WIFEXITED(status))
		return 2;

	switch (WEXITSTATUS(status)) {
	case 0:
		printf("PASS: waiter woken - the kernel replays the consumed wakeup\n");
		return 0;
	case 1:
		printf("FAIL: lost wakeup - waiter still blocked %d seconds after the\n"
		       "      robust exit walk (would sleep forever without the reproducer's\n"
		       "      timeout). This kernel drops the wakeup consumed by a killed\n"
		       "      waiter whose futex was re-acquired before its exit walk.\n",
		       WAIT_TIMEOUT_SEC);
		return 1;
	default:
		fprintf(stderr, "waiter setup error\n");
		return 2;
	}
}
