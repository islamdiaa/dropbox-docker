// Preloaded into the Dropbox client (LD_PRELOAD) by docker-entrypoint.sh.
//
// On its first link the client moves an existing ~/Dropbox without a
// .dropbox marker aside to "~/Dropbox (Old)" and starts a new folder. A sync
// folder mapped into the container is a mount point, which can't be renamed:
// the call fails with EBUSY and the client hangs on "Starting..." (#31).
//
// When that rename fails with EBUSY and the folder is empty, report it as
// done, so the client uses the mounted folder in place. A folder with files
// in it still fails: Dropbox would have moved those files out of the way,
// while syncing in place would upload them into the account being linked,
// and they may belong to another account. Every other rename, and every
// other error, is passed through unchanged.
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int is_empty_dir(const char *path) {
  DIR *dir = opendir(path);
  if (!dir) return 0;
  int empty = 1;
  const struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
      empty = 0;
      break;
    }
  }
  closedir(dir);
  return empty;
}

int rename(const char *oldpath, const char *newpath) {
  static int (*real_rename)(const char *, const char *);
  if (!real_rename) {
    real_rename = (int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename");
    if (!real_rename) {
      errno = ENOSYS;
      return -1;
    }
  }

  int ret = real_rename(oldpath, newpath);
  if (ret == 0 || errno != EBUSY) return ret;

  const char *home = getenv("HOME");
  char sync[PATH_MAX];
  int n = home ? snprintf(sync, sizeof sync, "%s/Dropbox", home) : -1;
  if (n > 0 && (size_t)n < sizeof sync && oldpath && newpath &&
      strcmp(oldpath, sync) == 0 && strncmp(newpath, sync, (size_t)n) == 0 &&
      strncmp(newpath + n, " (Old)", 6) == 0) {
    if (is_empty_dir(sync)) {
      fprintf(stderr, "dropbox-docker: %s is a mount point; keeping it as the sync folder\n", sync);
      return 0;
    }
    fprintf(stderr,
            "dropbox-docker: ERROR: Dropbox wants to move %s aside: it has files in it but isn't this\n"
            "dropbox-docker: ERROR: account's Dropbox folder. A mapped folder can't be moved, so linking stops here.\n"
            "dropbox-docker: ERROR: Stop the container, move the files out of the folder, empty the config folder,\n"
            "dropbox-docker: ERROR: remove this device under https://www.dropbox.com/account/security and start again.\n"
            "dropbox-docker: ERROR: Move the files back once Dropbox is up to date.\n",
            sync);
  }
  errno = EBUSY;
  return -1;
}
