import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/clip.dart';
import '../services/analytics.dart';
import '../services/procam_engine.dart';
import '../services/video_exporter.dart';
import '../widgets/grid_overlay.dart';
import '../widgets/teleprompter_overlay.dart';
import 'gallery_screen.dart';

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  final _engine = ProcamEngine();
  final _prompter = TeleprompterController();
  final _elapsed = ValueNotifier<Duration>(Duration.zero);

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  Timer? _timer;
  DateTime? _recStart;

  bool _perms = false;
  bool _ready = false;
  bool _recording = false;
  bool _busy = false;
  bool _torch = false;
  bool _is4k = false;
  bool _grid = true;
  bool _prompterOn = true;
  bool _focusLocked = false;
  bool _showReticle = false;

  String _aspect = '9:16';
  double _zoom = 1.0;
  double _zoomBase = 1.0;
  int _ev = 0;
  int _evMin = 0;
  int _evMax = 0;

  Map<String, String> _dirs = const {};
  int? _micId;
  Clip? _lastClip;
  Offset _reticle = Offset.zero;

  static const _aspects = ['9:16', '16:9', '1:1', '4:5'];
  static const _ratios = <String, double>{
    '9:16': 9 / 16,
    '16:9': 16 / 9,
    '1:1': 1,
    '4:5': 4 / 5,
  };

  @override
  void initState() {
    super.initState();
    _eventSub = ProcamEngine.events.listen(_onEngineEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsed.dispose();
    _eventSub?.cancel();
    _engine.pause();
    _prompter.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final ok = await _engine.ensurePermissions();
    if (!mounted) return;
    setState(() => _perms = ok);
    if (!ok) return;

    await _engine.start();
    // CameraX now binds on a coalesced background tick (it used to block the
    // UI thread). Wait for the real bind before reading exposure/quality.
    await _waitReady();
    final dirs = await _engine.mediaDirs();
    final range = await _engine.exposureRange();
    final mics = await _engine.audioInputs();
    final clips = await ClipRepository.list();
    final k4 = await _engine.is4k();
    if (!mounted) return;
    setState(() {
      _dirs = dirs;
      _evMin = range['min'] ?? 0;
      _evMax = range['max'] ?? 0;
      _micId = mics.isNotEmpty ? mics.first.id : null;
      _lastClip = clips.isNotEmpty ? clips.first : null;
      _is4k = k4;
      _prompterOn = true;
    });
  }

  Future<void> _waitReady() async {
    for (var i = 0; i < 40 && !_ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _onEngineEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'ready':
        if (mounted) setState(() => _ready = true);
        break;
      case 'recording_finalized':
        // CameraX can finalize on its own (storage full, lifecycle, error).
        // Keep the UI honest even when no stop() call is pending.
        if (_recording) {
          _stopTimer();
          _prompter.pause();
          if (mounted) {
            setState(() => _recording = false);
          }
        }
        break;
      case 'error':
        _snack(e['message']?.toString() ?? 'Camera error');
        break;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _startTimer() {
    _recStart = DateTime.now();
    _elapsed.value = Duration.zero;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final start = _recStart;
      if (start == null) return;
      _elapsed.value = DateTime.now().difference(start);
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _recStart = null;
  }

  Future<void> _toggleRecord() async {
    if (_busy) return;
    if (!_perms) {
      await _boot();
      return;
    }
    setState(() => _busy = true);
    try {
      if (_recording) {
        final took = _recStart == null
            ? 0
            : DateTime.now().difference(_recStart!).inSeconds;
        final result = await _engine.stopRecording();
        _stopTimer();
        _prompter.pause();
        Analytics.instance.log('record_stop', {
          'duration_s': took,
          'finalized': result == null ? 0 : 1,
        });
        if (!mounted) return;
        setState(() {
          _recording = false;
          _busy = false;
        });
        if (result == null) {
          _snack('Recording failed to finalize');
        } else {
          _openExport(result);
        }
      } else {
        final ok = await _engine.startRecording();
        if (!mounted) return;
        if (!ok) {
          _snack('Could not start recording');
          setState(() => _busy = false);
          return;
        }
        _startTimer();
        _prompter.play(); // auto-scroll starts with the take
        Analytics.instance.log('record_start', {
          'aspect': _aspect,
          'quality': _is4k ? '4k' : '1080p',
          'torch': _torch ? 1 : 0,
          'zoom': _zoom,
          'mic': _micId == null ? 'none' : 'selected',
          'teleprompter': _prompterOn ? 1 : 0,
        });
        setState(() {
          _recording = true;
          _busy = false;
          _prompterOn = true;
        });
      }
    } catch (e) {
      _snack(e.toString());
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openExport(RecordingResult result) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ExportSheet(result: result, dirs: _dirs),
    );
    final clips = await ClipRepository.list();
    if (!mounted) return;
    setState(() => _lastClip = clips.isNotEmpty ? clips.first : _lastClip);
  }

  Future<void> _toggleAspect(String a) async {
    if (_recording || a == _aspect) return;
    final ok = await _engine.setAspect(a);
    if (!mounted) return;
    if (ok) {
      setState(() => _aspect = a);
      Analytics.instance.log('aspect_change', {'aspect': a});
    }
  }

  Future<void> _toggle4k() async {
    final next = !_is4k;
    final ok = await _engine.setQuality4k(next);
    if (!mounted) return;
    if (!ok) {
      _snack(_recording ? 'Stop recording to change quality' : '4K not supported');
      return;
    }
    // CameraX rebinds on its own tick now; poll briefly for the real size.
    var real = _is4k;
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      real = await _engine.is4k();
      if (real == next) break;
    }
    if (!mounted) return;
    setState(() => _is4k = real);
    Analytics.instance.log('quality_change', {
      'quality': real ? '4k' : '1080p',
      'requested_4k': next ? 1 : 0,
    });
    if (next && !real) _snack('4K unavailable on this camera — using 1080p');
  }

  Future<void> _toggleTorch() async {
    final next = !_torch;
    await _engine.setTorch(next);
    if (mounted) setState(() => _torch = next);
  }

  Future<void> _switchCamera() async {
    if (_recording) return _snack('Stop recording to switch camera');
    final ok = await _engine.switchCamera();
    if (!mounted) return;
    if (ok) setState(() => _torch = false);
  }

  Future<void> _openMicSheet() async {
    await _engine.ensureBluetooth(); // Android 12+: required for BT routing
    final mics = await _engine.audioInputs();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Microphone source',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (mics.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No mic found',
                    style: TextStyle(color: kTextDim, fontSize: 13)),
              ),
            for (final m in mics)
              ListTile(
                dense: true,
                leading: Icon(
                  m.bluetooth
                      ? Icons.bluetooth_audio_rounded
                      : m.wired
                          ? Icons.cable_rounded
                          : Icons.mic_rounded,
                  color: m.id == _micId ? kLime : Colors.white70,
                ),
                title: Text(m.name, style: const TextStyle(fontSize: 13)),
                trailing: m.id == _micId
                    ? const Icon(Icons.check_rounded, color: kLime, size: 18)
                    : null,
                onTap: () async {
                  await _engine.selectAudioInput(m.id);
                  Analytics.instance.log('mic_select', {
                    'type': m.bluetooth
                        ? 'bluetooth'
                        : m.wired
                            ? 'wired'
                            : 'builtin',
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) setState(() => _micId = m.id);
                },
              ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Text(
                'Bluetooth/wired mics are routed per-recording. FFT denoise '
                '(afftdn) is applied on export, so background hiss stays gone.',
                style: TextStyle(color: kTextDim, fontSize: 11, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openExposure() async {
    var value = _ev;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Exposure  ${value > 0 ? '+' : ''}${(value / 2).toStringAsFixed(1)} EV',
                style: const TextStyle(fontSize: 14),
              ),
              Slider(
                min: _evMin.toDouble(),
                max: _evMax == _evMin ? _evMin + 1.0 : _evMax.toDouble(),
                divisions: (_evMax - _evMin).clamp(1, 20).toInt(),
                value: value.toDouble().clamp(_evMin.toDouble(), _evMax.toDouble()).toDouble(),
                onChanged: (v) {
                  setSheet(() => value = v.round());
                  _engine.setExposure(value);
                  if (mounted) setState(() => _ev = value);
                },
              ),
              const Text(
                'Lower EV for highlights, raise it for dark rooms.',
                style: TextStyle(color: kTextDim, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _focus(Offset local, Size size, {bool lock = false}) {
    final x = (local.dx / size.width).clamp(0.0, 1.0);
    final y = (local.dy / size.height).clamp(0.0, 1.0);
    _engine.focusAt(x, y, lock: lock);
    setState(() {
      _reticle = local;
      _showReticle = true;
      _focusLocked = lock;
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showReticle = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildPreview(),
          if (_grid) const IgnorePointer(child: GridOverlay()),
          if (_showReticle)
            Positioned(
              left: _reticle.dx - 24,
              top: _reticle.dy - 24,
              child: IgnorePointer(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: _focusLocked ? kLime : Colors.white, width: 1.5),
                  ),
                  child: Icon(
                    _focusLocked ? Icons.lock_rounded : Icons.filter_center_focus,
                    size: 16,
                    color: _focusLocked ? kLime : Colors.white,
                  ),
                ),
              ),
            ),
          if (!_perms) _permissionGate(),
          if (_perms) ...[
            _topBar(),
            _bottomBar(),
          ],
          if (_prompterOn && _perms)
            TeleprompterOverlay(
              controller: _prompter,
              onClose: () => setState(() => _prompterOn = false),
            ),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2, color: kAccent),
            ),
          if (_perms && !_ready)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('Starting camera…',
                    style: TextStyle(fontSize: 11, color: Colors.white70)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final ratio = _ratios[_aspect] ?? 9 / 16;
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: LayoutBuilder(
          builder: (ctx, c) {
            final size = Size(c.maxWidth, c.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _focus(d.localPosition, size),
              onLongPressStart: (d) => _focus(d.localPosition, size, lock: true),
              onScaleStart: (_) => _zoomBase = _zoom,
              onScaleUpdate: (d) {
                if (d.pointerCount < 2) return;
                final z = (_zoomBase * d.scale).clamp(1.0, 8.0).toDouble();
                _engine.setZoom(z);
                setState(() => _zoom = z);
              },
              child: ClipRect(
                child: AndroidView(
                  viewType: 'procam/camera_preview',
                  onPlatformViewCreated: (_) {
                    if (_perms) _engine.start();
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _permissionGate() {
    return ColoredBox(
      color: kBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_rounded, size: 44, color: kTextDim),
              const SizedBox(height: 16),
              const Text(
                'Camera & mic permission needed',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your footage stays on this device. Only anonymous usage\n'
                'stats are sent to Firebase.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextDim, fontSize: 12),
              ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.white),
                onPressed: _boot,
                child: const Text('Grant permissions',
                    style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 8,
      left: 12,
      right: 12,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            if (_recording)
              ValueListenableBuilder<Duration>(
                valueListenable: _elapsed,
                builder: (_, d, __) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                            color: kAccent, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${d.inMinutes.toString().padLeft(2, '0')}:'
                        '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              )
            else
              const Text('PROCAM',
                  style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700)),
            const Spacer(),
            _topBtn(
              _torch ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              active: _torch,
              onTap: _toggleTorch,
            ),
            _topBtn(Icons.exposure_rounded, onTap: _openExposure),
            _topBtn(
              null,
              text: _is4k ? '4K' : 'HD',
              active: _is4k,
              onTap: _toggle4k,
            ),
            _topBtn(Icons.cameraswitch_rounded, onTap: _switchCamera),
          ],
        ),
      ),
    );
  }

  Widget _topBtn(IconData? icon,
      {String? text, bool active = false, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          width: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
                color: active ? kLime : Colors.white.withOpacity(0.12)),
          ),
          child: text != null
              ? Text(text,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: active ? kLime : Colors.white))
              : Icon(icon ?? Icons.circle_outlined,
                  size: 17, color: active ? kLime : Colors.white),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(16, 28, 16, 14 + MediaQuery.paddingOf(context).bottom),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withOpacity(0.9)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final a in _aspects) _aspectChip(a),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _smallAction(
                  icon: _prompterOn
                      ? Icons.subtitles_rounded
                      : Icons.subtitles_off_rounded,
                  label: 'Teleprompter',
                  active: _prompterOn,
                  onTap: () => setState(() => _prompterOn = !_prompterOn),
                ),
                const Spacer(),
                _zoomChips(),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _galleryButton(),
                const Spacer(),
                _recordButton(),
                const Spacer(),
                _micButton(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _aspectChip(String a) {
    final active = a == _aspect;
    return GestureDetector(
      onTap: () => _toggleAspect(a),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          a,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _zoomChips() {
    return Row(
      children: [
        for (final z in const [1.0, 2.0, 4.0])
          GestureDetector(
            onTap: () {
              _engine.setZoom(z);
              setState(() => _zoom = z);
            },
            child: Container(
              margin: const EdgeInsets.only(left: 6),
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (_zoom - z).abs() < 0.05
                    ? Colors.white
                    : Colors.black.withOpacity(0.45),
                border: Border.all(color: Colors.white.withOpacity(0.15)),
              ),
              child: Text(
                '${z.toInt()}x',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: (_zoom - z).abs() < 0.05 ? Colors.black : Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _smallAction({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? Colors.white.withOpacity(0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? kLime : Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: active ? Colors.white : Colors.white70)),
          ],
        ),
      ),
    );
  }

  Widget _galleryButton() {
    return GestureDetector(
      onTap: () async {
        if (_recording) return;
        await _engine.pause(); // release camera while browsing the gallery
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const GalleryScreen()),
        );
        await _engine.start();
        final clips = await ClipRepository.list();
        if (mounted) {
          setState(() => _lastClip = clips.isNotEmpty ? clips.first : null);
        }
      },
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.35)),
          color: kSurface,
        ),
        clipBehavior: ui.Clip.antiAlias,
        child: _lastClip?.thumbPath != null
            ? Image.file(File(_lastClip!.thumbPath!), fit: BoxFit.cover)
            : const Icon(Icons.photo_library_outlined,
                size: 18, color: Colors.white70),
      ),
    );
  }

  Widget _recordButton() {
    return GestureDetector(
      onTap: _toggleRecord,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: _recording ? kAccent : Colors.white, width: 4),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: _recording ? 28 : 58,
            height: _recording ? 28 : 58,
            decoration: BoxDecoration(
              color: kAccent,
              borderRadius: BorderRadius.circular(_recording ? 7 : 30),
            ),
          ),
        ),
      ),
    );
  }

  Widget _micButton() {
    return GestureDetector(
      onTap: _openMicSheet,
      child: Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.45),
          border: Border.all(color: Colors.white.withOpacity(0.35)),
        ),
        child: Icon(
          _micId == null ? Icons.mic_off_rounded : Icons.mic_rounded,
          size: 19,
          color: _micId == null ? kTextDim : Colors.white,
        ),
      ),
    );
  }
}

/// Bottom sheet shown right after a take: pick FPS → export → share.
class _ExportSheet extends StatefulWidget {
  final RecordingResult result;
  final Map<String, String> dirs;

  const _ExportSheet({required this.result, required this.dirs});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  int _fps = 30;
  bool _exporting = false;
  bool _done = false;
  int _progress = 0;
  double _sizeMb = 0;
  String? _output;
  String? _error;
  String? _thumb;

  Future<void> _export() async {
    final exportDir = widget.dirs['exports'];
    if (exportDir == null) {
      setState(() => _error = 'Storage unavailable');
      return;
    }
    setState(() {
      _exporting = true;
      _error = null;
      _progress = 0;
    });

    final out = '$exportDir/REEL_${DateTime.now().millisecondsSinceEpoch}.mp4';
    try {
      final audioOk = widget.result.audioPath != null &&
          File(widget.result.audioPath!).existsSync() &&
          File(widget.result.audioPath!).lengthSync() > 1024;
      final started = DateTime.now();
      Analytics.instance.log('export_start', {
        'fps': _fps,
        'has_audio': audioOk ? 1 : 0,
      });
      await VideoExporter.export(
        videoPath: widget.result.videoPath,
        audioPath: audioOk ? widget.result.audioPath : null,
        outputPath: out,
        fps: _fps,
        durationMs: widget.result.durationMs,
        audioOffsetMs: widget.result.audioOffsetMs,
        onProgress: (p) {
          if (mounted && p != _progress) setState(() => _progress = p);
        },
      );
      final thumb = await ClipRepository.thumbnail(out);
      final mb = File(out).lengthSync() / (1024 * 1024);
      Analytics.instance.log('export_done', {
        'fps': _fps,
        'seconds': DateTime.now().difference(started).inSeconds,
        'mb': (mb * 10).round() / 10,
        'has_audio': audioOk ? 1 : 0,
      });
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _done = true;
        _output = out;
        _thumb = thumb;
        _sizeMb = mb;
      });
    } catch (e) {
      Analytics.instance.log('export_failed', {'fps': _fps, 'error': '$e'});
      // Never leave a half-written MP4 that the gallery would try to open.
      try {
        final partial = File(out);
        if (partial.existsSync()) partial.deleteSync();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = e.toString().replaceFirst('ExportException: ', '');
      });
    }
  }

  Future<void> _share(ShareTarget t) async {
    final path = _output;
    if (path == null) return;
    final ok = await ClipRepository.share(path, t);
    Analytics.instance.log('share', {
      'target': t.name,
      'source': 'export',
      'ok': ok ? 1 : 0,
    });
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open a share sheet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sizeMb = _sizeMb;

    return PopScope(
      canPop: !_exporting,
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  const Text('Optimize for Reels',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (!_exporting)
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                '1080×1920 · H.264 High · Rec.709 · 18 Mbps · AAC 192k',
                style: TextStyle(color: kTextDim, fontSize: 11),
              ),
            ),
            if (!_done) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Text('Frame rate',
                        style: TextStyle(color: kTextDim, fontSize: 12)),
                    const Spacer(),
                    for (final f in const [30, 60])
                      GestureDetector(
                        onTap: _exporting ? null : () => setState(() => _fps = f),
                        child: Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: _fps == f
                                ? Colors.white
                                : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text('$f FPS',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _fps == f
                                      ? Colors.black
                                      : Colors.white70)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_exporting)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progress / 100,
                          minHeight: 4,
                          backgroundColor: kSurfaceHi,
                          color: kLime,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Encoding on-device… $_progress%  (keep screen on)',
                        style: const TextStyle(color: kTextDim, fontSize: 11),
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _export,
                    child: Text('Export $_fps FPS',
                        style: const TextStyle(
                            color: Colors.black, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(_error!,
                      style: const TextStyle(color: kAccent, fontSize: 12)),
                ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Text(
                  'Export is CPU-bound. On 3GB phones prefer 30 FPS; a 60s clip '
                  'takes roughly 40–80s. Your video never leaves the device.',
                  style: TextStyle(color: kTextDim, fontSize: 10, height: 1.4),
                ),
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 64,
                        height: 96,
                        child: _thumb != null
                            ? Image.file(File(_thumb!), fit: BoxFit.cover)
                            : const ColoredBox(
                                color: kSurfaceHi,
                                child: Icon(Icons.movie_rounded,
                                    color: kTextDim, size: 20),
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.check_circle_rounded,
                                  color: kLime, size: 16),
                              SizedBox(width: 6),
                              Text('Reel ready',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '1080×1920 · $_fps FPS · ${sizeMb.toStringAsFixed(1)} MB',
                            style: const TextStyle(
                                color: kTextDim, fontSize: 11),
                          ),
                          const SizedBox(height: 2),
                          const Text('Upload-ready, no re-compression needed.',
                              style:
                                  TextStyle(color: kTextDim, fontSize: 10)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: _shareBtn('Instagram', _ShareStyle.ig,
                          () => _share(ShareTarget.instagram)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _shareBtn('Facebook', _ShareStyle.fb,
                          () => _share(ShareTarget.facebook)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _shareBtn('YouTube', _ShareStyle.yt,
                          () => _share(ShareTarget.youtube)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    side: BorderSide(color: Colors.white.withOpacity(0.18)),
                  ),
                  onPressed: () =>
                      ClipRepository.open(_output!).then((_) {}),
                  child: const Text('Preview clip'),
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
          ),
        ),
      ),
    );
  }

  Widget _shareBtn(String label, _ShareStyle style, VoidCallback onTap) {
    final color = switch (style) {
      _ShareStyle.ig => const Color(0xFFE1306C),
      _ShareStyle.fb => const Color(0xFF1877F2),
      _ShareStyle.yt => const Color(0xFFFF0000),
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ),
    );
  }
}

enum _ShareStyle { ig, fb, yt }
