package payload

import (
	"encoding/base64"
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
)

func LegacyBoot() (legacyboot.Payload, error) {
	stage1, err := base64.StdEncoding.DecodeString(legacyStage1Base64)
	if err != nil {
		return legacyboot.Payload{}, fmt.Errorf("decode embedded Legacy Stage 1: %w", err)
	}
	core, err := base64.StdEncoding.DecodeString(legacyCoreBase64)
	if err != nil {
		return legacyboot.Payload{}, fmt.Errorf("decode embedded Legacy Core: %w", err)
	}
	result := legacyboot.Payload{Stage1: stage1, Core: core}
	if err := result.Validate(); err != nil {
		return legacyboot.Payload{}, err
	}
	if actual := legacyboot.SHA256(stage1); actual != legacyStage1SHA256 {
		return legacyboot.Payload{}, fmt.Errorf("embedded Legacy Stage 1 SHA-256 mismatch: got %s want %s", actual, legacyStage1SHA256)
	}
	if actual := legacyboot.SHA256(core); actual != legacyCoreSHA256 {
		return legacyboot.Payload{}, fmt.Errorf("embedded Legacy Core SHA-256 mismatch: got %s want %s", actual, legacyCoreSHA256)
	}
	return result, nil
}
