! =============================================================================
! floc_cdir.f90
!
! MODULE floc_cdir
!   Thin Fortran ISO_C_BINDING wrapper around the four C functions in
!   dir_helper.c:  c_opendir / c_readdir / c_closedir / c_path_type / c_file_size
!
!   Directory traversal overview
!   ─────────────────────────────
!   collect_files() does a depth-first recursive scan of the given root.
!   Each call:
!     1. Opens the directory with c_opendir.
!     2. Iterates entries via c_readdir (returns type: 1=file, 2=dir).
!     3. Applies exclude-dir filter before recursing.
!     4. Appends regular files to the caller-supplied dynamic list.
!
!   Performance:
!     • readdir() is O(1) per entry (kernel fills DT_TYPE on ext4/xfs/btrfs).
!     • We avoid stat() entirely when DT_TYPE is set; the C layer falls back
!       to stat() only for DT_UNKNOWN (NFS/tmpfs).
!     • The Fortran side does zero heap allocation inside the hot path;
!       only the outermost collect_files call grows the results array.
! =============================================================================

MODULE floc_cdir
  USE, INTRINSIC :: ISO_C_BINDING
  IMPLICIT NONE

  ! ── C function interfaces ───────────────────────────────────────────────────
  INTERFACE
    FUNCTION c_opendir(path) BIND(C, NAME='c_opendir') RESULT(handle)
      IMPORT :: C_PTR, C_CHAR
      CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(IN) :: path
      TYPE(C_PTR) :: handle
    END FUNCTION c_opendir

    FUNCTION c_readdir(handle, buf, buflen, parent) BIND(C, NAME='c_readdir') RESULT(dtype)
      IMPORT :: C_PTR, C_CHAR, C_INT
      TYPE(C_PTR),            VALUE                    :: handle
      CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(OUT):: buf
      INTEGER(KIND=C_INT),    VALUE                    :: buflen
      CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(IN) :: parent
      INTEGER(KIND=C_INT) :: dtype
    END FUNCTION c_readdir

    SUBROUTINE c_closedir(handle) BIND(C, NAME='c_closedir')
      IMPORT :: C_PTR
      TYPE(C_PTR), VALUE :: handle
    END SUBROUTINE c_closedir

    FUNCTION c_path_type(path) BIND(C, NAME='c_path_type') RESULT(ptype)
      IMPORT :: C_INT, C_CHAR
      CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(IN) :: path
      INTEGER(KIND=C_INT) :: ptype
    END FUNCTION c_path_type

    FUNCTION c_file_size(path) BIND(C, NAME='c_file_size') RESULT(sz)
      IMPORT :: C_LONG_LONG, C_CHAR
      CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(IN) :: path
      INTEGER(KIND=C_LONG_LONG) :: sz
    END FUNCTION c_file_size
  END INTERFACE

  ! ── Dynamic file-list type ──────────────────────────────────────────────────
  INTEGER, PARAMETER :: PATH_LEN = 2048
  INTEGER, PARAMETER :: CHUNK    = 8192   ! growth chunk for file list

  TYPE :: FileList
    CHARACTER(LEN=PATH_LEN), ALLOCATABLE :: paths(:)
    INTEGER :: n = 0
    INTEGER :: capacity = 0
  END TYPE FileList

CONTAINS

  ! ---------------------------------------------------------------------------
  ! PUBLIC: recursively collect all source files under root_dir.
  !
  !   root_dir      — starting directory (Fortran string)
  !   excl_dirs     — array of directory names to skip (e.g. '.git','node_modules')
  !   n_excl        — number of entries in excl_dirs
  !   flist         — output FileList (must be initialised by caller)
  !   depth         — current recursion depth (pass 0 from top level)
  !   max_depth     — maximum recursion depth (0 = unlimited)
  ! ---------------------------------------------------------------------------
  RECURSIVE SUBROUTINE collect_files(root_dir, excl_dirs, n_excl, flist, &
                                      depth, max_depth)
    CHARACTER(LEN=*),    INTENT(IN)    :: root_dir
    CHARACTER(LEN=64),   INTENT(IN)    :: excl_dirs(:)
    INTEGER,             INTENT(IN)    :: n_excl
    TYPE(FileList),      INTENT(INOUT) :: flist
    INTEGER,             INTENT(IN)    :: depth, max_depth

    TYPE(C_PTR) :: dir_handle
    INTEGER(C_INT) :: dtype
    CHARACTER(KIND=C_CHAR), DIMENSION(4096) :: c_name
    CHARACTER(KIND=C_CHAR), DIMENSION(4096) :: c_root
    CHARACTER(LEN=256) :: entry_name
    CHARACTER(LEN=PATH_LEN) :: full_path
    INTEGER :: i, nlen

    IF (max_depth > 0 .AND. depth >= max_depth) RETURN

    ! Convert root to C string
    CALL to_c_str(TRIM(root_dir), c_root)

    dir_handle = c_opendir(c_root)
    IF (.NOT. C_ASSOCIATED(dir_handle)) RETURN

    ! Iterate directory entries
    DO
      dtype = c_readdir(dir_handle, c_name, INT(256, C_INT), c_root)
      IF (dtype == 0) EXIT

      ! Convert C name back to Fortran
      entry_name = from_c_str(c_name, 256)
      nlen = LEN_TRIM(entry_name)
      IF (nlen == 0) CYCLE

      ! Build full path
      full_path = TRIM(root_dir) // '/' // entry_name(1:nlen)

      IF (dtype == 2) THEN
        ! Directory: check exclusion list
        IF (.NOT. should_exclude(entry_name(1:nlen), excl_dirs, n_excl)) THEN
          CALL collect_files(TRIM(full_path), excl_dirs, n_excl, &
                             flist, depth+1, max_depth)
        END IF
      ELSE IF (dtype == 1) THEN
        ! Regular file: add to list
        CALL flist_append(flist, TRIM(full_path))
      END IF
    END DO

    CALL c_closedir(dir_handle)

  END SUBROUTINE collect_files

  ! ---------------------------------------------------------------------------
  ! Append a single path to the file list, growing capacity when needed.
  ! ---------------------------------------------------------------------------
  SUBROUTINE flist_append(flist, path)
    TYPE(FileList),  INTENT(INOUT) :: flist
    CHARACTER(LEN=*),INTENT(IN)    :: path
    CHARACTER(LEN=PATH_LEN), ALLOCATABLE :: tmp(:)
    INTEGER :: new_cap

    ! Grow if necessary
    IF (flist%n >= flist%capacity) THEN
      new_cap = MAX(flist%capacity + CHUNK, 2 * flist%capacity, CHUNK)
      ALLOCATE(tmp(new_cap))
      IF (flist%capacity > 0) THEN
        tmp(1:flist%n) = flist%paths(1:flist%n)
        DEALLOCATE(flist%paths)
      END IF
      CALL MOVE_ALLOC(tmp, flist%paths)
      flist%capacity = new_cap
    END IF

    flist%n = flist%n + 1
    flist%paths(flist%n) = path

  END SUBROUTINE flist_append

  ! ---------------------------------------------------------------------------
  ! Returns .TRUE. if 'name' should be excluded (matches excl_dirs list).
  ! ---------------------------------------------------------------------------
  PURE FUNCTION should_exclude(name, excl_dirs, n_excl) RESULT(excl)
    CHARACTER(LEN=*), INTENT(IN) :: name
    CHARACTER(LEN=64),INTENT(IN) :: excl_dirs(:)
    INTEGER,          INTENT(IN) :: n_excl
    LOGICAL :: excl
    INTEGER :: i
    excl = .FALSE.
    DO i = 1, n_excl
      IF (TRIM(excl_dirs(i)) == TRIM(name)) THEN
        excl = .TRUE.
        RETURN
      END IF
    END DO
  END FUNCTION should_exclude

  ! ---------------------------------------------------------------------------
  ! Convert Fortran string to null-terminated C character array.
  ! ---------------------------------------------------------------------------
  SUBROUTINE to_c_str(fstr, cstr)
    CHARACTER(LEN=*),              INTENT(IN)  :: fstr
    CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(OUT) :: cstr
    INTEGER :: i, n
    n = LEN_TRIM(fstr)
    DO i = 1, n
      cstr(i) = fstr(i:i)
    END DO
    cstr(n+1) = C_NULL_CHAR
  END SUBROUTINE to_c_str

  ! ---------------------------------------------------------------------------
  ! Convert null-terminated C char array to Fortran string.
  ! ---------------------------------------------------------------------------
  FUNCTION from_c_str(cstr, maxlen) RESULT(fstr)
    CHARACTER(KIND=C_CHAR), DIMENSION(*), INTENT(IN) :: cstr
    INTEGER,                              INTENT(IN) :: maxlen
    CHARACTER(LEN=256) :: fstr
    INTEGER :: i
    fstr = ' '
    DO i = 1, MIN(maxlen, 256)
      IF (cstr(i) == C_NULL_CHAR) EXIT
      fstr(i:i) = cstr(i)
    END DO
  END FUNCTION from_c_str

END MODULE floc_cdir
