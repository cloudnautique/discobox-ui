package fdwait

import "golang.org/x/sys/unix"

// Darwin poll(2) reports POLLNVAL for /dev/tty even when read/write work.
// select(2) supports the controlling-terminal device. Use its bounded wait
// while keeping the separately opened, nonblocking descriptors; dup would
// share O_NONBLOCK with the inherited stdin/stdout open descriptions.
func ready(fd int, events int16) (bool, error) {
	if fd < 0 || fd >= unix.FD_SETSIZE {
		return false, unix.EINVAL
	}
	var fds unix.FdSet
	fds.Set(fd)
	var read, write *unix.FdSet
	switch events {
	case unix.POLLIN:
		read = &fds
	case unix.POLLOUT:
		write = &fds
	default:
		return false, unix.EINVAL
	}
	timeout := unix.NsecToTimeval(50_000_000)
	n, err := unix.Select(fd+1, read, write, nil, &timeout)
	return n > 0 && fds.IsSet(fd), err
}
