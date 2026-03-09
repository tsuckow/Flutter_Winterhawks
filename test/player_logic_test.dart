import 'dart:math';
import 'package:flutter_test/flutter_test.dart';

// Pure-logic tests for the latency / rate-control algorithm used in main.dart.
// These tests do NOT require a running audio player or network access.

/// Mirrors the rate-selection logic from _PlayerPageState._onPositionUpdate.
({double rate, String indicator}) selectRate(double diff) {
  if (diff > 1.5) return (rate: 1.8, indicator: '>>>>>');
  if (diff > 1.0) return (rate: 1.2, indicator: '>>>>');
  if (diff > 0.3) return (rate: 1.05, indicator: '>>>');
  if (diff > 0.1) return (rate: 1.01, indicator: '>>');
  if (diff > -0.1) return (rate: 1.0, indicator: '>');
  if (diff > -0.4) return (rate: 0.95, indicator: '>');
  if (diff > -0.8) return (rate: 0.9, indicator: '!');
  return (rate: 0.8, indicator: '!');
}

/// Mirrors the dynamic targetLatency selection from _onPositionUpdate.
double targetLatency(double seekAvail) {
  if (seekAvail < 1) return 0.5;
  if (seekAvail < 3) return 1.0;
  return 1.5;
}

void main() {
  group('Rate selection', () {
    test('returns 1.8 when diff > 1.5 (way ahead of target)', () {
      final result = selectRate(2.0);
      expect(result.rate, equals(1.8));
      expect(result.indicator, equals('>>>>>'));
    });

    test('returns 1.2 when diff is between 1.0 and 1.5', () {
      final result = selectRate(1.2);
      expect(result.rate, equals(1.2));
    });

    test('returns 1.05 when diff is between 0.3 and 1.0', () {
      final result = selectRate(0.5);
      expect(result.rate, equals(1.05));
    });

    test('returns 1.01 when diff is between 0.1 and 0.3', () {
      final result = selectRate(0.2);
      expect(result.rate, equals(1.01));
    });

    test('returns 1.0 when diff is near zero (within ±0.1)', () {
      expect(selectRate(0.0).rate, equals(1.0));
      expect(selectRate(0.05).rate, equals(1.0));
      expect(selectRate(-0.05).rate, equals(1.0));
    });

    test('returns 0.95 when diff is between -0.4 and -0.1', () {
      expect(selectRate(-0.2).rate, equals(0.95));
    });

    test('returns 0.9 when diff is between -0.8 and -0.4', () {
      expect(selectRate(-0.6).rate, equals(0.9));
    });

    test('returns 0.8 when diff <= -0.8 (far behind target)', () {
      expect(selectRate(-1.0).rate, equals(0.8));
    });
  });

  group('Target latency selection', () {
    test('returns 0.5 when seekAvail < 1 s', () {
      expect(targetLatency(0.5), equals(0.5));
    });

    test('returns 1.0 when seekAvail is between 1 and 3 s', () {
      expect(targetLatency(2.0), equals(1.0));
    });

    test('returns 1.5 when seekAvail >= 3 s', () {
      expect(targetLatency(5.0), equals(1.5));
    });
  });

  group('Rolling latency window', () {
    test('keeps at most samplesCount entries', () {
      const maxSamples = 5;
      final latencies = <double>[];
      final times = <double>[];

      for (int i = 0; i < 10; i++) {
        latencies.add(i.toDouble());
        times.add(i.toDouble());
        while (latencies.length > maxSamples) {
          latencies.removeAt(0);
          times.removeAt(0);
        }
      }

      expect(latencies.length, equals(maxSamples));
      expect(times.length, equals(maxSamples));
    });

    test('min latency is correct after population', () {
      final latencies = [1.2, 0.8, 1.5, 0.6, 1.1];
      expect(latencies.reduce(min), closeTo(0.6, 0.001));
    });

    test('avg latency is correct after population', () {
      final latencies = [1.0, 2.0, 3.0];
      final avg = latencies.reduce((a, b) => a + b) / latencies.length;
      expect(avg, closeTo(2.0, 0.001));
    });
  });

  group('Time-to-empty calculation', () {
    test('TTE equals seekAvail / playbackRate', () {
      const seekAvail = 3.0;
      const rate = 1.5;
      final tte = seekAvail / rate;
      expect(tte, closeTo(2.0, 0.001));
    });
  });
}
