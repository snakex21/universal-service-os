package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
)

// mokRequest writes the MokNew and MokAuth variable payloads that
// "mokutil --import <cert>" (and the installer's "prepare key enrollment")
// would store, as plain files, so a QEMU test can load them into OVMF NVRAM
// with a small EFI app. It never touches this computer's firmware.
//
//	usos-efisign mok-request -cert assets/secure-boot/usos-secure-boot.cer -password usos -out DIR
func mokRequest(args []string) error {
	set := flag.NewFlagSet("mok-request", flag.ExitOnError)
	certPath := set.String("cert", "", "DER certificate to enroll")
	password := set.String("password", mokenroll.DefaultPassword, "MokManager password (1-16 printable ASCII characters)")
	out := set.String("out", "", "output directory for MokNew.bin and MokAuth.bin")
	set.Parse(args)
	if *certPath == "" || *out == "" {
		return errors.New("mok-request needs -cert and -out")
	}
	der, err := os.ReadFile(*certPath)
	if err != nil {
		return err
	}
	mokNew, mokAuth, _, err := mokenroll.Request(der, *password, nil, nil)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return err
	}
	for name, data := range map[string][]byte{"MokNew.bin": mokNew, "MokAuth.bin": mokAuth} {
		if err := writeFileAtomic(filepath.Join(*out, name), data); err != nil {
			return err
		}
	}
	fmt.Printf("[MOK] %s: MokNew.bin %d bytes, MokAuth.bin %d bytes; vendor %s attributes 0x%x\n",
		*out, len(mokNew), len(mokAuth), mokenroll.ShimLockGUID, mokenroll.MokAttributes)
	return nil
}
