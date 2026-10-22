"""One exact parent-completion event; no progress/process/image queries."""
from pathlib import Path
import importlib.util
import json

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT/'artifacts/coverage/nt351-client-auto-fresh01'
FINAL = HERE/'process-exit.json'


def main():
    spec = importlib.util.spec_from_file_location('auto351_parent_notice', HERE/'notify_core.py')
    notice = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(notice)
    # Subscribe first. A completion that preceded this extra subscription is
    # already terminal evidence, never a progress-file fallback or retry.
    try:
        notice.wait_created([FINAL], 'parent-completion')
        source = 'exact_future_creation_event'
    except FileExistsError:
        source = 'already_completed_before_subscription'
    # Creation is only the wake-up. The caller waits the owned TTY closed
    # before parsing this small terminal record, so no partial-write race.
    print(json.dumps(dict(event='PARENT_RETURN_RECORD_CREATED', source=source, path=str(FINAL))), flush=True)


if __name__ == '__main__':
    main()
