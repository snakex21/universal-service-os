"""Deliver the entire collector before its noninteractive output can start."""
import hashlib


def wrap(script):
    if not isinstance(script,str) or not script.strip():
        raise ValueError('A nonempty collector script is required')
    if '\0' in script:raise ValueError('NUL in collector script')
    body=script.replace('\r\n','\n')
    if '\r' in body:raise ValueError('Bare CR in collector script')
    if not body.endswith('\n'):body+='\n'
    marker='USOS_COLLECTOR_'+hashlib.sha256(body.encode('utf-8')).hexdigest()
    if marker in body.splitlines():raise ValueError('Collector delimiter collision')
    # Interactive ash consumes the whole quoted here-document first. exec
    # then replaces it with a noninteractive shell. No later commands remain
    # to be echoed into the base64 output. Quoting preserves the script bytes.
    return "exec /bin/sh <<'"+marker+"'\n"+body+marker+'\n'
