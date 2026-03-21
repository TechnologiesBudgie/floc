! =============================================================================
! floc_string_utils.f90
!
! MODULE floc_string_utils
!   Lightweight string helpers tuned for the hot counting loops in
!   floc_counter.f90.  All functions operate on Fortran CHARACTER strings and
!   avoid any heap allocation — only stack-local variables are used.
!
! Performance notes:
!   • str_starts  does a single character-by-character prefix compare starting
!     from a caller-specified offset, which the compiler can auto-vectorise.
!   • find_substr  uses a simple two-pointer scan; for comment delimiters
!     (length 2–4) this is faster than a Boyer–Moore setup.
!   • All helpers are PURE so the compiler can aggressively inline them.
! =============================================================================

MODULE floc_string_utils
  IMPLICIT NONE

CONTAINS

  ! ---------------------------------------------------------------------------
  ! Returns .TRUE. if buf(pos:pos+len(prefix)-1) == prefix.
  ! 'pos' is 1-based index into buf.
  ! ---------------------------------------------------------------------------
  PURE FUNCTION str_starts(buf, blen, pos, prefix) RESULT(ok)
    CHARACTER(LEN=1), INTENT(IN) :: buf(*)
    INTEGER,          INTENT(IN) :: blen, pos
    CHARACTER(LEN=*), INTENT(IN) :: prefix
    LOGICAL :: ok
    INTEGER :: plen, i
    plen = LEN(prefix)
    ok = .FALSE.
    IF (pos + plen - 1 > blen) RETURN
    DO i = 1, plen
      IF (buf(pos + i - 1) /= prefix(i:i)) RETURN
    END DO
    ok = .TRUE.
  END FUNCTION str_starts

  ! ---------------------------------------------------------------------------
  ! Search buf(from:blen) for sub.  Returns position of first match, or 0.
  ! ---------------------------------------------------------------------------
  PURE FUNCTION find_substr(buf, blen, from, sub) RESULT(pos)
    CHARACTER(LEN=1), INTENT(IN) :: buf(*)
    INTEGER,          INTENT(IN) :: blen, from
    CHARACTER(LEN=*), INTENT(IN) :: sub
    INTEGER :: pos
    INTEGER :: slen, i
    slen = LEN(sub)
    pos = 0
    IF (slen == 0) RETURN
    DO i = from, blen - slen + 1
      IF (str_starts(buf, blen, i, sub)) THEN
        pos = i
        RETURN
      END IF
    END DO
  END FUNCTION find_substr

  ! ---------------------------------------------------------------------------
  ! Returns .TRUE. if character c is ASCII whitespace (space, tab, CR, LF).
  ! ---------------------------------------------------------------------------
  PURE FUNCTION is_ws(c) RESULT(ok)
    CHARACTER(LEN=1), INTENT(IN) :: c
    LOGICAL :: ok
    INTEGER :: ic
    ic = ICHAR(c)
    ok = (ic == 32 .OR. ic == 9 .OR. ic == 13 .OR. ic == 10)
  END FUNCTION is_ws

  ! ---------------------------------------------------------------------------
  ! Returns .TRUE. if buf(pos:pos+len-1) is entirely whitespace/blank.
  ! Used to detect blank lines without allocating temporaries.
  ! ---------------------------------------------------------------------------
  PURE FUNCTION line_is_blank(buf, pos, len) RESULT(blank)
    CHARACTER(LEN=1), INTENT(IN) :: buf(*)
    INTEGER,          INTENT(IN) :: pos, len
    LOGICAL :: blank
    INTEGER :: i
    blank = .TRUE.
    DO i = pos, pos + len - 1
      IF (.NOT. is_ws(buf(i))) THEN
        blank = .FALSE.
        RETURN
      END IF
    END DO
  END FUNCTION line_is_blank

  ! ---------------------------------------------------------------------------
  ! Returns the first non-whitespace position in buf(from:blen), or 0.
  ! ---------------------------------------------------------------------------
  PURE FUNCTION skip_ws(buf, blen, from) RESULT(p)
    CHARACTER(LEN=1), INTENT(IN) :: buf(*)
    INTEGER,          INTENT(IN) :: blen, from
    INTEGER :: p
    p = 0
    DO p = from, blen
      IF (.NOT. is_ws(buf(p))) RETURN
    END DO
    p = 0
  END FUNCTION skip_ws

  ! ---------------------------------------------------------------------------
  ! Returns .TRUE. if s1 and s2 are equal ignoring ASCII case.
  ! ---------------------------------------------------------------------------
  PURE FUNCTION streq_nocase(s1, s2) RESULT(ok)
    CHARACTER(LEN=*), INTENT(IN) :: s1, s2
    LOGICAL :: ok
    INTEGER :: n, i, c1, c2
    ok = .FALSE.
    n = LEN_TRIM(s1)
    IF (n /= LEN_TRIM(s2)) RETURN
    DO i = 1, n
      c1 = ICHAR(s1(i:i));  c2 = ICHAR(s2(i:i))
      IF (c1 >= 65 .AND. c1 <= 90) c1 = c1 + 32
      IF (c2 >= 65 .AND. c2 <= 90) c2 = c2 + 32
      IF (c1 /= c2) RETURN
    END DO
    ok = .TRUE.
  END FUNCTION streq_nocase

END MODULE floc_string_utils
