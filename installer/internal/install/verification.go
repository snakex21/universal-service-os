package install

type VerificationItem struct {
	Name     string
	Expected string
	Actual   string
	Match    bool
}

type VerificationReport struct {
	Items []VerificationItem
}

func (r VerificationReport) OK() bool {
	if len(r.Items) == 0 {
		return false
	}
	for _, item := range r.Items {
		if !item.Match {
			return false
		}
	}
	return true
}
