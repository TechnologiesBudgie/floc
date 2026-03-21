/*
 * dir_helper.c  —  POSIX directory/stat helpers for FLOC (Fortran Lines Of Code)
 *
 * Provides Fortran-callable C functions for:
 *   - Opening/reading/closing directories  (opendir/readdir/closedir)
 *   - Querying file type and size          (stat)
 *
 * All string arguments are null-terminated C strings passed from Fortran
 * via ISO_C_BINDING (CHARACTER(KIND=C_CHAR, LEN=1), DIMENSION(*)).
 *
 * Performance note: stat() is cached by the kernel's dentry cache, so repeated
 * calls on the same path are essentially free.
 */

#include <stdio.h>
#include <dirent.h>
#include <sys/stat.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

/* ── Directory handle ──────────────────────────────────────────────────────── */

/* Opens a directory. Returns opaque handle, or NULL on error. */
void *c_opendir(const char *path) {
    return (void *)opendir(path);
}

/*
 * Reads the next entry from an open directory handle.
 *
 * Returns:
 *   2  → subdirectory   (name written to buf)
 *   1  → regular file   (name written to buf)
 *   0  → end of directory or error
 *
 * '..' and '.' are silently skipped.
 * d_type == DT_UNKNOWN (some NFS/tmpfs mounts) falls through to stat().
 */
int c_readdir(void *handle, char *buf, int buflen, const char *parent_path) {
    DIR *dir = (DIR *)handle;
    struct dirent *entry;

    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        /* Copy name into Fortran buffer (space-padded by caller) */
        strncpy(buf, entry->d_name, (size_t)(buflen - 1));
        buf[buflen - 1] = '\0';

        if (entry->d_type == DT_DIR)
            return 2;
        if (entry->d_type == DT_REG)
            return 1;

        /* DT_UNKNOWN: fall back to stat */
        if (entry->d_type == DT_UNKNOWN && parent_path != NULL) {
            char full[4096];
            struct stat st;
            snprintf(full, sizeof(full), "%s/%s", parent_path, entry->d_name);
            if (stat(full, &st) == 0) {
                if (S_ISDIR(st.st_mode)) return 2;
                if (S_ISREG(st.st_mode)) return 1;
            }
        }
        /* Symlink, pipe, device — skip */
    }
    return 0;
}

/* Closes a directory handle. */
void c_closedir(void *handle) {
    if (handle) closedir((DIR *)handle);
}

/* ── File / path queries ───────────────────────────────────────────────────── */

/* Returns 1 if path is a regular file, 2 if directory, 0 otherwise / error. */
int c_path_type(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (S_ISREG(st.st_mode))  return 1;
    if (S_ISDIR(st.st_mode))  return 2;
    return 0;
}

/* Returns file size in bytes, or -1 on error. */
long long c_file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return -1LL;
    return (long long)st.st_size;
}
