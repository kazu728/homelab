package receiver

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"
)

const (
	DailyScreenMetric   = "android_usage_daily_screen_time_seconds"
	AppForegroundMetric = "android_usage_app_foreground_seconds"
	LastReceivedMetric  = "android_usage_last_received_unixtime"
	SnapshotDateMetric  = "android_usage_snapshot_date_unixtime"
)

type UsageEvent struct {
	Snapshot       Snapshot `json:"snapshot"`
	ReceivedAtUnix int64    `json:"receivedAtUnix"`
}

type Snapshot struct {
	Device            string      `json:"device"`
	Date              string      `json:"date"`
	GeneratedAtMillis int64       `json:"generatedAtMillis"`
	Metrics           []MetricRow `json:"metrics"`
}

type MetricRow struct {
	Device       string  `json:"device"`
	Date         string  `json:"date"`
	Name         string  `json:"name"`
	LabelPackage string  `json:"labelPackage,omitempty"`
	Value        float64 `json:"value"`
}

// MustDateUnix は s.Date を Unix 秒に変換する。
// Date のフォーマットは validateDailySnapshot で保証されているため、
// パースに失敗した場合は呼び出し側のバグなので panic する。
func (s Snapshot) MustDateUnix() int64 {
	date, err := time.Parse("2006-01-02", s.Date)
	if err != nil {
		panic(fmt.Sprintf("snapshot date %q is invalid (validation gap): %v", s.Date, err))
	}
	return date.Unix()
}

func (s Snapshot) MessageID() string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s\x00%s\x00%d", s.Device, s.Date, s.GeneratedAtMillis)))
	return hex.EncodeToString(sum[:])
}

func IsNewerSnapshot(next, current Snapshot) bool {
	if next.Date != current.Date {
		return next.Date > current.Date
	}
	return next.GeneratedAtMillis > current.GeneratedAtMillis
}
