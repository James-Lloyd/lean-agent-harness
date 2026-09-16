# Independent review — round 3

Verdict: **FIX-THEN-SHIP**

- BLOCKER: the scrubber proof had eight positive controls but no deliberately weakened pre-fix mutant
  proving that exact, case-sensitive replacement fails on the relevant path forms.
- IMPORTANT: the README therefore overstated the evidence as mutation tested.

The next review surface adds a legacy exact-match scrubber and four controls that must catch its
failures on doubled backslashes, doubled forward slashes, doubled MSYS separators, and mixed
separators. The reviewer made no edits.
