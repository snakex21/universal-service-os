# Own NT4 Setup observer: diagnostic snapshot, WIP integration

This reviewed own helper does not install anything or register a Setup hook.
No Microsoft executable/resource text, hive, answer file or key is included.
public_ids.h contains only numeric public IDs and module basenames.

The GUI wrapper starts exact original `setup -newsetup`, waits for the child
and preserves its exit code, including when COM fails. Only STATIC/BUTTON/
top-level dialog captions are read through bounded WM_GETTEXT; never EDIT.
Original resource comparisons stay in the guest; only public IDs/closed states
reach the own C:/USOS/NT4/NT4PAGE.LOG file. Whole-frame mutex synchronization
prevents a native-exit flag from interleaving. No mutex is held across COM
ReadFile; the final observer wait is at most 1000 ms.

Using the configured Python/Zig paths, the self-contained host tests are:

```
python -I -B test_semantics.py
python -I -B test_cross_process.py
```

The first uses the actual C entry/observer with fake native APIs and real
threads/events/mutex for the childexit-during-BEGIN race. The second reads
only off-screen synthetic controls in a different own process, counts messages
to EDIT (zero), and checks a real hung-control deadline. Fresh output folders
are required and all data stays beside the scripts. These are 11 of the 26
host tests; the other UART/operator/file-policy tests and complete one-shot
preparation tools remain in the local diagnostic application folder recorded
in the handoff. Product-runner integration and guest validation are WIP.

Attempt 06: observer transport timeout480.15s, controlled quit/rc0, no page
proven. Native child was not blocked by COM failure; only observation was
skipped. This is not a Windows FAIL. Attempt07/final is PREPARED_NOT_BOOTED.
There is no NT4 desktop/LAN/HID/MSC or physical hardware PASS. The user's
end-of-day stop forbids any next VM until work is resumed.
