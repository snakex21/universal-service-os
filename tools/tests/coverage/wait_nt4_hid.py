"""One exact future HID completion, derived from own R19 notifier; no polling."""
from pathlib import Path
import ctypes,json,os,struct,sys
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'artifacts/coverage/vm/nt4-installed03-usb-hid01'
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
    mode=sys.argv[1]
    if mode=='endpoint':wanted=[OUT/'endpoint.png',OUT/'completed.json']
    elif mode=='completed':wanted=[OUT/'completed.json']
    else:
        n=int(mode)
        if not 1<=n<=128:raise ValueError('Step1..128 required')
        wanted=[OUT/('operator-%02d.png'%n),OUT/'completed.json']
    matched=wait_created(wanted,mode)
    print(json.dumps(dict(completed=str(matched))),flush=True)
if __name__=='__main__':main()
