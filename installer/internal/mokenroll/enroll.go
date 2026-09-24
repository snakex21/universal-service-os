package mokenroll

import (
	"bytes"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
)

// PayloadCertPath is where the release puts the USOS MOK certificate (DER)
// inside the installer payload and on the drive.
const PayloadCertPath = "EFI/USOS/ENROLL_THIS_KEY_IN_MOKMANAGER.cer"

// Firmware is the UEFI variable store. The Windows implementation is
// System(); tests use a fake so no real variable is ever written by them.
type Firmware interface {
	// UEFI reports whether the running system booted in UEFI mode.
	UEFI() (bool, error)
	// Get returns a variable and its attributes, or ErrNotFound.
	Get(name string, vendor GUID) (data []byte, attributes uint32, err error)
	// Set writes a variable; empty data deletes it.
	Set(name string, vendor GUID, data []byte, attributes uint32) error
}

var (
	// ErrNotFound: the variable does not exist.
	ErrNotFound = errors.New("firmware variable not found")
	// ErrNotUEFI: Windows was started in legacy BIOS (CSM) mode, so there are
	// no UEFI variables; shim and MokManager are UEFI-only anyway.
	ErrNotUEFI = errors.New("this computer was not started in UEFI mode, so UEFI variables cannot be written")
	// ErrPrivilege: SeSystemEnvironmentPrivilege is missing (not elevated).
	ErrPrivilege = errors.New("administrator rights (SeSystemEnvironmentPrivilege) are required")
	// ErrUnsupported: no firmware access on this platform.
	ErrUnsupported = errors.New("UEFI variable access is only implemented on Windows")
)

// Result describes what Prepare did.
type Result struct {
	// AlreadyEnrolled: MokListRT already holds the certificate, nothing was
	// written.
	AlreadyEnrolled bool
	// MergedPending: another pending MokNew request was kept after ours.
	MergedPending bool
	MokNew        []byte
	MokAuth       []byte
}

// Request builds the MokNew and MokAuth payloads for der and password
// without touching any firmware (also used to dump them for QEMU tests).
func Request(der []byte, password string, existingMokNew []byte, random io.Reader) (mokNew, mokAuth []byte, merged bool, err error) {
	if err := CheckCertificate(der); err != nil {
		return nil, nil, false, err
	}
	if err := ValidatePassword(password); err != nil {
		return nil, nil, false, err
	}
	salt, err := NewSalt(random)
	if err != nil {
		return nil, nil, false, err
	}
	mokAuth, err = BuildMokAuth(password, salt)
	if err != nil {
		return nil, nil, false, err
	}
	mokNew, merged = BuildMokNew(der, existingMokNew)
	return mokNew, mokAuth, merged, nil
}

// CheckCertificate makes sure der is one parseable X.509 certificate.
func CheckCertificate(der []byte) error {
	if len(der) == 0 {
		return errors.New("certificate is empty")
	}
	if _, err := x509.ParseCertificate(der); err != nil {
		return fmt.Errorf("certificate is not a DER X.509 certificate: %w", err)
	}
	return nil
}

// Prepare writes an enrollment request for der protected by password:
// MokNew first, then MokAuth. When MokAuth cannot be written the previous
// MokNew is restored (or MokNew deleted), so shim is never left with a
// request it cannot authenticate. Both variables are read back and compared.
func Prepare(fw Firmware, der []byte, password string, random io.Reader) (Result, error) {
	if err := CheckCertificate(der); err != nil {
		return Result{}, err
	}
	if err := ValidatePassword(password); err != nil {
		return Result{}, err
	}
	uefi, err := fw.UEFI()
	if err != nil {
		return Result{}, err
	}
	if !uefi {
		return Result{}, ErrNotUEFI
	}
	// MokListRT only exists when this boot went through shim; when it does
	// and already holds the key there is nothing to do.
	if list, _, err := fw.Get(VarMokListRT, ShimLockGUID); err == nil {
		if found, _ := ContainsX509(list, der); found {
			return Result{AlreadyEnrolled: true}, nil
		}
	}
	previous, _, err := fw.Get(VarMokNew, ShimLockGUID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return Result{}, fmt.Errorf("read %s: %w", VarMokNew, err)
	}
	mokNew, mokAuth, merged, err := Request(der, password, previous, random)
	if err != nil {
		return Result{}, err
	}
	if err := fw.Set(VarMokNew, ShimLockGUID, mokNew, MokAttributes); err != nil {
		return Result{}, fmt.Errorf("write %s: %w", VarMokNew, err)
	}
	if err := fw.Set(VarMokAuth, ShimLockGUID, mokAuth, MokAttributes); err != nil {
		if rollback := fw.Set(VarMokNew, ShimLockGUID, previous, MokAttributes); rollback != nil {
			return Result{}, fmt.Errorf("write %s: %w (restoring %s also failed: %v)", VarMokAuth, err, VarMokNew, rollback)
		}
		return Result{}, fmt.Errorf("write %s: %w", VarMokAuth, err)
	}
	for _, v := range []struct {
		name string
		want []byte
	}{{VarMokNew, mokNew}, {VarMokAuth, mokAuth}} {
		got, attrs, err := fw.Get(v.name, ShimLockGUID)
		if err != nil {
			return Result{}, fmt.Errorf("read back %s: %w", v.name, err)
		}
		if !bytes.Equal(got, v.want) {
			return Result{}, fmt.Errorf("read back %s: content differs (%d bytes, expected %d)", v.name, len(got), len(v.want))
		}
		if attrs != 0 && attrs&MokAttributes != MokAttributes {
			return Result{}, fmt.Errorf("read back %s: attributes 0x%x, expected 0x%x", v.name, attrs, MokAttributes)
		}
	}
	return Result{MergedPending: merged, MokNew: mokNew, MokAuth: mokAuth}, nil
}

// Tri-state answers for Status.
type Tri int8

const (
	Unknown Tri = iota
	No
	Yes
)

func (t Tri) String() string {
	switch t {
	case Yes:
		return "yes"
	case No:
		return "no"
	}
	return "unknown"
}

// Status is what Check found.
type Status struct {
	UEFI       bool
	SecureBoot Tri
	// Enrolled comes from MokListRT, which shim creates only on boots that
	// went through it; on a normal Windows boot it is Unknown.
	Enrolled Tri
	// Pending: MokNew holds the certificate (a request waits for MokManager).
	Pending bool
	// PendingAuth: MokAuth exists next to it.
	PendingAuth bool
}

// Check reads the Secure Boot state, MokListRT and a pending request. It
// never writes.
func Check(fw Firmware, der []byte) (Status, error) {
	var st Status
	uefi, err := fw.UEFI()
	if err != nil {
		return st, err
	}
	st.UEFI = uefi
	if !uefi {
		return st, nil
	}
	if v, _, err := fw.Get(VarSecureBoot, GlobalVariableGUID); err == nil && len(v) >= 1 {
		st.SecureBoot = No
		if v[0] == 1 {
			st.SecureBoot = Yes
		}
	}
	if list, _, err := fw.Get(VarMokListRT, ShimLockGUID); err == nil {
		st.Enrolled = No
		if found, _ := ContainsX509(list, der); found {
			st.Enrolled = Yes
		}
	}
	if pending, _, err := fw.Get(VarMokNew, ShimLockGUID); err == nil {
		st.Pending, _ = ContainsX509(pending, der)
	}
	if _, _, err := fw.Get(VarMokAuth, ShimLockGUID); err == nil {
		st.PendingAuth = true
	}
	return st, nil
}

// String is a one-line summary for logs and the CLI.
func (s Status) String() string {
	if !s.UEFI {
		return "firmware=legacy-bios"
	}
	return fmt.Sprintf("firmware=uefi secure_boot=%s enrolled=%s pending_request=%v pending_password=%v", s.SecureBoot, s.Enrolled, s.Pending, s.PendingAuth)
}
