# calc-compare

Compares dkde-calc with Qalculate (`qalc`), insect and kalker. dkde-calc's side is its `probe` test
(see `src/calc/accuracy_test.zig`), run directly from the built test binary.

    zig build test-calc                         # builds the test binary
    B=$(ls -t .zig-cache/o/*/test | head -1)
    python3 tools/calc-compare/run.py $B        # runs cases.py through all tools -> results.json
    python3 tools/calc-compare/compare.py       # agree/differ per tool, and every difference
    python3 tools/calc-compare/fuzz.py $B       # ~600 random arguments against qalc at 25 digits
    python3 tools/calc-compare/run.py $B feat feat.json   # feature probes (what each tool can do)

Run it from a scratch directory: it writes probe files and results next to the scripts.
Angles are radians everywhere. The probe shows 12 decimals, so very small results look truncated there;
the program itself switches to scientific notation instead. kalker reads `1e5` as 1·e·5 and
insect has no `mod`, `choose`, `cbrt` or `erf`: those cases are skipped for them in `cases.py`.

## Checking answers against independent references

Qalculate and the others cannot judge every lesson or formula, so two scripts check dkde-calc against
mpmath, scipy and sympy (nothing from dkde-calc's own code). Run them from the repository root with the
built binary at `zig-out/bin/dkde-calc`:

    python3 -I tools/calc-compare/verify_lessons.py [DIR-or-FILE ...]   # every calc line and exercise answer in data/learn
    python3 -I tools/calc-compare/verify_formulas.py [NAME-PART]        # every formula, solved for each of its letters

Both list every disagreement, crash, hang and "no answer", and list what they cannot check (never counted
as a pass). `dkde-calc eval --solve` works an equation as the Formulas pane does, and
`--programmer --base N --bits N` runs programmer-mode steps.
