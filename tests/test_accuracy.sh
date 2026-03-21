#!/bin/bash
# FLOC accuracy test suite — exit 0 if all pass

FLOC="${1:-../floc}"
TMPDIR_T="$(mktemp -d /tmp/floc_test.XXXXXX)"
PASS=0; FAIL=0
cleanup() { rm -rf "$TMPDIR_T"; }
trap cleanup EXIT

# check <label> <exp_blank> <exp_comment> <exp_code> <file>
# SUM line: SUM: <files> <blank> <comment> <code>
check() {
    local label="$1" eb="$2" ec="$3" ecode="$4" file="$5"
    local out gb gc gcode
    out="$("$FLOC" --quiet "$file" 2>&1)"
    gb=$(   printf '%s\n' "$out" | awk '/SUM:/{print $3}')
    gc=$(   printf '%s\n' "$out" | awk '/SUM:/{print $4}')
    gcode=$(printf '%s\n' "$out" | awk '/SUM:/{print $5}')
    if [ "$gb" = "$eb" ] && [ "$gc" = "$ec" ] && [ "$gcode" = "$ecode" ]; then
        printf "  PASS  %s\n" "$label"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$label"
        printf "        Expected: blank=%-4s comment=%-4s code=%-4s\n" "$eb" "$ec" "$ecode"
        printf "        Got:      blank=%-4s comment=%-4s code=%-4s\n" "$gb" "$gc" "$gcode"
        FAIL=$((FAIL + 1))
    fi
}

echo "=============================="
echo " FLOC Accuracy Test Suite"
echo "=============================="

# ── Python: triple-quote block + hash + inline ────────────────────────────────
F="$TMPDIR_T/t.py"
printf '"""\nblock\n"""\n\n# line\nx = 1  # inline\ny = 2\n' > "$F"
check "Python triple-quote+hash+inline" 1 4 2 "$F"

# ── Python: string should not suppress # ─────────────────────────────────────
F="$TMPDIR_T/t2.py"
printf '%s\n%s\n%s\n' 's = "not a # comment"' '# real comment' 'x = 1' > "$F"
check "Python string does not suppress hash" 0 1 2 "$F"

# ── C: block + line + inline ──────────────────────────────────────────────────
F="$TMPDIR_T/t.c"
{
  echo '/* block'
  echo '   comment */'
  echo ''
  echo '// line'
  echo 'int x = 1; // inline'
  echo 'int y = 2;'
} > "$F"
check "C block+line+inline" 1 3 2 "$F"

# ── C: URL in string must NOT be a comment ───────────────────────────────────
F="$TMPDIR_T/str.c"
{
  echo 'const char *s = "http://x.com";'
  echo '// real comment'
  echo 'int x = 0;'
} > "$F"
check "C string with // not a comment" 0 1 2 "$F"

# ── Shell: shebang=code, hash=comment, inline hash=code ──────────────────────
F="$TMPDIR_T/t.sh"
{
  echo '#!/bin/bash'
  echo '# comment'
  echo ''
  echo 'X=1  # inline'
  echo 'Y=2'
} > "$F"
check "Shell hash comments" 1 2 2 "$F"

# ── HTML: <!-- --> block comments ─────────────────────────────────────────────
F="$TMPDIR_T/t.html"
{
  echo '<!-- comment -->'
  echo '<html>'
  echo '<body>'
  echo '  <!-- inner -->'
  echo '  <p>hi</p>'
  echo '</body>'
  echo '</html>'
} > "$F"
check "HTML block comments" 0 2 5 "$F"

# ── YAML ─────────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.yaml"
{
  echo '# header'
  echo 'name: test  # inline'
  echo ''
  echo '# section'
  echo 'val: 42'
} > "$F"
check "YAML hash comments" 1 2 2 "$F"

# ── JSON ─────────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.json"
{
  echo '{'
  echo '  "a": 1,'
  echo '  "b": 2'
  echo '}'
} > "$F"
check "JSON no comments" 0 0 4 "$F"

# ── Go ────────────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.go"
{
  echo '// pkg'
  echo 'package main'
  echo ''
  echo '/* block */'
  echo 'import "fmt"'
  echo 'func main() {'
  echo '    fmt.Println("x") // code'
  echo '}'
} > "$F"
check "Go C-style comments" 1 2 5 "$F"

# ── All-blank file ────────────────────────────────────────────────────────────
F="$TMPDIR_T/blank.py"
printf '\n\n\n' > "$F"
check "All-blank file" 3 0 0 "$F"

# ── Single line no trailing newline ───────────────────────────────────────────
F="$TMPDIR_T/nonl.py"
printf 'x = 1' > "$F"
check "Single line no newline" 0 0 1 "$F"

# ── CSS ───────────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.css"
{
  echo '/* reset */'
  echo 'body {'
  echo '  margin: 0; /* inline */'
  echo '}'
} > "$F"
check "CSS block comment only" 0 1 3 "$F"

# ── SQL ───────────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.sql"
{
  printf '%s\n' '-- header'
  echo 'SELECT id, /* col */ name'
  echo 'FROM users;'
  echo ''
  printf '%s\n' '-- footer'
} > "$F"
check "SQL line+block comments" 1 2 2 "$F"

# ── Haskell ──────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.hs"
{
  echo '{- block'
  echo '   comment -}'
  printf '%s\n' '-- line'
  echo 'main = putStrLn "hi"'
} > "$F"
check "Haskell line+block comments" 0 3 1 "$F"

# ── Fortran ───────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.f90"
{
  echo '! header'
  echo 'PROGRAM test'
  echo '  x = 1 ! inline'
  echo '  PRINT *, x'
  echo 'END PROGRAM'
} > "$F"
check "Fortran ! comments" 0 1 4 "$F"

# ── Markdown ─────────────────────────────────────────────────────────────────
F="$TMPDIR_T/t.md"
{
  echo '# Title'
  echo ''
  echo 'Some text.'
  echo 'More text.'
} > "$F"
check "Markdown all-code" 1 0 3 "$F"

# ── Rust: // and /* */ ────────────────────────────────────────────────────────
F="$TMPDIR_T/t.rs"
{
  echo '// doc comment'
  echo 'fn main() {'
  echo '    /* block */'
  echo '    println!("hi"); // inline'
  echo '}'
} > "$F"
check "Rust C-style comments" 0 2 3 "$F"

echo ""
echo "=============================="
printf " Results: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
