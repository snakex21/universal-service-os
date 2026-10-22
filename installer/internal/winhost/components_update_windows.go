//go:build windows

package winhost

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/components"
)

// usos-physical-update rewrites the ESP and the Core but, unlike the
// installer's Components step, never installed or checked the optional
// components (the Windows XP package EFI\USOS-XP and the WinPE PE10 donors
// x64/x86 in DATA\Programs\USOS\WinPE + EFI\USOS\winpe-donor.ini), so a stick
// installed without one never got it back on update. This file adds the two
// halves: a read-only report (ReportComponents) that says present/current/
// outdated against the build, and InstallComponents, which installs only the
// explicitly selected components with the installer's own code.

// ComponentState is the state of one optional component on the stick.
type ComponentState int

const (
	// ComponentMissing: the component is not on the stick.
	ComponentMissing ComponentState = iota
	// ComponentCurrent: present and matching this build (manifest hashes,
	// winpe-donor.ini record) - nothing to do.
	ComponentCurrent
	// ComponentOutdated: present but damaged, unrecorded or made for another
	// USOS build; the Components step installs it again.
	ComponentOutdated
)

func (s ComponentState) String() string {
	switch s {
	case ComponentCurrent:
		return "current"
	case ComponentOutdated:
		return "outdated"
	}
	return "missing"
}

// ComponentReportItem is one line of the component report. Name is the
// -components token ("xp", "winpe", "winpe-x86"); ID is the concrete release
// asset when it is known (XPPL/XPEN for the XP package found on the ESP).
type ComponentReportItem struct {
	Name   string
	ID     components.ID
	State  ComponentState
	Detail string
}

// ComponentReport is the read-only component state of one stick.
type ComponentReport struct {
	Items []ComponentReportItem
}

// Item returns the entry named token ("xp", "winpe", "winpe-x86").
func (r ComponentReport) Item(name string) (ComponentReportItem, bool) {
	for _, item := range r.Items {
		if item.Name == name {
			return item, true
		}
	}
	return ComponentReportItem{}, false
}

// Lines is the report in the CLI's COMPONENT=state form.
func (r ComponentReport) Lines() []string {
	lines := make([]string, 0, len(r.Items))
	for _, item := range r.Items {
		lines = append(lines, "COMPONENT "+item.Name+"="+item.State.String()+" id="+string(item.ID)+" detail="+item.Detail)
	}
	return lines
}

// ReportComponents reads the optional components of an ESP/DATA pair without
// touching it: components.Inspect (XP manifest, micro-Linux base, donors) plus
// the XP package's own manifest.json hashes/sizes and the winpe-donor.ini
// records. The physical update only reports unless -components was given.
func ReportComponents(espRoot, dataRoot string) ComponentReport {
	status := components.Inspect(espRoot, dataRoot)
	report := ComponentReport{}
	report.Items = append(report.Items, inspectXPComponent(espRoot, status))
	report.Items = append(report.Items, inspectWinpeComponent(dataRoot, espRoot, archX64, status.WinPE))
	report.Items = append(report.Items, inspectWinpeComponent(dataRoot, espRoot, archX86, status.WinPEX86))
	return report
}

// inspectXPComponent checks ESP\EFI\USOS-XP\manifest.json, the two payload
// files against the manifest's SHA-256 map and the package's
// base_initramfs_sha256 against this stick's micro-Linux (the build check of
// install-xp-package.ps1).
func inspectXPComponent(espRoot string, status components.Status) ComponentReportItem {
	item := ComponentReportItem{Name: "xp", State: ComponentMissing,
		Detail: `no EFI\USOS-XP\manifest.json`}
	dir := filepath.Join(espRoot, "EFI", "USOS-XP")
	manifest, err := components.ReadXPManifest(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return item
	}
	switch {
	case strings.EqualFold(manifest.ReleaseLang, "pl"):
		item.ID = components.XPPL
	case strings.EqualFold(manifest.ReleaseLang, "en"):
		item.ID = components.XPEN
	}
	var facts, problems []string
	if item.ID == "" {
		facts = append(facts, "language unknown")
	} else {
		facts = append(facts, "language "+manifest.ReleaseLang)
	}
	for _, name := range []string{"initramfs-xp", "vmlinuz.efi"} {
		path := filepath.Join(dir, name)
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			problems = append(problems, name+" missing")
			continue
		}
		facts = append(facts, fmt.Sprintf("%s %d bytes", name, info.Size()))
		want, recorded := manifest.SHA256[name]
		if !recorded {
			continue
		}
		got, err := components.HashFile(path)
		if err != nil {
			problems = append(problems, name+" unreadable: "+err.Error())
			continue
		}
		if !strings.EqualFold(got, want) {
			problems = append(problems, name+" SHA-256 "+got+" differs from manifest "+strings.ToLower(want))
			continue
		}
		facts = append(facts, name+" SHA-256 ok")
	}
	if status.XPCurrent {
		facts = append(facts, "matches this build")
	} else {
		problems = append(problems, `made for another USOS build (manifest base_initramfs_sha256 differs from EFI\USOS\micro-linux\initramfs-usos)`)
	}
	item.State = ComponentCurrent
	if len(problems) > 0 {
		item.State = ComponentOutdated
	}
	item.Detail = strings.Join(facts, ", ")
	if len(problems) > 0 {
		if item.Detail != "" {
			item.Detail += "; "
		}
		item.Detail += strings.Join(problems, "; ")
	}
	return item
}

// inspectWinpeComponent checks one PE10 donor: the ISO in DATA and its
// winpe-donor.ini record (the verification the UEFI menu does before use).
func inspectWinpeComponent(dataRoot, espRoot string, arch donorArch, present bool) ComponentReportItem {
	item := ComponentReportItem{Name: "winpe", ID: components.WinPE, State: ComponentMissing,
		Detail: "no PE10 " + string(arch) + " donor ISO in " + filepath.FromSlash(winpeDonorDir)}
	if arch == archX86 {
		item.Name, item.ID = "winpe-x86", components.WinPEX86
	}
	if !present {
		return item
	}
	records := readWinpeRecords(filepath.Join(espRoot, filepath.FromSlash(winpeDonorRecord)))
	detail, ok := verifyWinpeDonorArch(dataRoot, records, arch)
	item.Detail = detail
	if ok {
		item.State = ComponentCurrent
	} else {
		item.State = ComponentOutdated
	}
	return item
}

// ComponentInstallOptions is where InstallComponents gets its verified zips
// from: the all-in-one installer's overlay (Bundle, as the installer itself
// uses) or, when the installer has none, the release download.
type ComponentInstallOptions struct {
	Bundle     *components.Bundle
	Release    components.Release
	Downloader *components.Downloader
	Log        func(string)
}

// InstallComponents installs the selected components on an ESP/DATA pair with
// the installer's Components step, not a copy of it: components.Runner
// (internal/components/runner.go:88) verifies every zip against the compiled
// hash list/SHA256SUMS and hands it to installComponentAt
// (components_windows.go:45), the exact function Backend.InstallComponent
// calls after resolving the volumes - so the WinPE donor gets the same
// ensureWinpeDonor record in EFI\USOS\winpe-donor.ini and the XP package the
// same install-xp-package.ps1 run.
//
// An empty ids list (no -components) installs nothing: the caller's default
// run is report only.
func InstallComponents(ctx context.Context, espRoot, dataRoot string, ids []components.ID, opts ComponentInstallOptions) map[components.ID]error {
	results := map[components.ID]error{}
	if len(ids) == 0 {
		return results // report only: no writes, ever
	}
	log := opts.Log
	if log == nil {
		log = func(string) {}
	}
	dir := components.DefaultDir(opts.Release) // %TEMP%, never the stick
	downloader := opts.Downloader
	if downloader == nil {
		downloader = &components.Downloader{Release: opts.Release, Dir: dir, Log: log}
	}
	runner := &components.Runner{
		Release:    opts.Release,
		Downloader: downloader,
		Installer:  componentInstallerAt{espRoot: espRoot, dataRoot: dataRoot},
		Bundle:     opts.Bundle,
		Dir:        dir,
		Log:        log,
	}

	status := components.Inspect(espRoot, dataRoot)
	var choices []components.Choice
	for _, id := range ids {
		if status.Present(id) {
			log("[COMPONENTS] " + string(id) + " already installed and current")
			results[id] = nil
			continue
		}
		source := components.SourceEmbedded
		if !opts.Bundle.Has(opts.Release.Asset(id)) {
			if !opts.Release.CanDownload() {
				results[id] = fmt.Errorf("%s: not in the -installer component overlay and this build cannot download it", id)
				continue
			}
			source = components.SourceDownload
		}
		choices = append(choices, components.Choice{ID: id, Source: source})
	}
	if len(choices) == 0 {
		return results
	}
	for id, err := range runner.Run(ctx, choices, nil) {
		results[id] = err
	}
	// Hash verification after the write: the read-only report the CLI already
	// printed must now say "current" for every component just installed.
	report := ReportComponents(espRoot, dataRoot)
	for _, choice := range choices {
		if results[choice.ID] != nil {
			continue
		}
		item, _ := report.Item(componentToken(choice.ID))
		if item.State != ComponentCurrent || item.ID != choice.ID {
			results[choice.ID] = fmt.Errorf("verification after install: %s, %s", item.State, item.Detail)
			continue
		}
		log("[COMPONENTS] " + string(choice.ID) + " verified after install: " + item.Detail)
	}
	return results
}

// componentInstallerAt is the components.Installer of InstallComponents: it
// calls installComponentAt, the same function Backend.InstallComponent
// (components_windows.go:37) uses for the installer's Components step.
type componentInstallerAt struct{ espRoot, dataRoot string }

func (c componentInstallerAt) InstallComponent(id components.ID, zipPath string, storeOnly bool, log func(string)) error {
	return installComponentAt(c.espRoot, c.dataRoot, id, zipPath, storeOnly, log)
}

// componentToken maps a release asset ID to its -components token.
func componentToken(id components.ID) string {
	switch {
	case id == components.WinPE:
		return "winpe"
	case id == components.WinPEX86:
		return "winpe-x86"
	case id.IsXP():
		return "xp"
	}
	return ""
}
