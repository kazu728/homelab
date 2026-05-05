package receiver

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	otelmetric "go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
)

const (
	telemetryServiceName = "android-usage-receiver"
	telemetryMeterName   = "github.com/kazu728/homelab/apps/android-usage-receiver"
)

type Telemetry struct {
	provider *sdkmetric.MeterProvider
}

type LatestReader interface {
	ListLatestSnapshots(ctx context.Context) ([]UsageEvent, error)
}

type usageInstruments struct {
	dailyScreen   otelmetric.Float64ObservableGauge
	appForeground otelmetric.Float64ObservableGauge
	lastReceived  otelmetric.Float64ObservableGauge
	snapshotDate  otelmetric.Float64ObservableGauge
}

type usageMetricPoint struct {
	Name       string
	Value      float64
	Attributes []attribute.KeyValue
}

func NewTelemetry(
	ctx context.Context,
	latestReader LatestReader,
	endpoint string,
	interval time.Duration,
) (*Telemetry, error) {
	exporter, err := newOTLPMetricExporter(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	provider := newMeterProvider(exporter, interval)
	meter := provider.Meter(telemetryMeterName)

	instruments, err := newUsageInstruments(meter)
	if err != nil {
		_ = provider.Shutdown(ctx)
		return nil, err
	}
	if err := registerUsageCallback(meter, latestReader, instruments); err != nil {
		_ = provider.Shutdown(ctx)
		return nil, err
	}

	return &Telemetry{provider: provider}, nil
}

func newOTLPMetricExporter(ctx context.Context, endpoint string) (sdkmetric.Exporter, error) {
	options := []otlpmetrichttp.Option{}
	if endpoint != "" {
		options = append(options, otlpmetrichttp.WithEndpointURL(endpoint))
	}

	exporter, err := otlpmetrichttp.New(ctx, options...)
	if err != nil {
		return nil, fmt.Errorf("create otlp metric exporter: %w", err)
	}
	return exporter, nil
}

func newMeterProvider(exporter sdkmetric.Exporter, interval time.Duration) *sdkmetric.MeterProvider {
	periodicReader := sdkmetric.NewPeriodicReader(
		exporter,
		sdkmetric.WithInterval(interval),
	)
	return sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(periodicReader),
		sdkmetric.WithResource(resource.NewWithAttributes(
			"",
			attribute.String("service.name", telemetryServiceName),
		)),
	)
}

func newUsageInstruments(meter otelmetric.Meter) (usageInstruments, error) {
	dailyGauge, err := meter.Float64ObservableGauge(
		DailyScreenMetric,
		otelmetric.WithDescription("Daily Android foreground usage time."),
		otelmetric.WithUnit("s"),
	)
	if err != nil {
		return usageInstruments{}, fmt.Errorf("create daily gauge: %w", err)
	}
	appGauge, err := meter.Float64ObservableGauge(
		AppForegroundMetric,
		otelmetric.WithDescription("Daily Android foreground usage time by app package."),
		otelmetric.WithUnit("s"),
	)
	if err != nil {
		return usageInstruments{}, fmt.Errorf("create app gauge: %w", err)
	}
	lastReceivedGauge, err := meter.Float64ObservableGauge(
		LastReceivedMetric,
		otelmetric.WithDescription("Unix time when the latest Android usage snapshot was received."),
		otelmetric.WithUnit("s"),
	)
	if err != nil {
		return usageInstruments{}, fmt.Errorf("create last received gauge: %w", err)
	}
	snapshotDateGauge, err := meter.Float64ObservableGauge(
		SnapshotDateMetric,
		otelmetric.WithDescription("Unix time for the latest Android usage snapshot date."),
		otelmetric.WithUnit("s"),
	)
	if err != nil {
		return usageInstruments{}, fmt.Errorf("create snapshot date gauge: %w", err)
	}

	return usageInstruments{
		dailyScreen:   dailyGauge,
		appForeground: appGauge,
		lastReceived:  lastReceivedGauge,
		snapshotDate:  snapshotDateGauge,
	}, nil
}

func registerUsageCallback(
	meter otelmetric.Meter,
	latestReader LatestReader,
	instruments usageInstruments,
) error {
	_, err := meter.RegisterCallback(
		func(ctx context.Context, observer otelmetric.Observer) error {
			snapshots, err := latestReader.ListLatestSnapshots(ctx)
			if err != nil {
				return err
			}

			observeUsageMetricPoints(observer, instruments, usageMetricPoints(snapshots))
			return nil
		},
		instruments.observables()...,
	)
	if err != nil {
		return fmt.Errorf("register metric callback: %w", err)
	}
	return nil
}

func (i usageInstruments) observables() []otelmetric.Observable {
	return []otelmetric.Observable{
		i.dailyScreen,
		i.appForeground,
		i.lastReceived,
		i.snapshotDate,
	}
}

func observeUsageMetricPoints(
	observer otelmetric.Observer,
	instruments usageInstruments,
	points []usageMetricPoint,
) {
	for _, point := range points {
		instrument, ok := instruments.instrument(point.Name)
		if !ok {
			continue
		}
		observer.ObserveFloat64(
			instrument,
			point.Value,
			otelmetric.WithAttributes(point.Attributes...),
		)
	}
}

func (i usageInstruments) instrument(name string) (otelmetric.Float64ObservableGauge, bool) {
	switch name {
	case DailyScreenMetric:
		return i.dailyScreen, true
	case AppForegroundMetric:
		return i.appForeground, true
	case LastReceivedMetric:
		return i.lastReceived, true
	case SnapshotDateMetric:
		return i.snapshotDate, true
	default:
		return nil, false
	}
}

func usageMetricPoints(events []UsageEvent) []usageMetricPoint {
	points := make([]usageMetricPoint, 0, len(events)*4)
	for _, event := range events {
		deviceAttributes := usageDeviceAttributes(event.Snapshot.Device)
		for _, row := range event.Snapshot.Metrics {
			switch row.Name {
			case DailyScreenMetric:
				points = append(points, usageMetricPoint{
					Name:       DailyScreenMetric,
					Value:      row.Value,
					Attributes: deviceAttributes,
				})
			case AppForegroundMetric:
				points = append(points, usageMetricPoint{
					Name:       AppForegroundMetric,
					Value:      row.Value,
					Attributes: usageAppAttributes(event.Snapshot.Device, row.LabelPackage),
				})
			}
		}
		points = append(points,
			usageMetricPoint{
				Name:       LastReceivedMetric,
				Value:      float64(event.ReceivedAtUnix),
				Attributes: deviceAttributes,
			},
			usageMetricPoint{
				Name:       SnapshotDateMetric,
				Value:      float64(event.Snapshot.MustDateUnix()),
				Attributes: deviceAttributes,
			},
		)
	}
	return points
}

func usageDeviceAttributes(device string) []attribute.KeyValue {
	return []attribute.KeyValue{
		attribute.String("device", device),
	}
}

func usageAppAttributes(device, packageName string) []attribute.KeyValue {
	return []attribute.KeyValue{
		attribute.String("device", device),
		attribute.String("package", packageName),
	}
}

func (t *Telemetry) Shutdown(ctx context.Context) error {
	return t.provider.Shutdown(ctx)
}
