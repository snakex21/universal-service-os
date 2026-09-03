package uninstall

import "fmt"

type StageID uint8

const (
	StageClean StageID = iota + 1
	StageCreateSinglePartition
	StageFormatExFAT
	StageVerify
	StageCount = 4
)

type Stage struct {
	ID     StageID
	Number int
	Name   string
}

var stages = map[StageID]Stage{
	StageClean:                 {ID: StageClean, Number: 1, Name: "Czyszczenie tablicy partycji"},
	StageCreateSinglePartition: {ID: StageCreateSinglePartition, Number: 2, Name: "Tworzenie jednej partycji danych"},
	StageFormatExFAT:           {ID: StageFormatExFAT, Number: 3, Name: "Formatowanie exFAT"},
	StageVerify:                {ID: StageVerify, Number: 4, Name: "Weryfikacja"},
}

func StageInfo(id StageID) (Stage, bool) {
	stage, ok := stages[id]
	return stage, ok
}

func StageCaption(id StageID) string {
	stage, ok := StageInfo(id)
	if !ok {
		return fmt.Sprintf("nieznany etap %d", id)
	}
	return fmt.Sprintf("%d/%d — %s", stage.Number, StageCount, stage.Name)
}

type EventKind uint8

const (
	EventStage EventKind = iota + 1
	EventLog
	EventFinished
)

type State uint8

const (
	StatePending State = iota
	StateActive
	StateSucceeded
	StateFailed
)

type Event struct {
	Kind         EventKind
	StageID      StageID
	State        State
	Message      string
	Err          error
	Verification *VerificationReport
}
