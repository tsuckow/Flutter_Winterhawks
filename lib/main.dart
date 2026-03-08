import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

const String _streamUrl = 'https://tsuckow.com/stream.php';

/// Number of latency samples to keep for the rolling window.
const int _defaultSampleCount = 10;

/// Desired rolling-window width in seconds used to compute [_defaultSampleCount].
const double _desiredWindow = 2.0;

void main() {
  runApp(const WinterhawksApp());
}

class WinterhawksApp extends StatelessWidget {
  const WinterhawksApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Winterhawks Live',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const PlayerPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// A single sample recorded for the buffer-time graph.
class _BufferSample {
  const _BufferSample({
    required this.timeToEmpty,
    required this.playbackRate,
    required this.stalled,
  });

  final double timeToEmpty;
  final double playbackRate;
  final bool stalled;
}

// ---------------------------------------------------------------------------
// Player logic
// ---------------------------------------------------------------------------

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // ---- audio ----
  late final AudioPlayer _player;

  // ---- status strings ----
  String _statusText = 'Player is stopped';
  String _bufferText = '';
  String _rateText = '';

  // ---- latency samples ----
  final List<double> _latencies = [0];
  final List<double> _times = [0];
  int _samplesCount = _defaultSampleCount;

  // ---- gain tracking ----
  double? _lastLatencySample;
  double? _lastGainTime;
  final List<double> _gainIntervals = [];
  final List<double> _gainAmounts = [];

  // ---- stall tracking ----
  bool _buffering = false;
  bool _stalledSample = false;

  // ---- buffer graph history ----
  final List<_BufferSample> _tteHistory = [];

  // ---- stream start time (for long-pause reload) ----
  DateTime? _streamStartTime;
  bool _wasPaused = false;

  // ---- subscriptions ----
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _bufferedSub;

  // ---- current playback info ----
  double _currentPlaybackRate = 1.0;
  double _latency = 0;
  double _targetLatency = 1.5;
  double _minLatency = 0;
  double _avgLatency = 0;
  double _timeToEmpty = 0;
  String _rateIndicator = '>';

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _setupSubscriptions();
    _loadStream();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _bufferedSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Stream setup
  // -------------------------------------------------------------------------

  Future<void> _loadStream() async {
    try {
      await _player.setUrl(_streamUrl);
      await _player.play();
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = 'Error: $e');
      }
    }
  }

  void _setupSubscriptions() {
    // Player state changes
    _stateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      switch (state.processingState) {
        case ProcessingState.idle:
          setState(() => _statusText = 'Player is stopped');
        case ProcessingState.loading:
        case ProcessingState.buffering:
          setState(() {
            _statusText = 'Player is buffering';
            _buffering = true;
          });
        case ProcessingState.ready:
          if (state.playing) {
            setState(() {
              _statusText = 'Player is playing';
              if (_streamStartTime == null) {
                _streamStartTime = DateTime.now();
              }
              if (_wasPaused) {
                _wasPaused = false;
                _checkLongPause();
              }
            });
          } else {
            setState(() {
              _statusText = 'Player is paused';
              _wasPaused = true;
            });
          }
        case ProcessingState.completed:
          setState(() => _statusText = 'Player has stopped');
      }
    });

    // Position updates — main latency / rate-control loop
    _positionSub = _player.positionStream.listen(_onPositionUpdate);
  }

  // -------------------------------------------------------------------------
  // Long-pause reload (mirrors the HTML play handler)
  // -------------------------------------------------------------------------

  void _checkLongPause() {
    final start = _streamStartTime;
    if (start == null) return;
    final wallElapsed =
        DateTime.now().difference(start).inMilliseconds / 1000.0;
    final streamElapsed = _player.position.inMilliseconds / 1000.0;
    final behind = wallElapsed - streamElapsed;
    if (behind > 20) {
      _reloadStream();
    }
  }

  Future<void> _reloadStream() async {
    await _player.stop();
    _streamStartTime = DateTime.now();
    _latencies
      ..clear()
      ..add(0);
    _times
      ..clear()
      ..add(0);
    _lastLatencySample = null;
    _lastGainTime = null;
    _gainIntervals.clear();
    _gainAmounts.clear();
    _tteHistory.clear();
    await _loadStream();
  }

  // -------------------------------------------------------------------------
  // Core latency / rate-control handler (mirrors handle() + timeupdate)
  // -------------------------------------------------------------------------

  void _onPositionUpdate(Duration position) {
    if (!mounted) return;
    final currentTime = position.inMilliseconds / 1000.0;
    final bufferedPos = _player.bufferedPosition;
    final bufferedSecs = bufferedPos.inMilliseconds / 1000.0;

    // Only proceed if we have valid buffered data ahead of current position
    if (bufferedSecs <= currentTime) return;

    final latency = bufferedSecs - currentTime;

    // ---- gain tracking ----
    final lastSample = _lastLatencySample;
    if (lastSample != null) {
      final delta = latency - lastSample;
      if (delta > 0.01) {
        final lastGain = _lastGainTime;
        if (lastGain != null) {
          _gainIntervals.add(currentTime - lastGain);
          if (_gainIntervals.length > _samplesCount) {
            _gainIntervals.removeAt(0);
          }
        }
        _gainAmounts.add(delta);
        if (_gainAmounts.length > _samplesCount) {
          _gainAmounts.removeAt(0);
        }
        _lastGainTime = currentTime;
      }
    }
    _lastLatencySample = latency;

    // ---- rolling window ----
    _latencies.add(latency);
    _times.add(currentTime);
    if (_latencies.length > _samplesCount) {
      _latencies.removeAt(0);
      _times.removeAt(0);
    }
    // recalc samplesCount to cover ~2 s window
    if (_times.length >= 2) {
      final window = _times.last - _times.first;
      if (window > 0) {
        _samplesCount = max(
          10,
          (_times.length / window * _desiredWindow).ceil(),
        );
      }
    }

    // ---- stall flag ----
    if (_buffering) {
      _stalledSample = true;
      _buffering = false;
    }

    // ---- compute stats ----
    final minLatency = _latencies.reduce(min);
    final avgLatency = _latencies.reduce((a, b) => a + b) / _latencies.length;
    final seekAvail = bufferedSecs - currentTime;

    // ---- dynamic target latency ----
    double targetLatency;
    if (seekAvail < 1) {
      targetLatency = 0.5;
    } else if (seekAvail < 3) {
      targetLatency = 1.0;
    } else {
      targetLatency = 1.5;
    }

    // ---- rate control ----
    final diff = minLatency - targetLatency;
    String rateIndicator;
    double newRate;

    if (diff > 1.5) {
      rateIndicator = '>>>>>';
      newRate = 1.8;
    } else if (diff > 1.0) {
      rateIndicator = '>>>>';
      newRate = 1.2;
    } else if (diff > 0.3) {
      rateIndicator = '>>>';
      newRate = 1.05;
    } else if (diff > 0.1) {
      rateIndicator = '>>';
      newRate = 1.01;
    } else if (diff > -0.1) {
      rateIndicator = '>';
      newRate = 1.0;
    } else if (diff > -0.4) {
      rateIndicator = '>';
      newRate = 0.95;
    } else if (diff > -0.8) {
      rateIndicator = '!';
      newRate = 0.9;
    } else {
      rateIndicator = '!';
      newRate = 0.8;
    }

    try {
      _player.setSpeed(newRate);
    } catch (_) {
      // Ignore speed-setting failures (e.g. unsupported on this platform/codec).
    }

    final timeToEmpty = seekAvail / newRate;

    // ---- update TTE history ----
    final stalled = _stalledSample;
    _stalledSample = false;

    _tteHistory.add(_BufferSample(
      timeToEmpty: timeToEmpty,
      playbackRate: newRate,
      stalled: stalled,
    ));
    final maxHistory = _samplesCount * 10;
    while (_tteHistory.length > maxHistory) {
      _tteHistory.removeAt(0);
    }

    // ---- gain stats ----
    final gainDelayMin =
        _gainIntervals.isNotEmpty ? _gainIntervals.reduce(min) : 0.0;
    final gainDelayAvg = _gainIntervals.isNotEmpty
        ? _gainIntervals.reduce((a, b) => a + b) / _gainIntervals.length
        : 0.0;
    final gainAmountMin =
        _gainAmounts.isNotEmpty ? _gainAmounts.reduce(min) : 0.0;
    final gainAmountAvg = _gainAmounts.isNotEmpty
        ? _gainAmounts.reduce((a, b) => a + b) / _gainAmounts.length
        : 0.0;

    final bufferText =
        'Buffer: Min ${minLatency.toStringAsFixed(2)}s, '
        'Avg ${avgLatency.toStringAsFixed(2)}s, '
        'Target ${targetLatency.toStringAsFixed(2)}s, '
        'TTE ${timeToEmpty.toStringAsFixed(1)}s, '
        'GainDt ${gainDelayMin.toStringAsFixed(2)}/${gainDelayAvg.toStringAsFixed(2)}s, '
        'GainAmt ${gainAmountMin.toStringAsFixed(2)}/${gainAmountAvg.toStringAsFixed(2)}s'
        ' (${_latencies.length})';
    final rateText =
        '${newRate.toStringAsFixed(2)} $rateIndicator '
        '${seekAvail.toStringAsFixed(3)} $_samplesCount';

    setState(() {
      _currentPlaybackRate = newRate;
      _latency = latency;
      _targetLatency = targetLatency;
      _minLatency = minLatency;
      _avgLatency = avgLatency;
      _timeToEmpty = timeToEmpty;
      _rateIndicator = rateIndicator;
      _bufferText = bufferText;
      _rateText = rateText;
    });
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  Color _rateColor() {
    if (_currentPlaybackRate > 1.15) return Colors.green;
    if (_currentPlaybackRate > 1.04) return Colors.blue;
    if (_currentPlaybackRate >= 0.95) return Colors.grey;
    if (_currentPlaybackRate >= 0.85) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Winterhawks Live'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- playback controls ----
            Row(
              children: [
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final state = snapshot.data;
                    final playing = state?.playing ?? false;
                    final processing =
                        state?.processingState ?? ProcessingState.idle;
                    if (processing == ProcessingState.loading ||
                        processing == ProcessingState.buffering) {
                      return const SizedBox(
                        width: 48,
                        height: 48,
                        child: CircularProgressIndicator(),
                      );
                    }
                    return IconButton(
                      iconSize: 48,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () {
                        if (playing) {
                          _player.pause();
                        } else {
                          _player.play();
                        }
                      },
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusText,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ---- buffer viz bar ----
            Container(
              height: 20,
              width: double.infinity,
              color: Colors.grey[300],
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (_latency * 100).clamp(0, 300) / 300,
                child: Container(
                  color: _rateColor(),
                ),
              ),
            ),

            const SizedBox(height: 4),

            // ---- playback rate indicator ----
            Text(
              _rateText,
              style: TextStyle(
                fontFamily: 'monospace',
                color: _rateColor(),
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 4),

            // ---- buffer status text ----
            Text(
              _bufferText,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),

            const SizedBox(height: 12),

            // ---- buffer time graph ----
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
              ),
              width: double.infinity,
              height: 80,
              child: CustomPaint(
                painter: _BufferGraphPainter(
                  samples: List.unmodifiable(_tteHistory),
                ),
              ),
            ),

            const SizedBox(height: 4),
            _buildLegend(),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    const items = [
      ('Stalled', Colors.red),
      ('Slow (< 0.95×)', Colors.orange),
      ('Normal', Colors.grey),
      ('Fast (< 1.2×)', Colors.blue),
      ('Very fast (≥ 1.2×)', Colors.green),
    ];
    return Wrap(
      spacing: 12,
      children: items.map((item) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 12, height: 12, color: item.$2),
            const SizedBox(width: 4),
            Text(item.$1, style: const TextStyle(fontSize: 10)),
          ],
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Buffer time graph painter
// ---------------------------------------------------------------------------

class _BufferGraphPainter extends CustomPainter {
  const _BufferGraphPainter({required this.samples});

  final List<_BufferSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;

    const marginLeft = 30.0;
    const marginRight = 2.0;
    const marginTop = 2.0;
    const marginBottom = 2.0;

    final plotWidth = size.width - marginLeft - marginRight;
    final plotHeight = size.height - marginTop - marginBottom;

    final maxTTE = samples.map((s) => s.timeToEmpty).reduce(max);
    final scaleY = maxTTE > 0 ? plotHeight / maxTTE : 1.0;

    // Grid / axis
    final axisPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (final v in [0.0, maxTTE / 2, maxTTE]) {
      final y = size.height - marginBottom - v * scaleY;
      canvas.drawLine(
        Offset(marginLeft - 3, y),
        Offset(size.width - marginRight, y),
        axisPaint,
      );
      textPainter.text = TextSpan(
        text: v.toStringAsFixed(1),
        style: const TextStyle(fontSize: 9, color: Colors.black),
      );
      textPainter.layout(maxWidth: marginLeft - 3);
      textPainter.paint(canvas, Offset(0, y - 5));
    }

    // Line segments
    for (int i = 1; i < samples.length; i++) {
      final x0 =
          marginLeft + ((i - 1) / (samples.length - 1)) * plotWidth;
      final y0 =
          size.height - marginBottom - samples[i - 1].timeToEmpty * scaleY;
      final x1 = marginLeft + (i / (samples.length - 1)) * plotWidth;
      final y1 =
          size.height - marginBottom - samples[i].timeToEmpty * scaleY;

      final stalledSeg = samples[i].stalled || samples[i - 1].stalled;
      final rate = samples[i].playbackRate;

      Color color;
      if (stalledSeg) {
        color = Colors.red;
      } else if (rate < 0.95) {
        color = Colors.orange;
      } else if (rate < 1.05) {
        color = Colors.grey;
      } else if (rate < 1.2) {
        color = Colors.blue;
      } else {
        color = Colors.green;
      }

      canvas.drawLine(
        Offset(x0, y0),
        Offset(x1, y1),
        Paint()
          ..color = color
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_BufferGraphPainter old) {
    return old.samples != samples;
  }
}
