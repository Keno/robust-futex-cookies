#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>

/* musl internals: _m_type=__u.__i[0], _m_lock=__u.__vi[1], _m_waiters=__u.__vi[2] */
#define M_TYPE(m)    ((m)->__u.__i[0])
#define M_LOCK(m)    ((m)->__u.__vi[1])
#define M_WAITERS(m) ((m)->__u.__vi[2])

#define FUTEX_WAITERS 0x80000000u

static const char *e(int r) { return r == 0 ? "OK(0)" : strerror(r); }

int main(void)
{
	pthread_mutex_t *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
				  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	pthread_mutexattr_t a;
	pthread_mutexattr_init(&a);
	pthread_mutexattr_setpshared(&a, PTHREAD_PROCESS_SHARED);
	pthread_mutexattr_setrobust(&a, PTHREAD_MUTEX_ROBUST);
	pthread_mutex_init(m, &a);
	printf("musl: type=0x%x\n", M_TYPE(m));

	/* Retained state, no counted waiters */
	M_LOCK(m) = (int)FUTEX_WAITERS;
	M_WAITERS(m) = 0;
	int r = pthread_mutex_trylock(m);
	printf("trylock  on WAITERS|0 (waiters ctr 0): %-18s word=0x%x\n",
	       e(r), (unsigned)M_LOCK(m));
	if (r == 0 || r == EOWNERDEAD) {
		int c = pthread_mutex_consistent(m);
		printf("  consistent() after that:             %s\n", e(c));
		printf("  unlock:                              %s word=0x%x waiters=%d\n",
		       e(pthread_mutex_unlock(m)), (unsigned)M_LOCK(m), M_WAITERS(m));
	}

	/* Retained state with counted waiters (as real sleepers would leave) */
	M_LOCK(m) = (int)FUTEX_WAITERS;
	M_WAITERS(m) = 1;
	r = pthread_mutex_trylock(m);
	printf("trylock  on WAITERS|0 (waiters ctr 1): %-18s word=0x%x\n",
	       e(r), (unsigned)M_LOCK(m));
	if (r == 0 || r == EOWNERDEAD) {
		M_WAITERS(m) = 0;   /* avoid unlock waking nobody forever */
		printf("  unlock:                              %s word=0x%x\n",
		       e(pthread_mutex_unlock(m)), (unsigned)M_LOCK(m));
	}

	/* lock path: must not block either (trylock never returns EBUSY here) */
	M_LOCK(m) = (int)FUTEX_WAITERS;
	M_WAITERS(m) = 0;
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += 1;
	r = pthread_mutex_timedlock(m, &ts);
	printf("timedlock(1s) on WAITERS|0:            %-18s word=0x%x\n",
	       e(r), (unsigned)M_LOCK(m));
	return 0;
}
