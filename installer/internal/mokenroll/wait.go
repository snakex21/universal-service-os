package mokenroll

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
)

// VarMokTimeout is read by MokManager (shim 16.1 MokManager.c,
// draw_countdown): a packed INT32. A negative value skips the 10 s
// "Press any key to perform MOK management" countdown and opens the menu at
// once; MokManager deletes the variable after reading it, so it is single
// use and nothing has to be restored. It does not start MokManager by
// itself: shim runs MokManager when a request is pending or when the second
// stage fails verification ("Verification failed"), which is exactly the
// first start of the USOS drive on a computer without the USOS key.
const VarMokTimeout = "MokTimeout"

// NoCountdown is the MokTimeout value that makes MokManager wait on its menu.
const NoCountdown int32 = -1

// MokTimeoutValue encodes a MokTimeout payload.
func MokTimeoutValue(seconds int32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, uint32(seconds))
	return out
}

// WaitResult is what PrepareWait did.
type WaitResult struct {
	// AlreadyEnrolled: MokListRT (visible only on boots through shim)
	// already holds the certificate; nothing was written.
	AlreadyEnrolled bool
}

// PrepareWait writes MokTimeout = -1 (NV|BS|RT, as mokutil --timeout does)
// so MokManager, when shim starts it after "Verification failed", shows its
// menu and waits instead of counting down 10 s (a held or repeating key on
// a handheld could skip it). No key and no password is written: the user
// then picks "Enroll key from disk" -> USOS_ESP -> USOS-KEY.cer. The value is
// read back and compared.
func PrepareWait(fw Firmware, der []byte) (WaitResult, error) {
	if err := CheckCertificate(der); err != nil {
		return WaitResult{}, err
	}
	uefi, err := fw.UEFI()
	if err != nil {
		return WaitResult{}, err
	}
	if !uefi {
		return WaitResult{}, ErrNotUEFI
	}
	if list, _, err := fw.Get(VarMokListRT, ShimLockGUID); err == nil {
		if found, _ := ContainsX509(list, der); found {
			return WaitResult{AlreadyEnrolled: true}, nil
		}
	}
	value := MokTimeoutValue(NoCountdown)
	if err := fw.Set(VarMokTimeout, ShimLockGUID, value, MokAttributes); err != nil {
		return WaitResult{}, fmt.Errorf("write %s: %w", VarMokTimeout, err)
	}
	got, _, err := fw.Get(VarMokTimeout, ShimLockGUID)
	if err != nil {
		return WaitResult{}, fmt.Errorf("read back %s: %w", VarMokTimeout, err)
	}
	if !bytes.Equal(got, value) {
		return WaitResult{}, fmt.Errorf("read back %s: % x, expected % x", VarMokTimeout, got, value)
	}
	return WaitResult{}, nil
}

// WaitPending reports whether MokTimeout is set (MokManager has not run
// since it was prepared).
func WaitPending(fw Firmware) bool {
	_, _, err := fw.Get(VarMokTimeout, ShimLockGUID)
	return err == nil
}

// CancelWait deletes MokTimeout (e.g. after the key was saved another way).
func CancelWait(fw Firmware) error {
	if err := fw.Set(VarMokTimeout, ShimLockGUID, nil, MokAttributes); err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}
	return nil
}
