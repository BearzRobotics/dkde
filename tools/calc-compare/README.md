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
