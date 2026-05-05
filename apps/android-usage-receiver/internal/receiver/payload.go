package receiver

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	TestPayloadType   = "android_usage_exporter_test"
	DailySnapshotType = "android_usage_daily_snapshot"

	// 1 日に foreground 利用するアプリ件数の現実的な上限。payload メモリを抑制する。
	maxAppForegroundRows = 200
)

type decodedPayload struct {
	IsTest   bool
	Snapshot Snapshot
}

type payload struct {
	Type              string          `json:"type"`
	Version           int             `json:"version"`
	Device            string          `json:"device"`
	Date              string          `json:"date"`
	GeneratedAtMillis int64           `json:"generatedAtMillis"`
	Metrics           []payloadMetric `json:"metrics"`
}

type payloadMetric struct {
	Name   string            `json:"name"`
	Value  json.Number       `json:"value"`
	Labels map[string]string `json:"labels"`
}

func decodePayload(body []byte) (decodedPayload, error) {
	var incoming payload
	if err := json.Unmarshal(body, &incoming); err != nil {
		return decodedPayload{}, fmt.Errorf("decode payload: %w", err)
	}

	if incoming.Type == TestPayloadType {
		if incoming.Version != 1 {
			return decodedPayload{}, errors.New("test payload version must be 1")
		}
		return decodedPayload{IsTest: true}, nil
	}

	snapshot, err := validateDailySnapshot(incoming)
	if err != nil {
		return decodedPayload{}, err
	}
	return decodedPayload{Snapshot: snapshot}, nil
}

func validateDailySnapshot(incoming payload) (Snapshot, error) {
	if incoming.Type != DailySnapshotType {
		return Snapshot{}, fmt.Errorf("unsupported payload type %q", incoming.Type)
	}
	if incoming.Version != 1 {
		return Snapshot{}, errors.New("payload version must be 1")
	}
	if incoming.Device == "" {
		return Snapshot{}, errors.New("device is required")
	}
	if _, err := time.Parse("2006-01-02", incoming.Date); err != nil {
		return Snapshot{}, errors.New("date must use YYYY-MM-DD")
	}
	if incoming.GeneratedAtMillis <= 0 {
		return Snapshot{}, errors.New("generatedAtMillis must be positive")
	}
	if len(incoming.Metrics) == 0 {
		return Snapshot{}, errors.New("metrics must not be empty")
	}

	seen := make(map[string]struct{}, len(incoming.Metrics))
	rows := make([]MetricRow, 0, len(incoming.Metrics))
	appForegroundRows := 0
	for _, metric := range incoming.Metrics {
		row, err := validateMetric(incoming.Device, incoming.Date, metric)
		if err != nil {
			return Snapshot{}, err
		}
		if row.Name == AppForegroundMetric {
			appForegroundRows++
			if appForegroundRows > maxAppForegroundRows {
				return Snapshot{}, fmt.Errorf("more than %d %q rows", maxAppForegroundRows, AppForegroundMetric)
			}
		}
		key := row.Name + "\x00" + row.LabelPackage
		if _, ok := seen[key]; ok {
			return Snapshot{}, fmt.Errorf("duplicate metric %q", row.Name)
		}
		seen[key] = struct{}{}
		rows = append(rows, row)
	}

	return Snapshot{
		Device:            incoming.Device,
		Date:              incoming.Date,
		GeneratedAtMillis: incoming.GeneratedAtMillis,
		Metrics:           rows,
	}, nil
}

func validateMetric(device, date string, metric payloadMetric) (MetricRow, error) {
	value, err := metric.Value.Float64()
	if err != nil {
		return MetricRow{}, fmt.Errorf("metric %q value must be numeric", metric.Name)
	}
	if value < 0 {
		return MetricRow{}, fmt.Errorf("metric %q value must be non-negative", metric.Name)
	}

	switch metric.Name {
	case DailyScreenMetric:
		return MetricRow{
			Device: device,
			Date:   date,
			Name:   metric.Name,
			Value:  value,
		}, nil
	case AppForegroundMetric:
		packageName := metric.Labels["package"]
		if packageName == "" {
			return MetricRow{}, fmt.Errorf("metric %q requires labels.package", metric.Name)
		}
		return MetricRow{
			Device:       device,
			Date:         date,
			Name:         metric.Name,
			LabelPackage: packageName,
			Value:        value,
		}, nil
	default:
		return MetricRow{}, fmt.Errorf("unsupported metric %q", metric.Name)
	}
}
