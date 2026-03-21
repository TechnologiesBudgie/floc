! =============================================================================
! floc_lang_defs.f90
!
! MODULE floc_lang_defs
!   Language ID constants, language name strings, comment-style tags,
!   and a sorted extension-to-language lookup table with binary search.
!
! Design notes:
!   • Extensions are stored in a sorted array so get_language_id() does
!     O(log N) binary search instead of O(N) linear scan.
!   • Comment-style tags drive the counting state-machine in floc_counter.f90
!     without any per-language special-casing inside the hot loop.
!   • Language IDs are simple INTEGER constants so the compiler can inline
!     all comparisons without indirection.
! =============================================================================

MODULE floc_lang_defs
  IMPLICIT NONE

  ! ─── Language IDs ──────────────────────────────────────────────────────────
  INTEGER, PARAMETER :: LANG_UNKNOWN    =  0
  INTEGER, PARAMETER :: LANG_C          =  1
  INTEGER, PARAMETER :: LANG_CPP        =  2
  INTEGER, PARAMETER :: LANG_CHEADER    =  3
  INTEGER, PARAMETER :: LANG_JAVA       =  4
  INTEGER, PARAMETER :: LANG_JAVASCRIPT =  5
  INTEGER, PARAMETER :: LANG_TYPESCRIPT =  6
  INTEGER, PARAMETER :: LANG_GO         =  7
  INTEGER, PARAMETER :: LANG_PYTHON     =  8
  INTEGER, PARAMETER :: LANG_RUBY       =  9
  INTEGER, PARAMETER :: LANG_PERL       = 10
  INTEGER, PARAMETER :: LANG_SHELL      = 11
  INTEGER, PARAMETER :: LANG_BASH       = 12
  INTEGER, PARAMETER :: LANG_HTML       = 13
  INTEGER, PARAMETER :: LANG_XML        = 14
  INTEGER, PARAMETER :: LANG_CSS        = 15
  INTEGER, PARAMETER :: LANG_JSON       = 16
  INTEGER, PARAMETER :: LANG_YAML       = 17
  INTEGER, PARAMETER :: LANG_MARKDOWN   = 18
  INTEGER, PARAMETER :: LANG_SQL        = 19
  INTEGER, PARAMETER :: LANG_RUST       = 20
  INTEGER, PARAMETER :: LANG_KOTLIN     = 21
  INTEGER, PARAMETER :: LANG_SWIFT      = 22
  INTEGER, PARAMETER :: LANG_PHP        = 23
  INTEGER, PARAMETER :: LANG_CSHARP     = 24
  INTEGER, PARAMETER :: LANG_FORTRAN_SRC= 25
  INTEGER, PARAMETER :: LANG_MAKEFILE   = 26
  INTEGER, PARAMETER :: LANG_DOCKERFILE = 27
  INTEGER, PARAMETER :: LANG_LUA        = 28
  INTEGER, PARAMETER :: LANG_SCALA      = 29
  INTEGER, PARAMETER :: LANG_R_LANG     = 30
  INTEGER, PARAMETER :: LANG_TOML       = 31
  INTEGER, PARAMETER :: LANG_INI        = 32
  INTEGER, PARAMETER :: LANG_ASSEMBLY   = 33
  INTEGER, PARAMETER :: LANG_VUE        = 34
  INTEGER, PARAMETER :: LANG_TERRAFORM  = 35
  INTEGER, PARAMETER :: LANG_GROOVY     = 36
  INTEGER, PARAMETER :: LANG_DART       = 37
  INTEGER, PARAMETER :: LANG_ELIXIR     = 38
  INTEGER, PARAMETER :: LANG_HASKELL    = 39
  INTEGER, PARAMETER :: LANG_OCAML      = 40
  INTEGER, PARAMETER :: NUM_LANGUAGES   = 40

  ! ─── Comment style IDs (one per counting algorithm) ─────────────────────────
  ! These map directly to state-machine dispatch in floc_counter.f90
  INTEGER, PARAMETER :: CS_NONE       = 0   ! JSON, Markdown – no comments
  INTEGER, PARAMETER :: CS_C          = 1   ! // line  +  /* */ block  (C,C++,Java,Go,JS,TS,Rust,…)
  INTEGER, PARAMETER :: CS_HASH       = 2   ! # line only              (Shell,YAML,TOML,R,Make,…)
  INTEGER, PARAMETER :: CS_HTML       = 3   ! <!-- --> block           (HTML,XML)
  INTEGER, PARAMETER :: CS_PYTHON     = 4   ! # line + """triple""" block
  INTEGER, PARAMETER :: CS_SQL        = 5   ! -- line  +  /* */ block
  INTEGER, PARAMETER :: CS_LUA        = 6   ! -- line  + --[[ ]] block
  INTEGER, PARAMETER :: CS_FORTRAN90  = 7   ! ! line only
  INTEGER, PARAMETER :: CS_RUBY       = 8   ! # line  + =begin/=end block
  INTEGER, PARAMETER :: CS_SEMI       = 9   ! ; line only              (Assembly, INI)
  INTEGER, PARAMETER :: CS_HASKELL    = 10  ! -- line  + {- -} block
  INTEGER, PARAMETER :: CS_CSS        = 11  ! /* */ block ONLY (no //)

  ! ─── Lookup tables (module-level, set once by init_language_tables) ──────────
  INTEGER, PARAMETER :: MAX_EXT = 150

  CHARACTER(LEN=12), DIMENSION(MAX_EXT) :: EXT_TABLE
  INTEGER,           DIMENSION(MAX_EXT) :: EXT_LANG
  INTEGER :: NUM_EXT = 0

  CHARACTER(LEN=22), DIMENSION(0:NUM_LANGUAGES) :: LANG_NAMES
  INTEGER,           DIMENSION(0:NUM_LANGUAGES) :: LANG_CS      ! comment style

CONTAINS

  ! ---------------------------------------------------------------------------
  ! PUBLIC: initialise all tables — call once before any other function
  ! ---------------------------------------------------------------------------
  SUBROUTINE init_language_tables()
    IMPLICIT NONE

    ! ── Language names ────────────────────────────────────────────────────────
    LANG_NAMES(LANG_UNKNOWN)    = 'Unknown'
    LANG_NAMES(LANG_C)          = 'C'
    LANG_NAMES(LANG_CPP)        = 'C++'
    LANG_NAMES(LANG_CHEADER)    = 'C/C++ Header'
    LANG_NAMES(LANG_JAVA)       = 'Java'
    LANG_NAMES(LANG_JAVASCRIPT) = 'JavaScript'
    LANG_NAMES(LANG_TYPESCRIPT) = 'TypeScript'
    LANG_NAMES(LANG_GO)         = 'Go'
    LANG_NAMES(LANG_PYTHON)     = 'Python'
    LANG_NAMES(LANG_RUBY)       = 'Ruby'
    LANG_NAMES(LANG_PERL)       = 'Perl'
    LANG_NAMES(LANG_SHELL)      = 'Bourne Shell'
    LANG_NAMES(LANG_BASH)       = 'Bourne Again Shell'
    LANG_NAMES(LANG_HTML)       = 'HTML'
    LANG_NAMES(LANG_XML)        = 'XML'
    LANG_NAMES(LANG_CSS)        = 'CSS'
    LANG_NAMES(LANG_JSON)       = 'JSON'
    LANG_NAMES(LANG_YAML)       = 'YAML'
    LANG_NAMES(LANG_MARKDOWN)   = 'Markdown'
    LANG_NAMES(LANG_SQL)        = 'SQL'
    LANG_NAMES(LANG_RUST)       = 'Rust'
    LANG_NAMES(LANG_KOTLIN)     = 'Kotlin'
    LANG_NAMES(LANG_SWIFT)      = 'Swift'
    LANG_NAMES(LANG_PHP)        = 'PHP'
    LANG_NAMES(LANG_CSHARP)     = 'C#'
    LANG_NAMES(LANG_FORTRAN_SRC)= 'Fortran 90'
    LANG_NAMES(LANG_MAKEFILE)   = 'make'
    LANG_NAMES(LANG_DOCKERFILE) = 'Dockerfile'
    LANG_NAMES(LANG_LUA)        = 'Lua'
    LANG_NAMES(LANG_SCALA)      = 'Scala'
    LANG_NAMES(LANG_R_LANG)     = 'R'
    LANG_NAMES(LANG_TOML)       = 'TOML'
    LANG_NAMES(LANG_INI)        = 'INI'
    LANG_NAMES(LANG_ASSEMBLY)   = 'Assembly'
    LANG_NAMES(LANG_VUE)        = 'Vuejs'
    LANG_NAMES(LANG_TERRAFORM)  = 'Terraform'
    LANG_NAMES(LANG_GROOVY)     = 'Groovy'
    LANG_NAMES(LANG_DART)       = 'Dart'
    LANG_NAMES(LANG_ELIXIR)     = 'Elixir'
    LANG_NAMES(LANG_HASKELL)    = 'Haskell'
    LANG_NAMES(LANG_OCAML)      = 'OCaml'

    ! ── Comment styles ────────────────────────────────────────────────────────
    LANG_CS(LANG_UNKNOWN)    = CS_NONE
    LANG_CS(LANG_C)          = CS_C
    LANG_CS(LANG_CPP)        = CS_C
    LANG_CS(LANG_CHEADER)    = CS_C
    LANG_CS(LANG_JAVA)       = CS_C
    LANG_CS(LANG_JAVASCRIPT) = CS_C
    LANG_CS(LANG_TYPESCRIPT) = CS_C
    LANG_CS(LANG_GO)         = CS_C
    LANG_CS(LANG_PYTHON)     = CS_PYTHON
    LANG_CS(LANG_RUBY)       = CS_RUBY
    LANG_CS(LANG_PERL)       = CS_RUBY    ! # + =pod/=cut (modelled same as Ruby)
    LANG_CS(LANG_SHELL)      = CS_HASH
    LANG_CS(LANG_BASH)       = CS_HASH
    LANG_CS(LANG_HTML)       = CS_HTML
    LANG_CS(LANG_XML)        = CS_HTML
    LANG_CS(LANG_CSS)        = CS_CSS
    LANG_CS(LANG_JSON)       = CS_NONE
    LANG_CS(LANG_YAML)       = CS_HASH
    LANG_CS(LANG_MARKDOWN)   = CS_NONE
    LANG_CS(LANG_SQL)        = CS_SQL
    LANG_CS(LANG_RUST)       = CS_C
    LANG_CS(LANG_KOTLIN)     = CS_C
    LANG_CS(LANG_SWIFT)      = CS_C
    LANG_CS(LANG_PHP)        = CS_C
    LANG_CS(LANG_CSHARP)     = CS_C
    LANG_CS(LANG_FORTRAN_SRC)= CS_FORTRAN90
    LANG_CS(LANG_MAKEFILE)   = CS_HASH
    LANG_CS(LANG_DOCKERFILE) = CS_HASH
    LANG_CS(LANG_LUA)        = CS_LUA
    LANG_CS(LANG_SCALA)      = CS_C
    LANG_CS(LANG_R_LANG)     = CS_HASH
    LANG_CS(LANG_TOML)       = CS_HASH
    LANG_CS(LANG_INI)        = CS_SEMI
    LANG_CS(LANG_ASSEMBLY)   = CS_SEMI
    LANG_CS(LANG_VUE)        = CS_HTML
    LANG_CS(LANG_TERRAFORM)  = CS_HASH
    LANG_CS(LANG_GROOVY)     = CS_C
    LANG_CS(LANG_DART)       = CS_C
    LANG_CS(LANG_ELIXIR)     = CS_HASH
    LANG_CS(LANG_HASKELL)    = CS_HASKELL
    LANG_CS(LANG_OCAML)      = CS_C       ! (* *) treated same as /* */

    ! ── Extension table (will be sorted by sort_ext_table) ───────────────────
    !    C / C++
    CALL ae('c',       LANG_C)
    CALL ae('ec',      LANG_C)
    CALL ae('pgc',     LANG_C)
    CALL ae('cpp',     LANG_CPP)
    CALL ae('cxx',     LANG_CPP)
    CALL ae('cc',      LANG_CPP)
    CALL ae('c++',     LANG_CPP)
    CALL ae('h',       LANG_CHEADER)
    CALL ae('hpp',     LANG_CHEADER)
    CALL ae('hxx',     LANG_CHEADER)
    CALL ae('hh',      LANG_CHEADER)
    CALL ae('inl',     LANG_CHEADER)
    !    Java / JVM
    CALL ae('java',    LANG_JAVA)
    CALL ae('kt',      LANG_KOTLIN)
    CALL ae('kts',     LANG_KOTLIN)
    CALL ae('scala',   LANG_SCALA)
    CALL ae('groovy',  LANG_GROOVY)
    CALL ae('gvy',     LANG_GROOVY)
    !    JavaScript / TypeScript
    CALL ae('js',      LANG_JAVASCRIPT)
    CALL ae('mjs',     LANG_JAVASCRIPT)
    CALL ae('cjs',     LANG_JAVASCRIPT)
    CALL ae('jsx',     LANG_JAVASCRIPT)
    CALL ae('ts',      LANG_TYPESCRIPT)
    CALL ae('tsx',     LANG_TYPESCRIPT)
    CALL ae('mts',     LANG_TYPESCRIPT)
    CALL ae('cts',     LANG_TYPESCRIPT)
    CALL ae('vue',     LANG_VUE)
    !    Go
    CALL ae('go',      LANG_GO)
    !    Python
    CALL ae('py',      LANG_PYTHON)
    CALL ae('py3',     LANG_PYTHON)
    CALL ae('pyw',     LANG_PYTHON)
    CALL ae('pyi',     LANG_PYTHON)
    !    Ruby / Perl
    CALL ae('rb',      LANG_RUBY)
    CALL ae('rbw',     LANG_RUBY)
    CALL ae('pl',      LANG_PERL)
    CALL ae('pm',      LANG_PERL)
    !    Shell
    CALL ae('sh',      LANG_SHELL)
    CALL ae('ksh',     LANG_SHELL)
    CALL ae('fish',    LANG_SHELL)
    CALL ae('bash',    LANG_BASH)
    CALL ae('zsh',     LANG_BASH)
    !    Web / markup
    CALL ae('html',    LANG_HTML)
    CALL ae('htm',     LANG_HTML)
    CALL ae('xhtml',   LANG_HTML)
    CALL ae('xml',     LANG_XML)
    CALL ae('svg',     LANG_XML)
    CALL ae('xsl',     LANG_XML)
    CALL ae('xslt',    LANG_XML)
    CALL ae('css',     LANG_CSS)
    CALL ae('scss',    LANG_CSS)
    CALL ae('sass',    LANG_CSS)
    CALL ae('less',    LANG_CSS)
    !    Data formats
    CALL ae('json',    LANG_JSON)
    CALL ae('jsonl',   LANG_JSON)
    CALL ae('yaml',    LANG_YAML)
    CALL ae('yml',     LANG_YAML)
    CALL ae('toml',    LANG_TOML)
    CALL ae('ini',     LANG_INI)
    CALL ae('cfg',     LANG_INI)
    CALL ae('conf',    LANG_INI)
    !    Documentation
    CALL ae('md',      LANG_MARKDOWN)
    CALL ae('markdown',LANG_MARKDOWN)
    CALL ae('rst',     LANG_MARKDOWN)
    CALL ae('txt',     LANG_MARKDOWN)
    !    Database
    CALL ae('sql',     LANG_SQL)
    CALL ae('pgsql',   LANG_SQL)
    CALL ae('mysql',   LANG_SQL)
    !    Systems / compiled
    CALL ae('rs',      LANG_RUST)
    CALL ae('swift',   LANG_SWIFT)
    CALL ae('dart',    LANG_DART)
    CALL ae('php',     LANG_PHP)
    CALL ae('php3',    LANG_PHP)
    CALL ae('php4',    LANG_PHP)
    CALL ae('php5',    LANG_PHP)
    CALL ae('php7',    LANG_PHP)
    CALL ae('cs',      LANG_CSHARP)
    !    Fortran
    CALL ae('f',       LANG_FORTRAN_SRC)
    CALL ae('f90',     LANG_FORTRAN_SRC)
    CALL ae('f95',     LANG_FORTRAN_SRC)
    CALL ae('f03',     LANG_FORTRAN_SRC)
    CALL ae('f08',     LANG_FORTRAN_SRC)
    CALL ae('for',     LANG_FORTRAN_SRC)
    CALL ae('ftn',     LANG_FORTRAN_SRC)
    !    Build systems
    CALL ae('mk',      LANG_MAKEFILE)
    CALL ae('mak',     LANG_MAKEFILE)
    CALL ae('cmake',   LANG_MAKEFILE)
    !    Scripting
    CALL ae('lua',     LANG_LUA)
    CALL ae('r',       LANG_R_LANG)
    CALL ae('rmd',     LANG_R_LANG)
    !    Infrastructure
    CALL ae('tf',      LANG_TERRAFORM)
    CALL ae('tfvars',  LANG_TERRAFORM)
    !    Assembly
    CALL ae('asm',     LANG_ASSEMBLY)
    CALL ae('s',       LANG_ASSEMBLY)
    CALL ae('nasm',    LANG_ASSEMBLY)
    !    FP languages
    CALL ae('hs',      LANG_HASKELL)
    CALL ae('lhs',     LANG_HASKELL)
    CALL ae('ml',      LANG_OCAML)
    CALL ae('mli',     LANG_OCAML)
    !    Elixir
    CALL ae('ex',      LANG_ELIXIR)
    CALL ae('exs',     LANG_ELIXIR)

    CALL sort_ext_table()

  END SUBROUTINE init_language_tables

  ! ---------------------------------------------------------------------------
  ! Return language ID for a given file path; uses extension or special names.
  ! Returns LANG_UNKNOWN if not recognised.
  ! ---------------------------------------------------------------------------
  FUNCTION get_language_id(filepath) RESULT(lid)
    CHARACTER(LEN=*), INTENT(IN) :: filepath
    INTEGER :: lid
    INTEGER :: dot_pos, sep_pos, flen, i
    CHARACTER(LEN=12) :: ext

    lid = LANG_UNKNOWN
    flen = LEN_TRIM(filepath)
    IF (flen == 0) RETURN

    ! Find last path separator
    sep_pos = 0
    DO i = flen, 1, -1
      IF (filepath(i:i) == '/' .OR. filepath(i:i) == '\') THEN
        sep_pos = i
        EXIT
      END IF
    END DO

    ! Check special whole-name files (no extension)
    CALL check_special_name(filepath(sep_pos+1:flen), lid)
    IF (lid /= LANG_UNKNOWN) RETURN

    ! Find last dot after the last separator
    dot_pos = 0
    DO i = flen, sep_pos+1, -1
      IF (filepath(i:i) == '.') THEN
        dot_pos = i
        EXIT
      END IF
    END DO

    IF (dot_pos == 0 .OR. dot_pos == flen) RETURN   ! no extension

    ! Extract and lower-case the extension
    ext = lower_str(filepath(dot_pos+1:flen))

    ! Binary search
    lid = bsearch_ext(TRIM(ext))
  END FUNCTION get_language_id

  ! ---------------------------------------------------------------------------
  ! Private helpers
  ! ---------------------------------------------------------------------------

  SUBROUTINE check_special_name(name, lid)
    CHARACTER(LEN=*), INTENT(IN)  :: name
    INTEGER,          INTENT(OUT) :: lid
    CHARACTER(LEN=30) :: lname
    lname = lower_str(TRIM(name))
    lid = LANG_UNKNOWN
    SELECT CASE (TRIM(lname))
      CASE ('makefile', 'gnumakefile', 'makefile.am', 'makefile.in')
        lid = LANG_MAKEFILE
      CASE ('dockerfile')
        lid = LANG_DOCKERFILE
      CASE ('gemfile', 'rakefile', 'capfile', 'guardfile', 'vagrantfile')
        lid = LANG_RUBY
      CASE ('cmakelists.txt')
        lid = LANG_MAKEFILE
    END SELECT
  END SUBROUTINE check_special_name

  FUNCTION bsearch_ext(ext) RESULT(lid)
    CHARACTER(LEN=*), INTENT(IN) :: ext
    INTEGER :: lid, lo, hi, mid
    lid = LANG_UNKNOWN
    lo = 1;  hi = NUM_EXT
    DO WHILE (lo <= hi)
      mid = (lo + hi) / 2
      IF (TRIM(EXT_TABLE(mid)) == ext) THEN
        lid = EXT_LANG(mid)
        RETURN
      ELSE IF (TRIM(EXT_TABLE(mid)) < ext) THEN
        lo = mid + 1
      ELSE
        hi = mid - 1
      END IF
    END DO
  END FUNCTION bsearch_ext

  ! Add entry to the unsorted extension table
  SUBROUTINE ae(ext, lid)
    CHARACTER(LEN=*), INTENT(IN) :: ext
    INTEGER,          INTENT(IN) :: lid
    IF (NUM_EXT < MAX_EXT) THEN
      NUM_EXT = NUM_EXT + 1
      EXT_TABLE(NUM_EXT) = ext
      EXT_LANG(NUM_EXT)  = lid
    END IF
  END SUBROUTINE ae

  ! Insertion-sort EXT_TABLE alphabetically (called once at init; N≈130 so fast)
  SUBROUTINE sort_ext_table()
    INTEGER :: i, j
    CHARACTER(LEN=12) :: te
    INTEGER :: tl
    DO i = 2, NUM_EXT
      te = EXT_TABLE(i);  tl = EXT_LANG(i)
      j = i - 1
      DO WHILE (j >= 1 .AND. TRIM(EXT_TABLE(j)) > TRIM(te))
        EXT_TABLE(j+1) = EXT_TABLE(j)
        EXT_LANG(j+1)  = EXT_LANG(j)
        j = j - 1
      END DO
      EXT_TABLE(j+1) = te;  EXT_LANG(j+1) = tl
    END DO
  END SUBROUTINE sort_ext_table

  ! Lower-case a string up to 30 characters
  FUNCTION lower_str(s) RESULT(ls)
    CHARACTER(LEN=*), INTENT(IN) :: s
    CHARACTER(LEN=30) :: ls
    INTEGER :: i, c
    ls = ' '
    DO i = 1, MIN(LEN_TRIM(s), 30)
      c = ICHAR(s(i:i))
      IF (c >= 65 .AND. c <= 90) THEN
        ls(i:i) = CHAR(c + 32)
      ELSE
        ls(i:i) = s(i:i)
      END IF
    END DO
  END FUNCTION lower_str

END MODULE floc_lang_defs
