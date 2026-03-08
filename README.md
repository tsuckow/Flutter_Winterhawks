# Flutter Winterhawks

A low-latency Flutter audio player for the Winterhawks live stream.

## Features

- Connects to the Winterhawks live audio stream (`stream.php`)
- Continuously monitors the buffer (buffered-end − current-time)
- Dynamically adjusts playback speed (0.80× – 1.80×) to minimise latency while avoiding stalls
- Rolling min/avg latency window used to select a dynamic target latency based on available buffer
- Visual buffer bar and colour-coded playback-rate indicator
- Buffer time-to-empty graph with colour coding for stall / slow / normal / fast segments
- Detects extended pauses (> 20 s behind live) and automatically reloads the stream

## Algorithm

The rate-control algorithm mirrors the HTML reference implementation:

1. Every position update, compute `latency = bufferedEnd − currentTime`.
2. Maintain a rolling window of `latency` and `time` samples (≈ 2 s of history).
3. Compute `minLatency` over the window.
4. Choose a dynamic `targetLatency` based on available seek buffer (0.5 / 1.0 / 1.5 s).
5. `diff = minLatency − targetLatency` drives the rate table:

   | diff        | rate  |
   |-------------|-------|
   | > 1.5 s     | 1.80× |
   | > 1.0 s     | 1.20× |
   | > 0.3 s     | 1.05× |
   | > 0.1 s     | 1.01× |
   | ±0.1 s      | 1.00× |
   | > −0.4 s    | 0.95× |
   | > −0.8 s    | 0.90× |
   | ≤ −0.8 s    | 0.80× |

## Getting Started

```bash
flutter pub get
flutter run
```

Requires Flutter ≥ 3.0.