from pathlib import Path
import sys
p=next((Path(__file__).resolve().parents[1]/'tools/vendor/xp-modern/2026-09-21').glob('integrator/*/Patch Integrator */Options Menu.cmd'))
lines=p.read_text(encoding='cp1252').splitlines()
for i in range(int(sys.argv[1])-1,min(int(sys.argv[2]),len(lines))): print(f'{i+1}: {lines[i]}')
