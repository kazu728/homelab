package receiver

import (
	"testing"

	"go.opentelemetry.io/otel/attribute"
)

func TestUsageMetricPoints(t *testing.T) {
	event := UsageEvent{
		Snapshot: Snapshot{
			Device:            "pixel-main",
			Date:              "2026-04-25",
			GeneratedAtMillis: 1777132800000,
			Metrics: []MetricRow{
				{
					Name:  DailyScreenMetric,
					Value: 120,
				},
				{
					Name:         AppForegroundMetric,
					LabelPackage: "com.example.social",
					Value:        45,
				},
			},
		},
		ReceivedAtUnix: 1777132900,
	}

	points := usageMetricPoints([]UsageEvent{event})
	if len(points) != 4 {
		t.Fatalf("points = %d, want 4: %#v", len(points), points)
	}

	assertMetricPoint(t, points, DailyScreenMetric, "", 120, map[string]string{
		"device": "pixel-main",
	})
	assertMetricPoint(t, points, AppForegroundMetric, "com.example.social", 45, map[string]string{
		"device":  "pixel-main",
		"package": "com.example.social",
	})
	assertMetricPoint(t, points, LastReceivedMetric, "", 1777132900, map[string]string{
		"device": "pixel-main",
	})
	assertMetricPoint(t, points, SnapshotDateMetric, "", float64(event.Snapshot.MustDateUnix()), map[string]string{
		"device": "pixel-main",
	})
}

func assertMetricPoint(
	t *testing.T,
	points []usageMetricPoint,
	name string,
	packageName string,
	value float64,
	attrs map[string]string,
) {
	t.Helper()

	point, ok := findMetricPoint(points, name, packageName)
	if !ok {
		t.Fatalf("missing metric point name=%q package=%q in %#v", name, packageName, points)
	}
	if point.Value != value {
		t.Fatalf("%s value = %v, want %v", name, point.Value, value)
	}
	if got := attributesByKey(point.Attributes); !equalStringMap(got, attrs) {
		t.Fatalf("%s attributes = %#v, want %#v", name, got, attrs)
	}
}

func findMetricPoint(points []usageMetricPoint, name, packageName string) (usageMetricPoint, bool) {
	for _, point := range points {
		attrs := attributesByKey(point.Attributes)
		if point.Name == name && attrs["package"] == packageName {
			return point, true
		}
	}
	return usageMetricPoint{}, false
}

func attributesByKey(attrs []attribute.KeyValue) map[string]string {
	result := make(map[string]string, len(attrs))
	for _, attr := range attrs {
		result[string(attr.Key)] = attr.Value.AsString()
	}
	return result
}

func equalStringMap(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for key, value := range a {
		if b[key] != value {
			return false
		}
	}
	return true
}
