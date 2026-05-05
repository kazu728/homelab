package receiver_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/kazu728/homelab/apps/android-usage-receiver/internal/receiver"
)

func newTestApp(publisher receiver.EventPublisher) *receiver.App {
	return receiver.NewApp(publisher, slog.New(slog.DiscardHandler))
}

func TestRoutes(t *testing.T) {
	tests := []struct {
		name      string
		method    string
		path      string
		wantCode  int
		wantAllow string
	}{
		{
			name:     "health",
			method:   http.MethodGet,
			path:     "/health",
			wantCode: http.StatusOK,
		},
		{
			name:      "health rejects post",
			method:    http.MethodPost,
			path:      "/health",
			wantCode:  http.StatusMethodNotAllowed,
			wantAllow: http.MethodGet,
		},
		{
			name:      "usage rejects get",
			method:    http.MethodGet,
			path:      "/android-usage",
			wantCode:  http.StatusMethodNotAllowed,
			wantAllow: http.MethodPost,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := newTestApp(&fakePublisher{})
			request := httptest.NewRequest(tt.method, tt.path, nil)
			response := httptest.NewRecorder()

			app.Handler().ServeHTTP(response, request)

			if response.Code != tt.wantCode {
				t.Fatalf("status = %d, want %d: %s", response.Code, tt.wantCode, response.Body.String())
			}
			if allow := response.Header().Get("Allow"); allow != tt.wantAllow {
				t.Fatalf("Allow = %q, want %q", allow, tt.wantAllow)
			}
		})
	}
}

func TestPostAndroidUsage(t *testing.T) {
	publishErr := errors.New("nats unavailable")
	tests := []struct {
		name          string
		body          string
		publishErr    error
		wantStatus    int
		wantPublished int
		assertEvent   func(t *testing.T, event receiver.UsageEvent)
	}{
		{
			name:          "publishes valid snapshot",
			body:          validPayload("2026-04-25", 120),
			wantStatus:    http.StatusNoContent,
			wantPublished: 1,
			assertEvent: func(t *testing.T, event receiver.UsageEvent) {
				if event.Snapshot.Device != "pixel-main" {
					t.Fatalf("device = %q, want pixel-main", event.Snapshot.Device)
				}
				if event.Snapshot.Date != "2026-04-25" {
					t.Fatalf("date = %q, want 2026-04-25", event.Snapshot.Date)
				}
				if event.ReceivedAtUnix <= 0 {
					t.Fatalf("received at unix = %v, want positive", event.ReceivedAtUnix)
				}
				metrics := rowsByName(event.Snapshot.Metrics)
				if metrics[receiver.DailyScreenMetric].Value != 120 {
					t.Fatalf("daily metric = %#v", metrics[receiver.DailyScreenMetric])
				}
				appMetric := metrics[receiver.AppForegroundMetric]
				if appMetric.LabelPackage != "com.example.social" || appMetric.Value != 120 {
					t.Fatalf("app metric = %#v", appMetric)
				}
			},
		},
		{
			name:       "test payload is noop",
			body:       `{"type":"android_usage_exporter_test","version":1}`,
			wantStatus: http.StatusNoContent,
		},
		{
			name:       "rejects invalid payload",
			body:       `{"type":"android_usage_daily_snapshot","version":1}`,
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "rejects duplicate metrics",
			body:       dailyPayload(duplicateMetrics()),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "rejects too many app metrics",
			body:       dailyPayload(tooManyAppMetrics()),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:          "ignores unused range field",
			body:          payloadWithRange(`"range":{"fromMillis":0,"toMillis":0},`),
			wantStatus:    http.StatusNoContent,
			wantPublished: 1,
		},
		{
			name:          "accepts unknown fields and package labels without extra guarding",
			body:          relaxedPayload("com.example/social"),
			wantStatus:    http.StatusNoContent,
			wantPublished: 1,
			assertEvent: func(t *testing.T, event receiver.UsageEvent) {
				metrics := rowsByName(event.Snapshot.Metrics)
				if metrics[receiver.AppForegroundMetric].LabelPackage != "com.example/social" {
					t.Fatalf("app metric = %#v", metrics[receiver.AppForegroundMetric])
				}
			},
		},
		{
			name:          "returns unavailable when publish fails",
			body:          validPayload("2026-04-25", 120),
			publishErr:    publishErr,
			wantStatus:    http.StatusServiceUnavailable,
			wantPublished: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			publisher := &fakePublisher{err: tt.publishErr}
			app := newTestApp(publisher)

			response := postUsage(t, app, tt.body)
			if response.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d: %s", response.Code, tt.wantStatus, response.Body.String())
			}
			if len(publisher.events) != tt.wantPublished {
				t.Fatalf("published events = %d, want %d", len(publisher.events), tt.wantPublished)
			}
			if tt.assertEvent != nil {
				tt.assertEvent(t, publisher.events[0])
			}
		})
	}
}

func TestIsNewerSnapshot(t *testing.T) {
	tests := []struct {
		name string
		next receiver.Snapshot
		curr receiver.Snapshot
		want bool
	}{
		{
			name: "newer date wins",
			next: receiver.Snapshot{Date: "2026-04-26", GeneratedAtMillis: 1},
			curr: receiver.Snapshot{Date: "2026-04-25", GeneratedAtMillis: 999},
			want: true,
		},
		{
			name: "older date loses",
			next: receiver.Snapshot{Date: "2026-04-24", GeneratedAtMillis: 999},
			curr: receiver.Snapshot{Date: "2026-04-25", GeneratedAtMillis: 1},
		},
		{
			name: "same date newer generated at wins",
			next: receiver.Snapshot{Date: "2026-04-25", GeneratedAtMillis: 2},
			curr: receiver.Snapshot{Date: "2026-04-25", GeneratedAtMillis: 1},
			want: true,
		},
		{
			name: "same date older generated at loses",
			next: receiver.Snapshot{Date: "2026-04-25", GeneratedAtMillis: 1},
			curr: receiver.Snapshot{Date: "2026-04-25", GeneratedAtMillis: 2},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := receiver.IsNewerSnapshot(tt.next, tt.curr); got != tt.want {
				t.Fatalf("IsNewerSnapshot = %v, want %v", got, tt.want)
			}
		})
	}
}

type fakePublisher struct {
	events []receiver.UsageEvent
	err    error
}

func (p *fakePublisher) PublishUsage(_ context.Context, event receiver.UsageEvent) error {
	p.events = append(p.events, event)
	return p.err
}

func postUsage(t *testing.T, app *receiver.App, body string) *httptest.ResponseRecorder {
	t.Helper()

	request := httptest.NewRequest(
		http.MethodPost,
		"/android-usage",
		bytes.NewBufferString(body),
	)
	response := httptest.NewRecorder()
	app.Handler().ServeHTTP(response, request)
	return response
}

func validPayload(date string, value int) string {
	return validPayloadWithGeneratedAt(date, value, 1777132800000)
}

func validPayloadWithGeneratedAt(date string, value int, generatedAtMillis int64) string {
	metrics := fmt.Sprintf(`[
		{"name":"android_usage_daily_screen_time_seconds","value":%d},
		{"name":"android_usage_app_foreground_seconds","value":%d,"labels":{"package":"com.example.social"}}
	]`, value, value)
	return dailyPayloadWithGeneratedAt(date, generatedAtMillis, metrics)
}

func relaxedPayload(packageName string) string {
	return strings.NewReplacer(
		`"metrics":`,
		`"unknown":true,"metrics":`,
		"com.example.social",
		packageName,
	).Replace(validPayload("2026-04-25", 120))
}

func payloadWithRange(rangeField string) string {
	return strings.Replace(
		validPayload("2026-04-25", 120),
		`"range":{"fromMillis":1777046400000,"toMillis":1777132800000},`,
		rangeField,
		1,
	)
}

func dailyPayload(metrics string) string {
	return dailyPayloadWithGeneratedAt("2026-04-25", 1777132800000, metrics)
}

func dailyPayloadWithGeneratedAt(date string, generatedAtMillis int64, metrics string) string {
	return `{
		"type":"android_usage_daily_snapshot",
		"version":1,
		"date":"` + date + `",
		"device":"pixel-main",
		"generatedAtMillis":` + strconv.FormatInt(generatedAtMillis, 10) + `,
		"range":{"fromMillis":1777046400000,"toMillis":1777132800000},
		"metrics":` + metrics + `
	}`
}

func duplicateMetrics() string {
	return `[
		{"name":"android_usage_daily_screen_time_seconds","value":120},
		{"name":"android_usage_daily_screen_time_seconds","value":45}
	]`
}

func tooManyAppMetrics() string {
	var metrics strings.Builder
	metrics.WriteString(`[{"name":"android_usage_daily_screen_time_seconds","value":120}`)
	for i := 0; i < 201; i++ {
		metrics.WriteString(`,{"name":"android_usage_app_foreground_seconds","value":1,"labels":{"package":"com.example.app`)
		metrics.WriteString(strconv.Itoa(i))
		metrics.WriteString(`"}}`)
	}
	metrics.WriteString(`]`)
	return metrics.String()
}

func rowsByName(rows []receiver.MetricRow) map[string]receiver.MetricRow {
	result := make(map[string]receiver.MetricRow, len(rows))
	for _, row := range rows {
		result[row.Name] = row
	}
	return result
}
