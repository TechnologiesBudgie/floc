! =============================================================================
! floc_counter.f90
!
! MODULE floc_counter
!   The performance-critical heart of FLOC.  For each file it:
!     1. Reads the entire file into a byte buffer in a SINGLE I/O call
!        (ACCESS='STREAM', FORM='UNFORMATTED') — avoids per-line read overhead.
!     2. Runs a hand-written state machine over the raw bytes.
!     3. Returns counts: blank / comment / code lines.
!
! State machine overview
! ──────────────────────
! Each comment style has its own fast-path routine.  All share the same
! core loop structure:
!
!   i = 1
!   DO WHILE (i <= nbytes)
!     c = buf(i)
!     CALL dispatch(state, c, i, line_flags, counts)
!   END DO
!   CALL flush_line(line_flags, counts)
!
! 'line_flags' is a 2-bit register:
!    bit 0 (HAS_CODE)    — non-whitespace, non-comment char seen on this line
!    bit 1 (HAS_COMMENT) — comment marker or content seen on this line
!
! A line is classified when '\n' (or EOF) is encountered:
!   blank   : line_flags == 0  (nothing but whitespace)
!   comment : line_flags has HAS_COMMENT but NOT HAS_CODE
!   code    : line_flags has HAS_CODE  (cloc counts mixed lines as code)
!
! Performance optimisations
! ─────────────────────────
!   • Buffer read is O(file_size) in wall-clock time, not O(line_count).
!   • State dispatch is a SELECT CASE with integer states — branch predictor
!     learns the dominant path (usually "normal code" or "in string").
!   • No Fortran string temporaries are created inside the hot loop.
!   • The outer OpenMP loop (in floc_main.f90) lets multiple files be
!     counted simultaneously across CPU cores.
! =============================================================================

MODULE floc_counter
  USE floc_lang_defs, ONLY : CS_NONE, CS_C, CS_HASH, CS_HTML, CS_PYTHON,  &
                              CS_SQL, CS_LUA, CS_FORTRAN90, CS_RUBY,       &
                              CS_SEMI, CS_HASKELL, CS_CSS, LANG_CS,        &
                              NUM_LANGUAGES
  USE floc_string_utils
  IMPLICIT NONE

  ! Return type
  TYPE :: CountResult
    INTEGER :: blank   = 0
    INTEGER :: comment = 0
    INTEGER :: code    = 0
  END TYPE CountResult

  ! Maximum single-file size to slurp into memory (64 MiB).
  ! Files larger than this are processed in streaming mode (rare for source).
  INTEGER, PARAMETER :: MAX_BUF = 67108864

  ! Line classification flags
  INTEGER, PARAMETER :: HAS_CODE    = 1
  INTEGER, PARAMETER :: HAS_COMMENT = 2

CONTAINS

  ! ===========================================================================
  ! PUBLIC: count lines in one file.
  !   path    — absolute or relative file path
  !   lang_id — language ID from floc_lang_defs
  !   res     — output counts
  !   ok      — .TRUE. on success, .FALSE. if file could not be read
  ! ===========================================================================
  SUBROUTINE count_file(path, lang_id, res, ok)
    CHARACTER(LEN=*), INTENT(IN)  :: path
    INTEGER,          INTENT(IN)  :: lang_id
    TYPE(CountResult),INTENT(OUT) :: res
    LOGICAL,          INTENT(OUT) :: ok

    CHARACTER(LEN=1), ALLOCATABLE :: buf(:)
    INTEGER :: nbytes, cstyle, ios, lu, rec_size
    INTEGER(KIND=8) :: fsize

    res = CountResult(0, 0, 0)
    ok  = .FALSE.

    ! ── Determine comment style ───────────────────────────────────────────────
    IF (lang_id < 0 .OR. lang_id > NUM_LANGUAGES) THEN
      cstyle = CS_NONE
    ELSE
      cstyle = LANG_CS(lang_id)
    END IF

    ! ── Open file and read into buffer ────────────────────────────────────────
    OPEN(NEWUNIT=lu, FILE=TRIM(path), ACCESS='STREAM', FORM='UNFORMATTED', &
         STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN

    ! Probe file size by seeking to end
    INQUIRE(UNIT=lu, SIZE=fsize)
    IF (fsize <= 0) THEN
      CLOSE(lu)
      ok = .TRUE.   ! empty file → all zeros
      RETURN
    END IF

    ! Cap at MAX_BUF; very large files are unusual for source
    nbytes = INT(MIN(fsize, INT(MAX_BUF, KIND=8)))
    ALLOCATE(buf(nbytes), STAT=ios)
    IF (ios /= 0) THEN
      CLOSE(lu)
      RETURN
    END IF

    READ(lu, IOSTAT=ios) buf(1:nbytes)
    CLOSE(lu)
    ! ios /= 0 after partial read is OK (e.g. binary file smaller than fsize)

    ! ── Skip binary files (contain null bytes in first 8 KB) ──────────────────
    !    cloc skips binary files entirely; checking only the first 8 KB keeps
    !    this O(1) rather than O(file_size).
    !    We return ok=.FALSE. so the caller's CYCLE skips lang_files counting.
    IF (is_binary(buf, MIN(nbytes, 8192))) THEN
      DEALLOCATE(buf)
      RETURN   ! ok stays .FALSE. → caller skips this file entirely
    END IF

    ! ── Skip auto-generated files (cloc behaviour) ────────────────────────────
    !    Many tools write a machine-readable marker on the first two lines:
    !      "// Code generated"  — Go protobuf, gRPC, mockgen, stringer, …
    !      "// DO NOT EDIT"     — generic Go generate output
    !      "// @generated"      — JS/TS codegen (Relay, GraphQL)
    !      "# This file is auto-generated" — Python codegen
    !    Checking only the first 256 bytes keeps this essentially free.
    IF (is_generated(buf, MIN(nbytes, 256))) THEN
      DEALLOCATE(buf)
      RETURN   ! ok stays .FALSE. → caller skips this file entirely
    END IF

    ! ── Dispatch to per-style counter ────────────────────────────────────────
    SELECT CASE (cstyle)
      CASE (CS_C)
        CALL count_c_style(buf, nbytes, res)
      CASE (CS_CSS)
        CALL count_css_style(buf, nbytes, res)
      CASE (CS_HASH)
        CALL count_hash_style(buf, nbytes, res)
      CASE (CS_HTML)
        CALL count_html_style(buf, nbytes, res)
      CASE (CS_PYTHON)
        CALL count_python_style(buf, nbytes, res)
      CASE (CS_SQL)
        CALL count_sql_style(buf, nbytes, res)
      CASE (CS_LUA)
        CALL count_lua_style(buf, nbytes, res)
      CASE (CS_FORTRAN90)
        CALL count_fortran_style(buf, nbytes, res)
      CASE (CS_RUBY)
        CALL count_ruby_style(buf, nbytes, res)
      CASE (CS_SEMI)
        CALL count_semi_style(buf, nbytes, res)
      CASE (CS_HASKELL)
        CALL count_haskell_style(buf, nbytes, res)
      CASE DEFAULT
        ! CS_NONE (JSON, Markdown): every non-blank line is code
        CALL count_no_comments(buf, nbytes, res)
    END SELECT

    DEALLOCATE(buf)
    ok = .TRUE.

  END SUBROUTINE count_file

  ! ===========================================================================
  ! CS_C  —  // line comments  +  /* */ block comments
  !          Strings " and ' suppress comment detection.
  !
  !  States:
  !    0 = normal
  !    1 = in line comment  (//)
  !    2 = in block comment (/* */)
  !    3 = in double-quoted string
  !    4 = in single-quoted string
  !    5 = escape in double-quoted string
  !    6 = escape in single-quoted string
  ! ===========================================================================
  SUBROUTINE count_c_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c, cnext

    state = 0
    lf    = 0   ! line flags

    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      IF (i < n) THEN
        cnext = buf(i+1)
      ELSE
        cnext = CHAR(0)
      END IF

      SELECT CASE (state)

        ! ── Normal ────────────────────────────────────────────────────────────
        CASE (0)
          SELECT CASE (ICHAR(c))
            CASE (10)  ! \n
              CALL flush_line(lf, res);  lf = 0
            CASE (47)  ! /
              IF (cnext == '/') THEN
                state = 1     ! start line comment
                i = i + 1    ! consume second /
                lf = IOR(lf, HAS_COMMENT)
              ELSE IF (cnext == '*') THEN
                state = 2
                i = i + 1
                lf = IOR(lf, HAS_COMMENT)
              ELSE
                IF (.NOT. is_ws(c)) lf = IOR(lf, HAS_CODE)
              END IF
            CASE (34)  ! "
              state = 3
              lf = IOR(lf, HAS_CODE)
            CASE (39)  ! '
              state = 4
              lf = IOR(lf, HAS_CODE)
            CASE (9, 13, 32)  ! whitespace (not newline)
              ! do nothing
            CASE DEFAULT
              lf = IOR(lf, HAS_CODE)
          END SELECT

        ! ── Line comment ──────────────────────────────────────────────────────
        CASE (1)
          IF (ICHAR(c) == 10) THEN   ! \n ends line comment
            CALL flush_line(lf, res);  lf = 0
            state = 0
          ELSE
            lf = IOR(lf, HAS_COMMENT)
          END IF

        ! ── Block comment ─────────────────────────────────────────────────────
        CASE (2)
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT  ! carry into next line
          ELSE IF (c == '*' .AND. cnext == '/') THEN
            state = 0
            i = i + 1           ! consume /
          END IF

        ! ── Double-quoted string ──────────────────────────────────────────────
        CASE (3)
          lf = IOR(lf, HAS_CODE)
          IF (c == '\') THEN
            state = 5
          ELSE IF (ICHAR(c) == 34) THEN
            state = 0
          ELSE IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
            state = 0
          END IF

        ! ── Single-quoted string ──────────────────────────────────────────────
        CASE (4)
          lf = IOR(lf, HAS_CODE)
          IF (c == '\') THEN
            state = 6
          ELSE IF (ICHAR(c) == 39) THEN
            state = 0
          ELSE IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
            state = 0
          END IF

        ! ── Escape in double-quoted string ────────────────────────────────────
        CASE (5)
          lf = IOR(lf, HAS_CODE)
          state = 3

        ! ── Escape in single-quoted string ────────────────────────────────────
        CASE (6)
          lf = IOR(lf, HAS_CODE)
          state = 4

      END SELECT
      i = i + 1
    END DO

    ! Flush last line if file doesn't end with newline
    IF (lf /= 0) CALL flush_line(lf, res)

  END SUBROUTINE count_c_style

  ! ===========================================================================
  ! CS_CSS  —  /* */ block comments ONLY (no //)
  ! ===========================================================================
  SUBROUTINE count_css_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c, cnext

    state = 0;  lf = 0
    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      cnext = MERGE(buf(i+1), CHAR(0), i < n)

      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '/' .AND. cnext == '*') THEN
            state = 1;  i = i + 1
            lf = IOR(lf, HAS_COMMENT)
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF
        CASE (1)   ! in block comment
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (c == '*' .AND. cnext == '/') THEN
            state = 0;  i = i + 1
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_css_style

  ! ===========================================================================
  ! CS_HASH  —  # line comments only  (Shell, YAML, TOML, R, Makefile, …)
  ! ===========================================================================
  SUBROUTINE count_hash_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c

    ! at_bol tracks whether we are at the first non-ws char of a line.
    ! Needed for shebang detection: #! at position 1 of line 1 is code.
    LOGICAL :: at_bol_hash
    INTEGER :: line_num_hash

    state = 0;  lf = 0;  at_bol_hash = .TRUE.;  line_num_hash = 1
    DO i = 1, n
      c = buf(i)
      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
            at_bol_hash = .TRUE.;  line_num_hash = line_num_hash + 1
          ELSE IF (c == '#') THEN
            ! Shebang (#!) on line 1 counts as code, like cloc
            IF (at_bol_hash .AND. line_num_hash == 1 .AND. &
                str_starts(buf, n, i, '#!')) THEN
              lf = IOR(lf, HAS_CODE);  state = 1   ! skip rest of shebang line
            ELSE
              state = 1;  lf = IOR(lf, HAS_COMMENT)
            END IF
            at_bol_hash = .FALSE.
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE);  at_bol_hash = .FALSE.
          END IF
        CASE (1)   ! in line comment (or shebang remainder)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
            at_bol_hash = .TRUE.;  line_num_hash = line_num_hash + 1
          END IF
      END SELECT
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_hash_style

  ! ===========================================================================
  ! CS_HTML  —  <!-- --> block comments (HTML, XML, Vue)
  !  States: 0=normal, 1=saw '<', 2=saw '<!', 3=saw '<!-', 4=in comment,
  !          5=saw '*' in comment (potential end), 6=saw '-', 7=saw '--'
  ! ===========================================================================
  SUBROUTINE count_html_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c

    state = 0;  lf = 0
    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '<') THEN
            ! Peek ahead for <!--
            IF (str_starts(buf, n, i, '<!--')) THEN
              state = 4;  i = i + 3
              lf = IOR(lf, HAS_COMMENT)
            ELSE
              lf = IOR(lf, HAS_CODE)
            END IF
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF
        CASE (4)   ! in HTML comment
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (str_starts(buf, n, i, '-->')) THEN
            state = 0;  i = i + 2
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_html_style

  ! ===========================================================================
  ! CS_PYTHON  —  # line comments + """ / ''' triple-quote block comments
  !  States: 0=normal, 1=line comment, 2=in """block""", 3=in '''block'''
  !          4=in "string", 5=in 'string'
  ! ===========================================================================
  SUBROUTINE count_python_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c

    state = 0;  lf = 0
    i = 1
    DO WHILE (i <= n)
      c = buf(i)

      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '#') THEN
            state = 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (c == '"') THEN
            IF (str_starts(buf, n, i, '"""')) THEN
              state = 2;  i = i + 2
              lf = IOR(lf, HAS_COMMENT)
            ELSE
              state = 4;  lf = IOR(lf, HAS_CODE)
            END IF
          ELSE IF (c == CHAR(39)) THEN   ! '
            IF (str_starts(buf, n, i, "'''")) THEN
              state = 3;  i = i + 2
              lf = IOR(lf, HAS_COMMENT)
            ELSE
              state = 5;  lf = IOR(lf, HAS_CODE)
            END IF
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF

        CASE (1)   ! line comment
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF

        CASE (2)   ! """ block
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (str_starts(buf, n, i, '"""')) THEN
            state = 0;  i = i + 2
          END IF

        CASE (3)   ! ''' block
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (str_starts(buf, n, i, "'''")) THEN
            state = 0;  i = i + 2
          END IF

        CASE (4)   ! "string"
          lf = IOR(lf, HAS_CODE)
          IF (c == '\') THEN
            i = i + 1   ! skip escaped char
          ELSE IF (c == '"') THEN
            state = 0
          ELSE IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF

        CASE (5)   ! 'string'
          lf = IOR(lf, HAS_CODE)
          IF (c == '\') THEN
            i = i + 1
          ELSE IF (c == CHAR(39)) THEN
            state = 0
          ELSE IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_python_style

  ! ===========================================================================
  ! CS_SQL  —  -- line comments  +  /* */ block comments
  ! ===========================================================================
  SUBROUTINE count_sql_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c, cnext

    state = 0;  lf = 0
    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      cnext = MERGE(buf(i+1), CHAR(0), i < n)

      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '-' .AND. cnext == '-') THEN
            state = 1;  i = i + 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (c == '/' .AND. cnext == '*') THEN
            state = 2;  i = i + 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF
        CASE (1)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF
        CASE (2)
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (c == '*' .AND. cnext == '/') THEN
            state = 0;  i = i + 1
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_sql_style

  ! ===========================================================================
  ! CS_LUA  —  -- line comments  +  --[[ ]] block comments
  ! ===========================================================================
  SUBROUTINE count_lua_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c, cnext

    state = 0;  lf = 0
    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      cnext = MERGE(buf(i+1), CHAR(0), i < n)

      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '-' .AND. cnext == '-') THEN
            ! Check for --[[
            IF (str_starts(buf, n, i, '--[[')) THEN
              state = 2;  i = i + 3;  lf = IOR(lf, HAS_COMMENT)
            ELSE
              state = 1;  i = i + 1;  lf = IOR(lf, HAS_COMMENT)
            END IF
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF
        CASE (1)   ! line comment
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF
        CASE (2)   ! block comment
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (str_starts(buf, n, i, ']]')) THEN
            state = 0;  i = i + 1
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_lua_style

  ! ===========================================================================
  ! CS_FORTRAN90  —  ! line comment, suppressed inside string literals.
  !
  !  States:
  !    0  normal code
  !    1  in ! comment (to end of line)
  !    2  in double-quoted string  ("…")
  !    3  in single-quoted string  ('…')  — Fortran character literals
  !
  !  cloc quirk matched: a ! inside "string" or 'string' is NOT a comment.
  !  e.g.:  WRITE(*,'(A)') "Hello ! World"  → code line, not comment.
  ! ===========================================================================
  SUBROUTINE count_fortran_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c

    state = 0;  lf = 0
    DO i = 1, n
      c = buf(i)
      SELECT CASE (state)

        ! ── Normal ────────────────────────────────────────────────────────────
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '!') THEN
            state = 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (ICHAR(c) == 34) THEN      ! " opens string
            state = 2;  lf = IOR(lf, HAS_CODE)
          ELSE IF (ICHAR(c) == 39) THEN      ! ' opens character literal
            state = 3;  lf = IOR(lf, HAS_CODE)
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF

        ! ── In ! comment ─────────────────────────────────────────────────────
        CASE (1)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF

        ! ── In double-quoted string ───────────────────────────────────────────
        ! Fortran strings double the delimiter to escape: "it""s" = it"s
        CASE (2)
          lf = IOR(lf, HAS_CODE)
          IF (ICHAR(c) == 34) THEN      ! closing "
            state = 0
          ELSE IF (ICHAR(c) == 10) THEN ! unterminated string — treat as end
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF

        ! ── In single-quoted character literal ───────────────────────────────
        CASE (3)
          lf = IOR(lf, HAS_CODE)
          IF (ICHAR(c) == 39) THEN      ! closing '
            state = 0
          ELSE IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF

      END SELECT
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_fortran_style

  ! ===========================================================================
  ! CS_RUBY  —  # line comments  +  =begin / =end block (Ruby/Perl)
  ! ===========================================================================
  SUBROUTINE count_ruby_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    LOGICAL :: at_bol   ! at beginning of line
    CHARACTER(LEN=1) :: c

    state = 0;  lf = 0;  at_bol = .TRUE.
    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  at_bol = .TRUE.
          ELSE IF (at_bol .AND. str_starts(buf, n, i, '=begin')) THEN
            state = 2;  lf = IOR(lf, HAS_COMMENT)
            ! skip to end of line
            DO WHILE (i <= n .AND. ICHAR(buf(i)) /= 10)
              i = i + 1
            END DO
            CYCLE
          ELSE IF (c == '#') THEN
            state = 1;  lf = IOR(lf, HAS_COMMENT);  at_bol = .FALSE.
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE);  at_bol = .FALSE.
          END IF
        CASE (1)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0;  at_bol = .TRUE.
          END IF
        CASE (2)   ! =begin block
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT;  at_bol = .TRUE.
          ELSE IF (at_bol .AND. str_starts(buf, n, i, '=end')) THEN
            state = 0
            DO WHILE (i <= n .AND. ICHAR(buf(i)) /= 10)
              i = i + 1
            END DO
            CALL flush_line(lf, res);  lf = 0;  at_bol = .TRUE.
            CYCLE
          ELSE
            at_bol = .FALSE.
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_ruby_style

  ! ===========================================================================
  ! CS_SEMI  —  ; line comments (Assembly, some INI)
  ! ===========================================================================
  SUBROUTINE count_semi_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c

    state = 0;  lf = 0
    DO i = 1, n
      c = buf(i)
      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == ';') THEN
            state = 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF
        CASE (1)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF
      END SELECT
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_semi_style

  ! ===========================================================================
  ! CS_HASKELL  —  -- line  +  {- -} block
  ! ===========================================================================
  SUBROUTINE count_haskell_style(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: state, i, lf
    CHARACTER(LEN=1) :: c, cnext

    state = 0;  lf = 0
    i = 1
    DO WHILE (i <= n)
      c = buf(i)
      cnext = MERGE(buf(i+1), CHAR(0), i < n)

      SELECT CASE (state)
        CASE (0)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0
          ELSE IF (c == '-' .AND. cnext == '-') THEN
            state = 1;  i = i + 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (c == '{' .AND. cnext == '-') THEN
            state = 2;  i = i + 1;  lf = IOR(lf, HAS_COMMENT)
          ELSE IF (.NOT. is_ws(c)) THEN
            lf = IOR(lf, HAS_CODE)
          END IF
        CASE (1)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = 0;  state = 0
          END IF
        CASE (2)
          lf = IOR(lf, HAS_COMMENT)
          IF (ICHAR(c) == 10) THEN
            CALL flush_line(lf, res);  lf = HAS_COMMENT
          ELSE IF (c == '-' .AND. cnext == '}') THEN
            state = 0;  i = i + 1
          END IF
      END SELECT
      i = i + 1
    END DO
    IF (lf /= 0) CALL flush_line(lf, res)
  END SUBROUTINE count_haskell_style

  ! ===========================================================================
  ! CS_NONE  —  no comment syntax (JSON, plain Markdown, binary-like)
  ! ===========================================================================
  SUBROUTINE count_no_comments(buf, n, res)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    TYPE(CountResult),INTENT(INOUT) :: res

    INTEGER :: i, lf
    CHARACTER(LEN=1) :: c

    lf = 0
    DO i = 1, n
      c = buf(i)
      IF (ICHAR(c) == 10) THEN
        IF (lf == 0) THEN
          res%blank = res%blank + 1
        ELSE
          res%code  = res%code  + 1
        END IF
        lf = 0
      ELSE IF (.NOT. is_ws(c)) THEN
        lf = 1
      END IF
    END DO
    IF (lf /= 0) res%code = res%code + 1
  END SUBROUTINE count_no_comments

  ! ===========================================================================
  ! PRIVATE: is_binary — returns .TRUE. if buf(1:n) contains a NUL byte.
  !   Checks at most the first n bytes; n should be capped at ~8 KB.
  ! ===========================================================================
  PURE FUNCTION is_binary(buf, n) RESULT(bin)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    LOGICAL :: bin
    INTEGER :: i
    bin = .FALSE.
    DO i = 1, n
      IF (ICHAR(buf(i)) == 0) THEN
        bin = .TRUE.
        RETURN
      END IF
    END DO
  END FUNCTION is_binary

  ! ===========================================================================
  ! PRIVATE: is_generated — returns .TRUE. if the file header contains a
  !   standard auto-generation marker used by cloc to skip generated files.
  !
  !   Checked markers (any of these in the first 256 bytes → skip):
  !     "Code generated"     ← Go: protobuf, gRPC, stringer, mockgen
  !     "DO NOT EDIT"        ← Go: generic generate marker
  !     "@generated"         ← JS/TS: Relay, GraphQL codegen, Babel
  !     "auto-generated"     ← Python, various tools
  !     "AUTOMATICALLY GENERATED" ← protobuf Python, Thrift
  !
  !   Case-insensitive check on the first 256 bytes only.
  ! ===========================================================================
  PURE FUNCTION is_generated(buf, n) RESULT(gen)
    CHARACTER(LEN=1), INTENT(IN) :: buf(:)
    INTEGER,          INTENT(IN) :: n
    LOGICAL :: gen

    CHARACTER(LEN=256) :: header
    INTEGER :: i, c

    gen = .FALSE.
    IF (n < 1) RETURN

    ! Build lower-case copy of first n bytes
    DO i = 1, n
      c = ICHAR(buf(i))
      IF (c >= 65 .AND. c <= 90) c = c + 32   ! upper → lower
      header(i:i) = CHAR(c)
    END DO

    ! Check substrings
    IF (INDEX(header(1:n), 'code generated')    /= 0) THEN; gen = .TRUE.; RETURN; END IF
    IF (INDEX(header(1:n), 'do not edit')       /= 0) THEN; gen = .TRUE.; RETURN; END IF
    IF (INDEX(header(1:n), '@generated')        /= 0) THEN; gen = .TRUE.; RETURN; END IF
    IF (INDEX(header(1:n), 'auto-generated')    /= 0) THEN; gen = .TRUE.; RETURN; END IF
    IF (INDEX(header(1:n), 'automatically generated') /= 0) THEN; gen = .TRUE.; RETURN; END IF

  END FUNCTION is_generated

  ! ===========================================================================
  ! PRIVATE: flush accumulated line flags into counts.
  !   lf == 0           → blank line
  !   lf has HAS_CODE   → code line  (inline comment still counts as code)
  !   lf has COMMENT only → comment line
  ! ===========================================================================
  SUBROUTINE flush_line(lf, res)
    INTEGER,          INTENT(IN)    :: lf
    TYPE(CountResult),INTENT(INOUT) :: res
    IF (lf == 0) THEN
      res%blank   = res%blank   + 1
    ELSE IF (IAND(lf, HAS_CODE) /= 0) THEN
      res%code    = res%code    + 1
    ELSE
      res%comment = res%comment + 1
    END IF
  END SUBROUTINE flush_line

END MODULE floc_counter
