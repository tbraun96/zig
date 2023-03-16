#ifndef __wasilibc_sys_select_h
#define __wasilibc_sys_select_h

#include <__fd_set.h>
#include <__struct_timespec.h>
#include <__struct_timeval.h>

#ifdef __cplusplus
extern "C" {
#endif

#define _NSIG 65
#define _NSIG_BPW   32
#define _NSIG_WORDS (_NSIG / _NSIG_BPW)
/* TODO: This is just a placeholder for now. Keep this in sync with musl. */
typedef union {
    unsigned long sig[_NSIG_WORDS];
    unsigned long __bits[_NSIG_WORDS];
} sigset_t;

int pselect(int, fd_set *, fd_set *, fd_set *, const struct timespec *, const sigset_t *);

#ifdef __cplusplus
}
#endif

#endif
