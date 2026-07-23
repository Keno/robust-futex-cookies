#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdatomic.h>
#include <gnu/libc-version.h>

#define FUTEX_WAITERS 0x80000000u

static const char *e(int r) { return r == 0 ? "OK(0)" : strerror(r); }

int main(void)
{
	printf("glibc %s\n", gnu_get_libc_version());

	pthread_mutex_t *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
				  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	pthread_mutexattr_t a;
	pthread_mutexattr_init(&a);
	pthread_mutexattr_setpshared(&a, PTHREAD_PROCESS_SHARED);
	pthread_mutexattr_setrobust(&a, PTHREAD_MUTEX_ROBUST);
	pthread_mutex_init(m, &a);
	printf("kind after robust pshared init: 0x%x\n", m->__data.__kind);

	_Atomic int *word = (_Atomic int *)&m->__data.__lock;

	/* The state a retaining robust unlock leaves with waiters queued */
	atomic_store(word, FUTEX_WAITERS);
	int r = pthread_mutex_trylock(m);
	printf("trylock  on WAITERS|0: %-15s word=0x%x\n", e(r), atomic_load(word));
	if (r == 0) pthread_mutex_unlock(m);

	atomic_store(word, FUTEX_WAITERS);
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += 1;
	r = pthread_mutex_timedlock(m, &ts);
	printf("timedlock(1s) WAITERS|0: %-15s word=0x%x\n", e(r), atomic_load(word));
	if (r == 0) pthread_mutex_unlock(m);

	atomic_store(word, FUTEX_WAITERS);
	pid_t pid = fork();
	if (pid == 0) {
		r = pthread_mutex_lock(m);
		_exit(r == 0 ? 42 : 43);
	}
	sleep(2);
	int st;
	if (waitpid(pid, &st, WNOHANG) == 0) {
		printf("lock     on WAITERS|0: still BLOCKED after 2s (kernel-queued, hang)\n");
		kill(pid, SIGKILL);
		waitpid(pid, &st, 0);
	} else {
		printf("lock     on WAITERS|0: returned, child exit=%d\n",
		       WIFEXITED(st) ? WEXITSTATUS(st) : -1);
	}

	/* Versioning probes: unknown kind bits */
	pthread_mutex_t *m2 = (pthread_mutex_t *)((char *)m + 256);
	pthread_mutex_init(m2, &a);
	m2->__data.__kind |= 8;
	r = pthread_mutex_lock(m2);
	printf("lock     with kind|=8    (in &127 range): %s\n", e(r));
	r = pthread_mutex_trylock(m2);
	printf("trylock  with kind|=8    (in &127 range): %s\n", e(r));
	m2->__data.__kind &= ~8;
	m2->__data.__kind |= 4;
	r = pthread_mutex_lock(m2);
	printf("lock     with kind|=4    (in &127 range): %s\n", e(r));
	m2->__data.__kind &= ~4;
	m2->__data.__kind |= 1024;
	r = pthread_mutex_trylock(m2);
	printf("trylock  with kind|=1024 (above mask):    %s word=0x%x\n", e(r),
	       (unsigned)m2->__data.__lock);
	if (r == 0)
		printf("unlock   with kind|=1024:                 %s\n",
		       e(pthread_mutex_unlock(m2)));
	return 0;
}
