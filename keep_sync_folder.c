// Preloaded into the Dropbox client (LD_PRELOAD). On its first link the
// client moves an existing ~/Dropbox it doesn't recognise aside to
// "~/Dropbox (Old)". When ~/Dropbox is a bind mount that rename fails with
// EBUSY, and the client stalls on "Starting..." forever (#31). Report the
// rename as done instead: the client then keeps using the mounted folder in
// place. Every other rename is passed through untouched.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef KEEP_ERRNO
#define KEEP_ERRNO EBUSY
#endif

int rename(const char *oldpath, const char *newpath) {
  static int (*real_rename)(const char *, const char *);
  if (!real_rename) real_rename = (int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename");

  int ret = real_rename(oldpath, newpath);
  if (ret == 0 || errno != KEEP_ERRNO) return ret;

  const char *home = getenv("HOME");
  char sync[PATH_MAX];
  if (!home || snprintf(sync, sizeof sync, "%s/Dropbox", home) >= (int)sizeof sync) {
    errno = KEEP_ERRNO;
    return ret;
  }
  size_t n = strlen(sync);
  if (strcmp(oldpath, sync) == 0 && strncmp(newpath, sync, n) == 0 &&
      strncmp(newpath + n, " (Old)", 6) == 0) {
    fprintf(stderr, "dropbox-docker: %s is a mount point; keeping it as the sync folder\n", sync);
    return 0;
  }
  errno = KEEP_ERRNO;
  return ret;
}
