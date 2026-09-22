from pathlib import Path
root=Path(__file__).resolve().parents[1]
for folder in [root/'tools/cache',root/'zig-out',Path('J:/EFI/USOS'),Path('L:/Systems/Windows/Windows XP')]:
    print('\nDIRECTORY',folder)
    if not folder.exists():
        print('MISSING');continue
    for p in folder.rglob('*'):
        if p.is_file() and (p.suffix.lower() in ['.iso','.conf'] or any(w in p.name.lower() for w in ['initramfs','vmlinuz','bzimage','micro-linux','nt52'])):
            print(p, p.stat().st_size)
