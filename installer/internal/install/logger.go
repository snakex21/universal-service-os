package install

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type OperationLogger struct {
	mu   sync.Mutex
	file *os.File
	path string
}

func DefaultLogPath() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}
	return filepath.Join(filepath.Dir(executable), "USOS Installer.log"), nil
}

func NewOperationLogger() (*OperationLogger, error) {
	path, err := DefaultLogPath()
	if err != nil {
		return nil, err
	}
	return NewOperationLoggerAt(path)
}

func NewOperationLoggerAt(path string) (*OperationLogger, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open operation log %s: %w", path, err)
	}
	logger := &OperationLogger{file: file, path: path}
	if err := logger.WriteLine("=== nowa sesja instalatora ==="); err != nil {
		file.Close()
		return nil, err
	}
	return logger, nil
}

func (l *OperationLogger) Path() string {
	return l.path
}

func (l *OperationLogger) WriteLine(message string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return fmt.Errorf("operation log is closed")
	}
	_, err := fmt.Fprintf(l.file, "%s %s\r\n", time.Now().Format("2006-01-02 15:04:05.000"), message)
	if err != nil {
		return err
	}
	return l.file.Sync()
}

func (l *OperationLogger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}
