#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

struct sweep {
  unsigned long long limit, inspected, removed, errors;
  int limited;
};

/* Only retired trees are traversed. Relative descriptors and NOFOLLOW keep
   symlink targets outside the tree untouched, including during overlapping runs. */
static int sweep_directory(int fd, unsigned int depth, struct sweep *state) {
  DIR *directory = fdopendir(fd);
  struct dirent *entry;
  struct stat info;
  int complete = 1, child, result;
  if (directory == NULL) { close(fd); ++state->errors; return 0; }

  for (;;) {
    errno = 0;
    entry = readdir(directory);
    if (entry == NULL) {
      if (errno != 0) { ++state->errors; complete = 0; }
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    if (state->inspected == state->limit) {
      state->limited = 1; complete = 0; break;
    }
    ++state->inspected;
    if (fstatat(fd, entry->d_name, &info, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno != ENOENT) { ++state->errors; complete = 0; }
      continue;
    }
    if (S_ISDIR(info.st_mode)) {
      if (depth == 8) { ++state->errors; complete = 0; continue; }
      child = openat(fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
      if (child < 0) {
        if (errno != ENOENT) { ++state->errors; complete = 0; }
        continue;
      }
      if (!sweep_directory(child, depth + 1, state)) { complete = 0; continue; }
      result = unlinkat(fd, entry->d_name, AT_REMOVEDIR);
    } else {
      result = unlinkat(fd, entry->d_name, 0);
    }
    if (result == 0) ++state->removed;
    else if (errno != ENOENT) { ++state->errors; complete = 0; }
  }
  if (closedir(directory) != 0) { ++state->errors; complete = 0; }
  return complete;
}

static int failure(int error) {
  const char *name;
  switch (error) {
  case ENOENT: name = "enoent"; break;
  case ENOTDIR: name = "enotdir"; break;
  case EACCES: name = "eacces"; break;
  case EMFILE: name = "emfile"; break;
  case ENFILE: name = "enfile"; break;
  case ENOMEM: name = "enomem"; break;
  default: name = "directory_io"; break;
  }
  return printf("E %s\n", name) < 0 || fflush(stdout) != 0 ? 74 : 0;
}

static int identifier(const char *name) {
  size_t i;
  if (strlen(name) != 32) return 0;
  for (i = 0; i < 32; ++i) {
    if (!((name[i] >= '0' && name[i] <= '9') ||
          (name[i] >= 'a' && name[i] <= 'f'))) return 0;
  }
  return 1;
}

static int space(const char *path) {
  struct statvfs stats;
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  int error;
  if (fd < 0) return failure(errno);
  if (fstatvfs(fd, &stats) != 0) {
    error = errno;
    close(fd);
    return failure(error);
  }
  if (close(fd) != 0) return failure(errno);
  /* Emit counts without multiplying in C: large virtual filesystems can exceed
     fixed-width byte arithmetic. The bounded Elixir decoder computes bytes. */
  return printf("V %" PRIuMAX " %" PRIuMAX " %" PRIuMAX " %" PRIuMAX "\n",
                (uintmax_t)stats.f_frsize, (uintmax_t)stats.f_blocks,
                (uintmax_t)stats.f_bfree, (uintmax_t)stats.f_bavail) < 0 ||
         fflush(stdout) != 0 ? 74 : 0;
}

int main(int argc, char **argv) {
  char *end;
  unsigned long long limit, inspected = 0;
  DIR *directory;
  struct dirent *entry;
  int error = 0, limited = 0, fd;
  struct sweep state;

  if (argc == 3 && strcmp(argv[2], "--space") == 0) return space(argv[1]);
  if ((argc != 3 && argc != 4) || argv[2][0] < '0' || argv[2][0] > '9') return 64;
  errno = 0;
  limit = strtoull(argv[2], &end, 10);
  if (errno != 0 || *end != '\0') return 64;
  if (argc == 4) {
    if (strcmp(argv[3], "--sweep") != 0) return 64;
    fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) return failure(errno);
    state = (struct sweep){limit, 0, 0, 0, 0};
    sweep_directory(fd, 0, &state);
    return printf("S %llu %llu %llu %d\n", state.inspected, state.removed,
                  state.errors, state.limited) < 0 || fflush(stdout) != 0 ? 74 : 0;
  }
  directory = opendir(argv[1]);
  if (directory == NULL) return failure(errno);

  for (;;) {
    errno = 0;
    entry = readdir(directory);
    if (entry == NULL) { error = errno; break; }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    /* One lookahead distinguishes an exact-size directory from truncation. */
    if (inspected == limit) { limited = 1; break; }
    ++inspected;
    if (identifier(entry->d_name) && puts(entry->d_name) == EOF) {
      closedir(directory);
      return 74;
    }
  }

  if (closedir(directory) != 0 && error == 0) error = errno;
  if (error != 0) return failure(error);
  return printf("%c %llu\n", limited ? 'L' : 'C', inspected) < 0 || fflush(stdout) != 0 ? 74 : 0;
}
