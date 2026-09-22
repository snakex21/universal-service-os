package install

import "fmt"

type StageID uint8

const (
	StageCleanPartitionTable StageID = iota + 1
	StageCreateGPT
	StageWriteLegacyBoot
	StageFormatESP
	StageFormatDATA
	StageFormatWORK
	StageCopyESP
	StageWriteIdentity
	StageVerify
	StageCount = 9
)

type StageState uint8

const (
	StatePending StageState = iota
	StateActive
	StateSucceeded
	StateFailed
)

type StageDefinition struct {
	ID         StageID
	Number     int
	Name       string
	Measurable bool
}

var stages = [...]StageDefinition{
	{StageCleanPartitionTable, 1, "Czyszczenie tablicy partycji", false},
	{StageCreateGPT, 2, "Tworzenie GPT i partycji", false},
	{StageWriteLegacyBoot, 3, "Zapis Legacy BIOS Stage 1 i Core", false},
	{StageFormatESP, 4, "Formatowanie ESP (FAT32)", false},
	{StageFormatDATA, 5, "Formatowanie DATA (NTFS)", false},
	{StageFormatWORK, 6, "Formatowanie WORK (NTFS)", false},
	{StageCopyESP, 7, "Kopiowanie payloadu na ESP i DATA", true},
	{StageWriteIdentity, 8, "Zapis usos-device.ini i .usos-work", false},
	{StageVerify, 9, "Weryfikacja", false},
}

func Stages() []StageDefinition {
	result := make([]StageDefinition, len(stages))
	copy(result, stages[:])
	return result
}

func Stage(id StageID) (StageDefinition, bool) {
	if id < 1 || id > StageCount {
		return StageDefinition{}, false
	}
	return stages[id-1], true
}

type EventKind uint8

const (
	EventStage EventKind = iota + 1
	EventLog
	EventFinished
)

type Event struct {
	Kind          EventKind
	StageID       StageID
	State         StageState
	ProgressKnown bool
	Progress      float64
	Message       string
	Verification  *VerificationReport
	Err           error
}

func StageCaption(id StageID) string {
	stage, ok := Stage(id)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d/%d — %s", stage.Number, StageCount, stage.Name)
}
