package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/Reilley64/homelab/observability/internal/agent"
)

func main() {
	logger := log.New(os.Stderr, "", log.LstdFlags)
	settings, err := agent.LoadSettings(os.Getenv)
	if err != nil {
		logger.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := agent.NewRuntime(settings, nil, logger).Run(ctx); err != nil {
		logger.Fatal(err)
	}
}
