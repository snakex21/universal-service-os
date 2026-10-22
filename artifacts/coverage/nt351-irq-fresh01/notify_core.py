"""One-shot, exact-path NT3.1 notifications. No progress polling or image reads."""
from pathlib import Path
import ctypes
import json
import os
import stat
import struct
import sys
import time

HERE = Path(__file__).resolve().parent
CASE = Path(r'G:\USOS-Kolekcja\_vm\r19-nt31-desktop-ps2')
OUT = Path(r'C:\Users\ASRock\usos-work\macierz-windows\artifacts\coverage\vm\r19-nt31-desktop-ps2')
SOURCE = CASE / 'target.qcow2'
LINK = CASE / 'target-retained.qcow2'


def exact(path):
    if not path.is_absolute() or str(path.resolve()).casefold() != str(path).casefold():
        raise ValueError('Unexpected absolute path or reparse-point redirection')


def wait_created(paths, mode):
    for path in paths:
        exact(path)
    directory = paths[0].parent
    watched = directory
    while not watched.is_dir():
        watched = watched.parent
    expected = {str(p.relative_to(watched)).casefold(): p for p in paths}
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.ReadDirectoryChangesW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p, ctypes.c_void_p]
    kernel.CreateEventW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_wchar_p]
    kernel.CreateEventW.restype = ctypes.c_void_p
    kernel.ResetEvent.argtypes = [ctypes.c_void_p]
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.GetOverlappedResult.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]
    kernel.CancelIoEx.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    class Overlapped(ctypes.Structure):
        _fields_ = [('internal', ctypes.c_size_t), ('internal_high', ctypes.c_size_t), ('offset', ctypes.c_uint32), ('offset_high', ctypes.c_uint32), ('event', ctypes.c_void_p)]
    handle = kernel.CreateFileW(str(watched), 1, 7, None, 3, 0x42000000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    event = kernel.CreateEventW(None, True, False, None)
    if not event:
        kernel.CloseHandle(handle)
        raise ctypes.WinError(ctypes.get_last_error())
    overlapped = Overlapped()
    overlapped.event = event
    pending = False
    initial = True
    try:
        buffer = ctypes.create_string_buffer(65536)
        while True:
            received = ctypes.c_uint32()
            kernel.ResetEvent(event)
            if not kernel.ReadDirectoryChangesW(handle, buffer, len(buffer), watched != directory, 1, None, ctypes.byref(overlapped), None) and ctypes.get_last_error() != 997:
                raise ctypes.WinError(ctypes.get_last_error())
            pending = True
            if initial:
                initial = False
                # Subscription precedes this one-time check; no check/subscribe race.
                if any(os.path.lexists(p) for p in paths):
                    raise FileExistsError('Refusing an existing candidate notification path')
                if mode == 'retain' and os.path.lexists(LINK):
                    raise FileExistsError('Refusing an existing retained image')
                print(json.dumps({'event': 'ARMED', 'mode': mode, 'pid': os.getpid(), 'watched': str(watched), 'exact_paths': [str(p) for p in paths]}), flush=True)
            if kernel.WaitForSingleObject(event, 0xffffffff) != 0:
                raise ctypes.WinError(ctypes.get_last_error())
            if not kernel.GetOverlappedResult(handle, ctypes.byref(overlapped), ctypes.byref(received), False):
                raise ctypes.WinError(ctypes.get_last_error())
            pending = False
            if not received.value:
                raise RuntimeError('Directory notification overflow; no polling fallback')
            offset = 0
            while received.value - offset >= 12:
                following, action, length = struct.unpack_from('<III', buffer, offset)
                name = buffer.raw[offset + 12:offset + 12 + length].decode('utf-16-le')
                if action in (1, 5) and name.casefold() in expected:
                    return expected[name.casefold()]
                if not following:
                    break
                offset += following
    finally:
        if pending:
            kernel.CancelIoEx(handle, ctypes.byref(overlapped))
            received = ctypes.c_uint32()
            kernel.GetOverlappedResult(handle, ctypes.byref(overlapped), ctypes.byref(received), True)
        kernel.CloseHandle(event)
        kernel.CloseHandle(handle)


def main():
    mode = sys.argv[1]
    if mode not in ('retain', 'endpoint'):
        raise ValueError('Unknown fixed notification mode')
    started = time.time()
    paths = [SOURCE] if mode == 'retain' else [OUT / 'endpoint.png', OUT / 'cleanup.json']
    matched = wait_created(paths, mode)
    result = {'event': 'COMPLETED', 'mode': mode, 'matched': str(matched), 'started_unix': started, 'completed_unix': time.time()}
    if mode == 'retain':
        exact(CASE)
        exact(SOURCE)
        exact(LINK)
        if SOURCE.parent != CASE or LINK.parent != CASE or os.path.lexists(LINK):
            raise ValueError('Unexpected hardlink boundary or existing destination')
        metadata = SOURCE.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_file_attributes & 0x400:
            raise ValueError('Target must be a regular non-reparse file')
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateHardLinkW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_void_p]
        kernel.CreateHardLinkW.restype = ctypes.c_int
        if not kernel.CreateHardLinkW(str(LINK), str(SOURCE), None):
            raise ctypes.WinError(ctypes.get_last_error())
        # Metadata identity only: no open/read of the active QCOW2 payload.
        retained = LINK.lstat()
        if (metadata.st_dev, metadata.st_ino) != (retained.st_dev, retained.st_ino):
            raise RuntimeError('Hardlink file identity mismatch')
        result.update(hardlink=str(LINK), hardlink_verified=True, source_content_read=False)
    (HERE / ('r19-nt31-' + mode + '-notification.json')).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
