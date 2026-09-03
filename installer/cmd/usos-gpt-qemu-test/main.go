//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	serial := flag.String("serial", "USOS-GPT-TEST", "required target serial")
	size := flag.Uint64("size", 40*layout.GiB, "required target size in bytes")
	out := flag.String("out", "", "result file path")
	flag.Parse()

	if strings.TrimSpace(*out) == "" {
		fmt.Fprintln(os.Stderr, "missing -out")
		os.Exit(2)
	}

	lines := []string{"USOS GPT QEMU destructive integration test"}
	finish := func(ok bool, err error) {
		if err != nil {
			lines = append(lines, "ERROR="+err.Error())
		}
		if ok {
			lines = append(lines, "RESULT=PASS")
		} else {
			lines = append(lines, "RESULT=FAIL")
		}
		_ = os.WriteFile(*out, []byte(strings.Join(lines, "\r\n")+"\r\n"), 0o644)
		if ok {
			os.Exit(0)
		}
		os.Exit(1)
	}

	disks, err := (winhost.Enumerator{}).ListDisks()
	if err != nil {
		finish(false, fmt.Errorf("enumerate disks: %w", err))
	}

	var matches []domain.Disk
	for _, disk := range disks {
		lines = append(lines, fmt.Sprintf(
			"DISK number=%d model=%q serial=%q size=%d removable=%v system=%v eligible=%v reason=%q",
			disk.Number,
			disk.Model,
			disk.Serial,
			disk.SizeBytes,
			disk.Removable,
			disk.SystemDisk,
			disk.Eligible,
			disk.Reason,
		))
		if strings.TrimSpace(disk.Serial) == strings.TrimSpace(*serial) && disk.SizeBytes == *size && disk.Removable && !disk.SystemDisk {
			matches = append(matches, disk)
		}
	}
	if len(matches) != 1 {
		finish(false, fmt.Errorf("expected exactly one removable target serial=%q size=%d, found %d", *serial, *size, len(matches)))
	}
	target := matches[0]
	lines = append(lines, fmt.Sprintf("TARGET=PhysicalDrive%d model=%q serial=%q size=%d", target.Number, target.Model, target.Serial, target.SizeBytes))

	plan, err := layout.Build(target.SizeBytes)
	if err != nil {
		finish(false, fmt.Errorf("build layout: %w", err))
	}
	if err := plan.ValidateSectorSize(target.SectorBytes); err != nil {
		finish(false, fmt.Errorf("validate sector layout: %w", err))
	}

	session, current, err := (winhost.Backend{}).BeginDestructive(target)
	if err != nil {
		finish(false, fmt.Errorf("begin destructive session: %w", err))
	}
	defer session.Close()
	lines = append(lines, fmt.Sprintf("REVALIDATED model=%q serial=%q size=%d sector=%d", current.Model, current.Serial, current.SizeBytes, current.SectorBytes))

	if err := session.CleanPartitionTable(); err != nil {
		finish(false, fmt.Errorf("delete drive layout: %w", err))
	}
	lines = append(lines, "DELETE=PASS")

	backend := winhost.Backend{}
	media, err := session.CreateGPTAndPartitions(plan)
	if err != nil {
		finish(false, fmt.Errorf("create/set/read-back GPT: %w", err))
	}
	lines = append(lines,
		"CREATE_SET_READBACK=PASS",
		"DISK_PTUUID="+media.DiskPTUUID,
		fmt.Sprintf("ESP partuuid=%s offset=%d size=%d", media.ESP.PartUUID, media.ESP.StartBytes, media.ESP.SizeBytes),
		fmt.Sprintf("DATA partuuid=%s offset=%d size=%d", media.DATA.PartUUID, media.DATA.StartBytes, media.DATA.SizeBytes),
		fmt.Sprintf("WORK partuuid=%s offset=%d size=%d", media.WORK.PartUUID, media.WORK.StartBytes, media.WORK.SizeBytes),
	)

	if err := backend.FormatESP(media); err != nil {
		finish(false, fmt.Errorf("format ESP: %w", err))
	}
	lines = append(lines, "FORMAT_ESP=PASS")
	if err := backend.FormatDATA(media); err != nil {
		finish(false, fmt.Errorf("format DATA: %w", err))
	}
	lines = append(lines, "FORMAT_DATA=PASS")
	if err := backend.FormatWORK(media); err != nil {
		finish(false, fmt.Errorf("format WORK: %w", err))
	}
	lines = append(lines, "FORMAT_WORK=PASS")

	postFormat, err := session.VerifyLayoutUnchanged(media)
	if err != nil {
		finish(false, fmt.Errorf("post-format GPT read-back: %w", err))
	}
	lines = append(lines,
		"POST_FORMAT_READBACK=PASS",
		"POST_FORMAT_DISK_PTUUID="+postFormat.DiskPTUUID,
		"POST_FORMAT_ESP_PARTUUID="+postFormat.ESP.PartUUID,
		"POST_FORMAT_DATA_PARTUUID="+postFormat.DATA.PartUUID,
		"POST_FORMAT_WORK_PARTUUID="+postFormat.WORK.PartUUID,
	)
	finish(true, nil)
}
