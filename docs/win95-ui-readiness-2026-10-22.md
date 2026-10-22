# Windows 95 RFB input readiness — runtime pending

The original event receiver notified the shell as soon as a heading and
its optional static label matched. A real RTM PL diagnostic showed that a
page heading and the Next button can paint separately; the busy page
briefly retained the preceding enabled button before it became disabled.
Recognizing a heading therefore does not establish input readiness. The
normal r22 run is independent of this change and still uses its frozen
earlier inputs. No stall cause or runtime success is inferred here.

The receiver now retains a pending public state: role, heading hash and
footer glyph hash. Known Next pages need the enabled RTM PL/Polish glyph
observed in the private keyless r17 images. Restart/confirmation pages
keep their existing static-label guards. The state must remain stable
for three seconds before one role notification is emitted. Private edit
and caret paints do not reset this deadline or leave the receiver.

An unrecognized page with that enabled Next glyph and an unchanged public
state for thirty seconds emits only `unsupported <heading-hash>` and
exits with code 4. The shell records the reason, stops phase one with
failure and withholds reboot. It neither guesses a navigation action nor
types a key. A busy page, disabled button, other resolution or invalid
paint cancels the pending action. English OSR1 requires its own validated
heading/button profiles; it does not inherit Polish coverage.

The only timed wait is `select` for the real wire event or that single
pending deadline. The already outstanding incremental RFB request stays
outstanding when a deadline fires: no screenshot, status request, extra
frame request or periodic guest/disk/process check is sent. With no
candidate, the receiver blocks without a timer. Pixels remain RAM only
and are cleared on normal exit.

Host validation: 13 native synthetic RFB cases, 3 shell controller cases
and 11 input-policy cases pass. New cases verify cancellation when Next
disables, rejection after a changed heading, no failure on a disabled
unknown page, no extra request at publication, and private-field paints
continuing while the public state becomes ready. The unsupported shell
case checks failure and absence of key input. Synthetic tests use short
compile-time deadlines; production defaults remain 3000/30000 ms. Both
static Linux helpers build with warnings treated as errors.

No Windows runtime PASS, new VM, full release build, physical disk write,
merge or push is part of this change. The separate RTM UI branch remains
at `22f12539`; this branch is based on it and does not replace NT/hub code.
