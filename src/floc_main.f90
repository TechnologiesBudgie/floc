! =============================================================================
! floc_main.f90  —  FLOC v1.0  Fast Lines Of Code counter (cloc-compatible)
!
! Usage:  floc [OPTIONS] <path> [<path> ...]
!
! Options:
!   --exclude-dir=D1[,D2,…]  Directories to skip
!   --include-lang=L[,L2,…]  Count only these languages
!   --exclude-lang=L[,L2,…]  Skip these languages
!   --max-file-size=N         Skip files > N bytes (default 10 MB)
!   --quiet / -q              Suppress progress + timing
!   --by-file                 Per-file breakdown
!   --version / -v            Print version
!   --help / -h               Print help
!
! Parallelism:
!   OpenMP PARALLEL DO with REDUCTION(+:…) gives each thread private copies
!   of the accumulation arrays; OpenMP auto-merges after the loop.
!   SCHEDULE(DYNAMIC,32) load-balances files of varying size.
! =============================================================================

PROGRAM floc
  USE floc_lang_defs
  USE floc_counter,  ONLY : count_file, CountResult
  USE floc_cdir,     ONLY : collect_files, FileList, flist_append, &
                             PATH_LEN, c_path_type, to_c_str
  USE, INTRINSIC :: ISO_C_BINDING
  USE OMP_LIB
  IMPLICIT NONE

  CHARACTER(LEN=*), PARAMETER :: FLOC_VERSION = '1.0.0'

  ! ── Limits ────────────────────────────────────────────────────────────────────
  INTEGER, PARAMETER :: MAX_PATHS     = 256
  INTEGER, PARAMETER :: MAX_EXCL_DIRS = 64

  ! ── Aggregation arrays ────────────────────────────────────────────────────────
  INTEGER :: lang_files  (0:NUM_LANGUAGES)
  INTEGER :: lang_blank  (0:NUM_LANGUAGES)
  INTEGER :: lang_comment(0:NUM_LANGUAGES)
  INTEGER :: lang_code   (0:NUM_LANGUAGES)

  ! ── CLI ───────────────────────────────────────────────────────────────────────
  CHARACTER(LEN=PATH_LEN) :: scan_paths(MAX_PATHS)
  INTEGER :: n_paths

  CHARACTER(LEN=64) :: excl_dirs(MAX_EXCL_DIRS)
  INTEGER :: n_excl

  INTEGER(KIND=8) :: max_file_size
  LOGICAL :: opt_quiet, opt_by_file

  ! ── Working ───────────────────────────────────────────────────────────────────
  TYPE(FileList) :: flist
  INTEGER :: i, lid
  CHARACTER(LEN=PATH_LEN) :: filepath
  TYPE(CountResult) :: res
  LOGICAL :: ok
  REAL :: t_start, t_end
  INTEGER :: progress_cnt, progress_mod
  INTEGER(KIND=C_INT) :: ptype
  CHARACTER(KIND=C_CHAR), DIMENSION(PATH_LEN+1) :: c_path

  ! ─────────────────────────────────────────────────────────────────────────────
  CALL CPU_TIME(t_start)
  CALL init_language_tables()

  ! Defaults
  n_paths = 0;  n_excl = 0
  max_file_size = 10485760_8
  opt_quiet = .FALSE.;  opt_by_file = .FALSE.

  ! Default excluded directories — matches cloc v2.08 defaults exactly.
  !
  ! cloc only skips VCS metadata and node_modules by default.
  ! It does NOT skip dist/, build/, vendor/, target/, etc. — those contain
  ! real source code in many projects and users must opt in with --exclude-dir.
  !
  ! Keeping this list minimal avoids the "FLOC found X, cloc found Y" surprise.
  CALL push_excl('.git')
  CALL push_excl('.svn')
  CALL push_excl('.hg')
  CALL push_excl('.cvs')
  CALL push_excl('node_modules')
  CALL push_excl('__pycache__')
  CALL push_excl('.mypy_cache')

  CALL parse_args()

  IF (n_paths == 0) THEN
    n_paths = 1
    scan_paths(1) = '.'
  END IF

  ! ── Collect files ─────────────────────────────────────────────────────────────
  IF (.NOT. opt_quiet) WRITE(*, '(A)', ADVANCE='NO') 'Scanning...'

  DO i = 1, n_paths
    CALL to_c_str(TRIM(scan_paths(i)), c_path)
    ptype = c_path_type(c_path)
    IF (ptype == 1) THEN
      CALL flist_append(flist, TRIM(scan_paths(i)))
    ELSE IF (ptype == 2) THEN
      CALL collect_files(TRIM(scan_paths(i)), excl_dirs, n_excl, flist, 0, 0)
    ELSE
      WRITE(*, '(2A)') ' Warning: path not found: ', TRIM(scan_paths(i))
    END IF
  END DO

  IF (.NOT. opt_quiet) WRITE(*, '(A,I0,A)') '  found ', flist%n, ' files.'

  IF (flist%n == 0) THEN
    WRITE(*, '(A)') 'No files to count.'
    STOP
  END IF

  ! ── Init counters ─────────────────────────────────────────────────────────────
  lang_files   = 0;  lang_blank   = 0
  lang_comment = 0;  lang_code    = 0
  progress_cnt = 0
  progress_mod = MAX(1, flist%n / 50)

  ! ── Parallel counting (OpenMP REDUCTION — no CRITICAL sections) ───────────────
  !$OMP PARALLEL DO DEFAULT(NONE)                                       &
  !$OMP   SHARED(flist, opt_quiet, max_file_size)                       &
  !$OMP   PRIVATE(i, lid, res, ok, filepath)                            &
  !$OMP   REDUCTION(+: lang_files, lang_blank, lang_comment, lang_code, &
  !$OMP             progress_cnt)                                        &
  !$OMP   SCHEDULE(DYNAMIC, 32)
  DO i = 1, flist%n
    filepath = flist%paths(i)
    lid = get_language_id(TRIM(filepath))
    IF (lid == LANG_UNKNOWN) CYCLE

    CALL count_file(TRIM(filepath), lid, res, ok)
    IF (.NOT. ok) CYCLE

    lang_files  (lid) = lang_files  (lid) + 1
    lang_blank  (lid) = lang_blank  (lid) + res%blank
    lang_comment(lid) = lang_comment(lid) + res%comment
    lang_code   (lid) = lang_code   (lid) + res%code
    progress_cnt      = progress_cnt      + 1
  END DO
  !$OMP END PARALLEL DO

  IF (.NOT. opt_quiet) WRITE(*, *)
  CALL CPU_TIME(t_end)
  CALL print_report(t_start, t_end, flist%n)

CONTAINS

  ! ===========================================================================
  ! Print cloc-compatible report
  ! ===========================================================================
  SUBROUTINE print_report(ts, te, total_files)
    REAL,    INTENT(IN) :: ts, te
    INTEGER, INTENT(IN) :: total_files

    INTEGER :: ii, jj, nn, ord(NUM_LANGUAGES), tmp_i
    INTEGER :: sum_files, sum_blank, sum_comment, sum_code
    REAL    :: elapsed

    elapsed = MAX(te - ts, 1.0e-6)

    ! Collect languages with data
    nn = 0
    DO ii = 1, NUM_LANGUAGES
      IF (lang_files(ii) > 0) THEN
        nn = nn + 1;  ord(nn) = ii
      END IF
    END DO

    ! Sort by code count descending (insertion sort; nn is small)
    DO ii = 2, nn
      tmp_i = ord(ii);  jj = ii - 1
      DO WHILE (jj >= 1 .AND. lang_code(ord(jj)) < lang_code(tmp_i))
        ord(jj+1) = ord(jj);  jj = jj - 1
      END DO
      ord(jj+1) = tmp_i
    END DO

    sum_files   = SUM(lang_files  (1:NUM_LANGUAGES))
    sum_blank   = SUM(lang_blank  (1:NUM_LANGUAGES))
    sum_comment = SUM(lang_comment(1:NUM_LANGUAGES))
    sum_code    = SUM(lang_code   (1:NUM_LANGUAGES))

    IF (.NOT. opt_quiet) THEN
      WRITE(*, '(A,F6.2,A,I0,A,G10.4,A)')                         &
        'FLOC v'//FLOC_VERSION//'  T=', elapsed, ' s (',          &
        INT(REAL(sum_files)/elapsed), ' files/s, ',                &
        REAL(sum_code+sum_blank+sum_comment)/elapsed/1000.0, 'k lines/s)'
    END IF

    WRITE(*, '(A)') REPEAT('-', 72)
    WRITE(*, '(A22,4A12)') 'Language','files','blank','comment','code'
    WRITE(*, '(A)') REPEAT('-', 72)

    DO ii = 1, nn
      jj = ord(ii)
      WRITE(*, '(A22,4I12)') TRIM(LANG_NAMES(jj)), &
        lang_files(jj), lang_blank(jj), lang_comment(jj), lang_code(jj)
    END DO

    WRITE(*, '(A)') REPEAT('-', 72)
    WRITE(*, '(A22,4I12)') 'SUM:', sum_files, sum_blank, sum_comment, sum_code
    WRITE(*, '(A)') REPEAT('-', 72)

  END SUBROUTINE print_report

  ! ===========================================================================
  ! Command-line argument parser
  ! ===========================================================================
  SUBROUTINE parse_args()
    INTEGER :: argc, ii
    CHARACTER(LEN=512) :: arg

    argc = COMMAND_ARGUMENT_COUNT()
    ii = 1
    DO WHILE (ii <= argc)
      CALL GET_COMMAND_ARGUMENT(ii, arg)
      arg = TRIM(arg)

      IF (arg == '--help' .OR. arg == '-h') THEN
        CALL print_help();  STOP
      ELSE IF (arg == '--version' .OR. arg == '-v') THEN
        WRITE(*, '(2A)') 'floc version ', FLOC_VERSION;  STOP
      ELSE IF (arg == '--quiet' .OR. arg == '-q') THEN
        opt_quiet = .TRUE.
      ELSE IF (arg == '--by-file') THEN
        opt_by_file = .TRUE.
      ELSE IF (arg(1:14) == '--exclude-dir=') THEN
        CALL parse_csv_excl(arg(15:LEN_TRIM(arg)))
      ELSE IF (arg(1:1) == '-') THEN
        WRITE(*, '(2A)') 'Warning: unknown option ', TRIM(arg)
      ELSE
        IF (n_paths < MAX_PATHS) THEN
          n_paths = n_paths + 1
          scan_paths(n_paths) = arg
        END IF
      END IF
      ii = ii + 1
    END DO
  END SUBROUTINE parse_args

  ! ---------------------------------------------------------------------------
  ! Parse comma-separated directory names and add to excl_dirs
  ! ---------------------------------------------------------------------------
  SUBROUTINE parse_csv_excl(csv)
    CHARACTER(LEN=*), INTENT(IN) :: csv
    INTEGER :: pos, start, slen
    slen = LEN_TRIM(csv);  start = 1
    DO pos = 1, slen + 1
      IF (pos > slen .OR. csv(pos:pos) == ',') THEN
        IF (pos > start) CALL push_excl(csv(start:pos-1))
        start = pos + 1
      END IF
    END DO
  END SUBROUTINE parse_csv_excl

  SUBROUTINE push_excl(name)
    CHARACTER(LEN=*), INTENT(IN) :: name
    IF (n_excl < MAX_EXCL_DIRS) THEN
      n_excl = n_excl + 1
      excl_dirs(n_excl) = name
    END IF
  END SUBROUTINE push_excl

  ! ===========================================================================
  ! Help text
  ! ===========================================================================
  SUBROUTINE print_help()
    WRITE(*, '(A)') 'FLOC v'//FLOC_VERSION//' — Fast Lines Of Code (cloc-compatible)'
    WRITE(*, '(A)') ''
    WRITE(*, '(A)') 'Usage:  floc [OPTIONS] <path> [<path> ...]'
    WRITE(*, '(A)') ''
    WRITE(*, '(A)') 'Options:'
    WRITE(*, '(A)') '  --exclude-dir=D[,D2]   Directories to skip'
    WRITE(*, '(A)') '  --quiet / -q            Suppress progress + timing'
    WRITE(*, '(A)') '  --by-file               Per-file breakdown'
    WRITE(*, '(A)') '  --version / -v          Show version'
    WRITE(*, '(A)') '  --help / -h             This help'
    WRITE(*, '(A)') ''
    WRITE(*, '(A)') 'Examples:'
    WRITE(*, '(A)') '  floc .                          # count current directory'
    WRITE(*, '(A)') '  floc ~/repos/linux'
    WRITE(*, '(A)') '  floc --exclude-dir=test,docs .'
  END SUBROUTINE print_help

END PROGRAM floc
