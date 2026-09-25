from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
source = root / 'tools/vendor/patchpae3/3e1d3b65f5c3c1ec0c4759f707d3017e51113103/PatchPAE3/main.c'
if len(sys.argv) > 1:
    source = root / sys.argv[1]
lines = source.read_text(errors='replace').splitlines()
ranges = [(int(sys.argv[2])-1, int(sys.argv[3]))] if len(sys.argv) > 3 else [(5380, 5450), (5750, 5950)]
for start, end in ranges:
    for number in range(start, min(end, len(lines))):
        print(f'{number + 1}: {lines[number]}')
