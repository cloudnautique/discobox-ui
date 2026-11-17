package terminal

import (
	"context"
	"io"

	"github.com/discobox-ai/discobox/pkg/execstream"
	"github.com/discobox-ai/discobox/pkg/execstream/frame"
)

// Compatibility adapter for in-memory fixtures. Production uses the owned,
// nonblocking PTY below, never an arbitrary uncancellable io.Writer.
func pumpAttach(ctx context.Context, c execstream.Conn, input io.Reader, output io.Writer, sizes <-chan frame.ResizePayload) error {
	return pumpTerminal(ctx, c, terminalDelivery{
		read: func(_ context.Context, p []byte) (int, error) { return input.Read(p) },
		write: func(ctx context.Context, p []byte, progress func(int)) error {
			for len(p) > 0 {
				if err := ctx.Err(); err != nil {
					return err
				}
				n, err := output.Write(p)
				if n > 0 {
					progress(n)
					p = p[n:]
				}
				if err != nil {
					return err
				}
				if n == 0 {
					return io.ErrNoProgress
				}
			}
			return nil
		},
	}, sizes)
}
