package receiver

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"time"
)

const defaultMaxBodyBytes = int64(1 << 20) // 1 MiB

type EventPublisher interface {
	PublishUsage(ctx context.Context, event UsageEvent) error
}

type App struct {
	publisher    EventPublisher
	logger       *slog.Logger
	handler      http.Handler
	maxBodyBytes int64
}

func NewApp(publisher EventPublisher, logger *slog.Logger) *App {
	a := &App{
		publisher:    publisher,
		logger:       logger,
		maxBodyBytes: defaultMaxBodyBytes,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.handleHealth)
	mux.HandleFunc("/android-usage", a.handleAndroidUsage)
	a.handler = mux
	return a
}

func (a *App) Handler() http.Handler {
	return a.handler
}

func (a *App) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok\n"))
}

func (a *App) handleAndroidUsage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, a.maxBodyBytes))
	if err != nil {
		http.Error(w, "request body is too large", http.StatusRequestEntityTooLarge)
		return
	}

	decoded, err := decodePayload(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if decoded.IsTest {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	event := UsageEvent{
		Snapshot:       decoded.Snapshot,
		ReceivedAtUnix: time.Now().UTC().Unix(),
	}
	if err := a.publisher.PublishUsage(r.Context(), event); err != nil {
		a.logger.Error("publish usage failed", "error", err, "device", event.Snapshot.Device)
		http.Error(w, "queue publish failed", http.StatusServiceUnavailable)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func methodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	w.WriteHeader(http.StatusMethodNotAllowed)
}
