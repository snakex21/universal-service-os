tools/release/licenses

Licence texts and source notes for third-party components that ship with
USOS but whose vendor folders do not carry them. Referenced from
tools/release/third-party.json; tools/release/assemble_release.py copies each
listed file to LICENSES/<component id>/ in the release.

spdx/            canonical licence texts, byte copies of texts already vetted
                 in the repository:
                   GPL-2.0.txt     = tools/vendor/syslinux/6.03/COPYING
                   GPL-3.0.txt     = tools/vendor/wimlib/1.14.5/COPYING.GPLv3.txt
                   LGPL-2.1.txt    = tools/vendor/csmwrap/3.1.2/LICENSE
                   LGPL-3.0.txt    = tools/vendor/csmwrap/3.1.2/COPYING.LESSER
                   Apache-2.0.txt  = assets/fonts/LICENSE-Apache-2.0.txt
<component>/     SOURCES.txt (upstream, exact version, source location) and
                 licence files extracted from the upstream archives:
                   freedos/    DOC/KERNEL/COPYING of kernel.zip, DOC/DOSZIP/LICENSE of doszip.zip
                   genahci/    gpl.txt of GenAHCI_6.3.0.1.7z
                   go/         LICENSE of the Go 1.26.2 distribution (identical to golang.org/x/sys v0.47.0)
                   alpine/, linux-lts/, systemd-boot/, efifs-ntfs/: SOURCES.txt

None of these files is a payload input; the installer payload is unchanged.
Audit: docs/LICENSES-AUDIT.md.
