package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/kazu728/homelab/apps/android-usage-receiver/internal/receiver"
	"github.com/nats-io/nats.go"
	natsjetstream "github.com/nats-io/nats.go/jetstream"
)

const (
	listenPort   = "8080"
	natsURL      = "nats://nats.nats.svc.cluster.local:4222"
	streamName   = "ANDROID_USAGE_EVENTS"
	subject      = "homelab.android_usage.snapshot"
	kvBucket     = "android_usage_latest"
	durableName  = "android-usage-receiver"
	otlpEndpoint = "http://otel-collector-opentelemetry-collector.observability.svc.cluster.local:4318"
	exportEvery  = 60 * time.Second
)

type service struct {
	natsConn  *nats.Conn
	telemetry *receiver.Telemetry
	worker    *receiver.UsageWorker
	server    *http.Server
	logger    *slog.Logger
	workerWG  sync.WaitGroup
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("android usage receiver exited", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	svc, err := newService(ctx, logger)
	if err != nil {
		return err
	}

	svc.start(ctx, stop)

	<-ctx.Done()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return svc.shutdown(shutdownCtx)
}

func newService(ctx context.Context, logger *slog.Logger) (_ *service, err error) {
	natsConn, js, err := receiver.ConnectNATS(natsURL, os.Getenv("NATS_TOKEN"), "android-usage-receiver")
	if err != nil {
		return nil, fmt.Errorf("failed to initialize nats: %w", err)
	}

	var telemetry *receiver.Telemetry
	defer func() {
		if err == nil {
			return
		}

		if telemetry != nil {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if shutdownErr := telemetry.Shutdown(shutdownCtx); shutdownErr != nil {
				logger.Error("failed to shut down telemetry", "error", shutdownErr)
			}
		}
		natsConn.Close()
	}()

	initCtx, cancelInit := context.WithCancel(ctx)
	defer cancelInit()

	type ensureResult struct {
		kv  natsjetstream.KeyValue
		err error
	}
	results := make(chan ensureResult, 2)

	go func() {
		err := receiver.EnsureUsageStream(initCtx, js, receiver.NATSResources{
			StreamName: streamName,
			Subject:    subject,
			MaxAge:     receiver.DefaultStreamMaxAge,
		})
		results <- ensureResult{err: err}
	}()
	go func() {
		kv, err := receiver.EnsureUsageKV(initCtx, js, kvBucket)
		results <- ensureResult{kv: kv, err: err}
	}()

	var kv natsjetstream.KeyValue
	for range 2 {
		result := <-results
		if result.err != nil {
			return nil, result.err
		}
		if result.kv != nil {
			kv = result.kv
		}
	}

	store := receiver.NewNATSLatestStore(kv)
	telemetry, err = receiver.NewTelemetry(ctx, store, otlpEndpoint, exportEvery)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize telemetry: %w", err)
	}

	worker, err := receiver.NewUsageWorker(ctx, js, streamName, subject, durableName, store, logger)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize usage worker: %w", err)
	}

	app := receiver.NewApp(receiver.NewNATSPublisher(js, subject), logger)
	server := &http.Server{
		Addr:              ":" + listenPort,
		Handler:           app.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	return &service{
		natsConn:  natsConn,
		telemetry: telemetry,
		worker:    worker,
		server:    server,
		logger:    logger,
	}, nil
}

func (s *service) start(ctx context.Context, stop context.CancelFunc) {
	s.workerWG.Add(1)
	go func() {
		defer s.workerWG.Done()
		s.worker.Run(ctx)
	}()

	go func() {
		s.logger.Info(
			"android usage receiver listening",
			"addr", s.server.Addr,
			"nats_url", natsURL,
			"subject", subject,
			"kv_bucket", kvBucket,
			"otlp_endpoint", otlpEndpoint,
		)
		if err := s.server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			s.logger.Error("server failed", "error", err)
			stop()
		}
	}()
}

func (s *service) shutdown(ctx context.Context) error {
	var errs []error
	if err := s.server.Shutdown(ctx); err != nil {
		errs = append(errs, fmt.Errorf("server shutdown failed: %w", err))
	}

	workerDone := make(chan struct{})
	go func() {
		s.workerWG.Wait()
		close(workerDone)
	}()
	select {
	case <-workerDone:
	case <-ctx.Done():
		errs = append(errs, fmt.Errorf("worker shutdown timed out: %w", ctx.Err()))
	}

	if err := s.telemetry.Shutdown(ctx); err != nil {
		errs = append(errs, fmt.Errorf("telemetry shutdown failed: %w", err))
	}
	s.natsConn.Close()
	return errors.Join(errs...)
}
