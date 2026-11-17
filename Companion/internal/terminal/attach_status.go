package terminal

import (
	"encoding/json"
	"os"
	"syscall"
)

// A private FIFO carries connection state separately from remote terminal
// bytes. Nonblocking, single-record writes never backpressure the stream.
func attachStatusWriter(path string) (func(string, string), func()) {
	ignore, close := func(string, string) {}, func() {}
	if path == "" {
		return ignore, close
	}
	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return ignore, close
	}
	var stat syscall.Stat_t
	if syscall.Fstat(fd, &stat) != nil || stat.Mode&syscall.S_IFMT != syscall.S_IFIFO || stat.Uid != uint32(os.Getuid()) {
		_ = syscall.Close(fd)
		return ignore, close
	}
	return func(state, detail string) {
		switch state {
		case "connecting", "connected", "reconnecting", "reconnected", "disconnected", "ended", "output-stalled":
			if len(detail) > 512 {
				detail = detail[:512] + "…"
			}
			line, _ := json.Marshal(struct {
				State string `json:"state"`
				Error string `json:"error,omitempty"`
			}{state, detail})
			_, _ = syscall.Write(fd, append(line, '\n'))
		}
	}, func() { _ = syscall.Close(fd) }
}
