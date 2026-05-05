package receiver

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/nats-io/nats.go"
	natsjetstream "github.com/nats-io/nats.go/jetstream"
)

const (
	// DefaultStreamMaxAge は ANDROID_USAGE_EVENTS ストリームに保持するイベントの最大寿命 (7 日)。
	DefaultStreamMaxAge  = 7 * 24 * time.Hour
	natsOperationTimeout = 10 * time.Second
	defaultWorkerBatch   = 16
	defaultWorkerMaxWait = time.Second
)

type NATSResources struct {
	StreamName string
	Subject    string
	MaxAge     time.Duration
}

type NATSPublisher struct {
	js      natsjetstream.JetStream
	subject string
}

type NATSLatestStore struct {
	kv natsjetstream.KeyValue
}

type UsageWorker struct {
	consumer natsjetstream.Consumer
	store    *NATSLatestStore
	logger   *slog.Logger
	batch    int
	maxWait  time.Duration
}

func ConnectNATS(url, token, name string) (*nats.Conn, natsjetstream.JetStream, error) {
	options := []nats.Option{
		nats.Name(name),
		nats.Timeout(10 * time.Second),
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2 * time.Second),
	}
	if token != "" {
		options = append(options, nats.Token(token))
	}

	conn, err := nats.Connect(url, options...)
	if err != nil {
		return nil, nil, fmt.Errorf("connect nats: %w", err)
	}

	js, err := natsjetstream.New(conn)
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("create jetstream context: %w", err)
	}
	return conn, js, nil
}

func EnsureUsageStream(ctx context.Context, js natsjetstream.JetStream, resources NATSResources) error {
	ctx, cancel := context.WithTimeout(ctx, natsOperationTimeout)
	defer cancel()

	config := natsjetstream.StreamConfig{
		Name:      resources.StreamName,
		Subjects:  []string{resources.Subject},
		Retention: natsjetstream.LimitsPolicy,
		Storage:   natsjetstream.FileStorage,
		MaxAge:    resources.MaxAge,
		// 同一 MessageID の重複 publish を 24h ウィンドウで抑止する。
		Duplicates: 24 * time.Hour,
	}

	if _, err := js.CreateOrUpdateStream(ctx, config); err != nil {
		return fmt.Errorf("ensure nats stream %q: %w", resources.StreamName, err)
	}
	return nil
}

func EnsureUsageKV(ctx context.Context, js natsjetstream.JetStream, bucket string) (natsjetstream.KeyValue, error) {
	ctx, cancel := context.WithTimeout(ctx, natsOperationTimeout)
	defer cancel()

	kv, err := js.CreateOrUpdateKeyValue(ctx, natsjetstream.KeyValueConfig{
		Bucket:  bucket,
		Storage: natsjetstream.FileStorage,
		History: 1,
	})
	if err != nil {
		return nil, fmt.Errorf("ensure nats kv bucket %q: %w", bucket, err)
	}
	return kv, nil
}

func NewNATSPublisher(js natsjetstream.JetStream, subject string) *NATSPublisher {
	return &NATSPublisher{js: js, subject: subject}
}

func (p *NATSPublisher) PublishUsage(ctx context.Context, event UsageEvent) error {
	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("encode usage event: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, natsOperationTimeout)
	defer cancel()

	if _, err := p.js.Publish(ctx, p.subject, data, natsjetstream.WithMsgID(event.Snapshot.MessageID())); err != nil {
		return fmt.Errorf("publish usage event: %w", err)
	}
	return nil
}

func NewNATSLatestStore(kv natsjetstream.KeyValue) *NATSLatestStore {
	return &NATSLatestStore{kv: kv}
}

func (s *NATSLatestStore) SaveLatest(ctx context.Context, event UsageEvent) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}

	key := latestKey(event.Snapshot.Device)
	current, err := s.get(ctx, key)
	if err != nil && !errors.Is(err, natsjetstream.ErrKeyNotFound) && !errors.Is(err, natsjetstream.ErrKeyDeleted) {
		return false, err
	}
	if err == nil && !IsNewerSnapshot(event.Snapshot, current.Snapshot) {
		return false, nil
	}

	data, err := json.Marshal(event)
	if err != nil {
		return false, fmt.Errorf("encode latest snapshot: %w", err)
	}
	if _, err := s.kv.Put(ctx, key, data); err != nil {
		return false, fmt.Errorf("write latest snapshot %q: %w", key, err)
	}
	return true, nil
}

func (s *NATSLatestStore) ListLatestSnapshots(ctx context.Context) ([]UsageEvent, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	keys, err := s.kv.Keys(ctx)
	if errors.Is(err, natsjetstream.ErrNoKeysFound) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("list latest snapshot keys: %w", err)
	}

	snapshots := make([]UsageEvent, 0, len(keys))
	for _, key := range keys {
		event, err := s.get(ctx, key)
		if errors.Is(err, natsjetstream.ErrKeyNotFound) || errors.Is(err, natsjetstream.ErrKeyDeleted) {
			continue
		}
		if err != nil {
			return nil, err
		}
		snapshots = append(snapshots, event)
	}
	sort.Slice(snapshots, func(i, j int) bool {
		return snapshots[i].Snapshot.Device < snapshots[j].Snapshot.Device
	})
	return snapshots, nil
}

func (s *NATSLatestStore) get(ctx context.Context, key string) (UsageEvent, error) {
	entry, err := s.kv.Get(ctx, key)
	if err != nil {
		return UsageEvent{}, err
	}

	var event UsageEvent
	if err := json.Unmarshal(entry.Value(), &event); err != nil {
		return UsageEvent{}, fmt.Errorf("decode latest snapshot %q: %w", key, err)
	}
	return event, nil
}

func NewUsageWorker(
	ctx context.Context,
	js natsjetstream.JetStream,
	streamName string,
	subject string,
	durableName string,
	store *NATSLatestStore,
	logger *slog.Logger,
) (*UsageWorker, error) {
	ctx, cancel := context.WithTimeout(ctx, natsOperationTimeout)
	defer cancel()

	consumer, err := js.CreateOrUpdateConsumer(ctx, streamName, natsjetstream.ConsumerConfig{
		Name:          durableName,
		Durable:       durableName,
		AckPolicy:     natsjetstream.AckExplicitPolicy,
		FilterSubject: subject,
	})
	if err != nil {
		return nil, fmt.Errorf("ensure usage consumer %q: %w", durableName, err)
	}
	return &UsageWorker{
		consumer: consumer,
		store:    store,
		logger:   logger,
		batch:    defaultWorkerBatch,
		maxWait:  defaultWorkerMaxWait,
	}, nil
}

func (w *UsageWorker) Run(ctx context.Context) {
	for ctx.Err() == nil {
		if err := w.fetchAndProcess(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			w.logger.Error("failed to fetch usage events", "error", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}

func (w *UsageWorker) fetchAndProcess(ctx context.Context) error {
	fetchCtx, cancel := context.WithTimeout(ctx, w.maxWait)
	defer cancel()

	batch, err := w.consumer.Fetch(w.batch, natsjetstream.FetchContext(fetchCtx))
	if err != nil {
		return err
	}

	for msg := range batch.Messages() {
		w.process(ctx, msg)
	}
	if err := batch.Error(); err != nil && !errors.Is(err, natsjetstream.ErrNoMessages) {
		return err
	}
	return nil
}

func (w *UsageWorker) process(ctx context.Context, msg natsjetstream.Msg) {
	var event UsageEvent
	if err := json.Unmarshal(msg.Data(), &event); err != nil {
		w.logger.Error("dropping invalid usage event", "error", err)
		if err := msg.Term(); err != nil {
			w.logger.Error("failed to terminate invalid usage event", "error", err)
		}
		return
	}

	updated, err := w.store.SaveLatest(ctx, event)
	if err != nil {
		w.logger.Error("failed to save latest usage snapshot", "device", event.Snapshot.Device, "error", err)
		if err := msg.Nak(); err != nil {
			w.logger.Error("failed to nak usage event", "error", err)
		}
		return
	}

	if err := msg.Ack(); err != nil {
		w.logger.Error("failed to ack usage event", "device", event.Snapshot.Device, "error", err)
		return
	}
	if updated {
		w.logger.Info("updated latest usage snapshot", "device", event.Snapshot.Device, "date", event.Snapshot.Date)
	}
}

func latestKey(device string) string {
	sum := sha256.Sum256([]byte(device))
	return "device." + hex.EncodeToString(sum[:])
}
