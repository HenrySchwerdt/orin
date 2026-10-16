/* Deterministic listDir error paths: successful enumeration must never hide a partial result.
 * Include L0 with syscall substitutions so macOS and Linux exercise the same faults. */
#define _GNU_SOURCE
#include <stdlib.h>
#include <dirent.h>
#include <sys/stat.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>

static void *fault_malloc(size_t n);
static struct dirent *fault_readdir(DIR *d);
static int fault_fstatat(int fd, const char *path, struct stat *st, int flags);
static int fault_closedir(DIR *d);
#define malloc fault_malloc
#define readdir fault_readdir
#define fstatat fault_fstatat
#define closedir fault_closedir
#include "../orin_platform.c"
#undef malloc
#undef readdir
#undef fstatat
#undef closedir

static int allocation_fault, read_fault, stat_fault, close_fault, read_calls, closes;
static void *fault_malloc(size_t n) { return allocation_fault ? NULL : malloc(n); }
static struct dirent *fault_readdir(DIR *d) {
    if (!read_fault) return readdir(d);
    static struct dirent entry;
    if (read_calls++ == 0) {
        strcpy(entry.d_name, "file");
        return &entry;
    }
    errno = read_fault;
    return NULL;
}
static int fault_fstatat(int fd, const char *path, struct stat *st, int flags) {
    if (stat_fault) { errno = stat_fault; return -1; }
    return fstatat(fd, path, st, flags);
}
static int fault_closedir(DIR *d) {
    closes++;
    int rc = closedir(d);
    if (close_fault) { errno = close_fault; return -1; }
    return rc;
}
static void count_entry(void *ctx, const char *name, size_t len, int is_dir) {
    (void)name; (void)len; (void)is_dir;
    (*(int *)ctx)++;
    errno = EINVAL; /* Must not be mistaken for an enumeration error. */
}
static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)
int main(void) {
    char directory[] = "/tmp/orin_dir_fault_XXXXXX", path[128];
    if (!mkdtemp(directory)) return 1;
    snprintf(path, sizeof path, "%s/file", directory);
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    fclose(f);
    int count = 0;
    CHECK(orin_platform_dir_list(directory, strlen(directory), count_entry, &count) == 0 && count == 1 && closes == 1);
    allocation_fault = 1;
    count = 0;
    CHECK(orin_platform_dir_list(directory, strlen(directory), count_entry, &count) == ENOMEM && count == 0 && closes == 1);
    allocation_fault = 0;
    for (int i = 0; i < 2; i++) {
        read_fault = i == 0 ? EIO : ENOMEM;
        read_calls = count = 0;
        CHECK(orin_platform_dir_list(directory, strlen(directory), count_entry, &count) == read_fault && count == 1);
    }
    read_fault = 0;
    stat_fault = EACCES;
    count = 0;
    CHECK(orin_platform_dir_list(directory, strlen(directory), count_entry, &count) == EACCES && count == 0);
    stat_fault = 0;
    close_fault = EIO;
    count = 0;
    CHECK(orin_platform_dir_list(directory, strlen(directory), count_entry, &count) == EIO && count == 1);
    CHECK(closes == 5); /* Every successful open is closed on every fault path. */
    unlink(path);
    rmdir(directory);
    if (failures) return 1;
    puts("dir_fault_test: 7 checks passed");
    return 0;
}
