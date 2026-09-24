#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

int main(int argc, char **argv) {
  char *end;
  unsigned long long limit, inspected = 0;
  DIR *directory;
  struct dirent *entry;
  int error = 0, limited = 0;

  if (argc != 3 || argv[2][0] < '0' || argv[2][0] > '9') return 64;
  errno = 0;
  limit = strtoull(argv[2], &end, 10);
  if (errno != 0 || *end != '\0') return 64;
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
