"""Convert a QEMU screendump for inspection without changing its pixels."""
import sys
from pathlib import Path
from PIL import Image

for argument in sys.argv[1:]:
    path = Path(argument)
    with Image.open(path) as image:
        image.save(path.with_suffix('.png'))
