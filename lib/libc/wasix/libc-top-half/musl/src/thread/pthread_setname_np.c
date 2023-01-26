#define _GNU_SOURCE
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#ifdef __wasilibc_unmodified_upstream
#include <sys/prctl.h>
#endif

#include "pthread_impl.h"

#ifdef __wasilibc_unmodified_upstream
int pthread_setname_np(pthread_t thread, const char *name)
{
	int fd, cs, status = 0;
	char f[sizeof "/proc/self/task//comm" + 3*sizeof(int)];
	size_t len;

	if ((len = strnlen(name, 16)) > 15) return ERANGE;

	if (thread == pthread_self())
		return prctl(PR_SET_NAME, (unsigned long)name, 0UL, 0UL, 0UL) ? errno : 0;

	snprintf(f, sizeof f, "/proc/self/task/%d/comm", thread->tid);
	pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cs);
	if ((fd = open(f, O_WRONLY)) < 0 || write(fd, name, len) < 0) status = errno;
	if (fd >= 0) close(fd);
	pthread_setcancelstate(cs, 0);
	return status;
}
#else
int pthread_setname_np(pthread_t thread, const char *name)
{
	return 0;
}
#endif