package fdwait

import (
	"io"

	"golang.org/x/sys/unix"
)

func ready(fd int, events int16) (bool, error) {
	poll := []unix.PollFd{{Fd: int32(fd), Events: events}}
	_, err := unix.Poll(poll, 50)
	if err != nil {
		return false, err
	}
	if poll[0].Revents&unix.POLLNVAL != 0 {
		return false, unix.EBADF
	}
	// Drain readable bytes before reporting a hangup.
	if poll[0].Revents&events != 0 {
		return true, nil
	}
	if poll[0].Revents&(unix.POLLERR|unix.POLLHUP) != 0 {
		return false, io.EOF
	}
	return false, nil
}
