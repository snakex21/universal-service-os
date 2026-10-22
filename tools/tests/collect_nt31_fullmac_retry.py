"""Fixed R24b stopped collector; uses the identical bounded own evidence policy."""
from pathlib import Path
import importlib.util
ROOT=Path(__file__).resolve().parents[2]
TAG='r24b-nt31-image-entry'
def main():
    s=importlib.util.spec_from_file_location('nt31_retry_collect',Path(__file__).with_name('collect_nt31_fullmac.py'))
    c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
    c.WORK=Path(r'G:\USOS-Kolekcja\_vm')/TAG
    c.VM=c.RUNTIME/'vm'/TAG;c.OUT=c.RUNTIME/'r24b-stopped-readback'
    c.PREPARATION=c.RUNTIME/'r24b-preparation.json'
    c.main()
if __name__=='__main__':main()
