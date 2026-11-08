import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/theme.dart';

/// Floating, draggable, semi-transparent teleprompter.
/// Auto-scroll uses a Ticker (vsync-locked) and `jumpTo`, so it never triggers
/// a widget rebuild per frame — critical on 3GB devices.
class TeleprompterController extends ChangeNotifier {
  String text = 'Namaste! Aaj hum banayenge ek high-quality Reel.\n\n'
      'Tip: 9:16 framing rakhein, aur natural light mein shoot karein.\n\n'
      'Tap the settings icon to change size, opacity and scroll speed.';
  double fontSize = 28;
  double opacity = 0.78;
  double speed = 26; // logical pixels per second
  bool playing = false;

  void setText(String v) {
    text = v;
    notifyListeners();
  }

  void setFontSize(double v) {
    fontSize = v.clamp(16.0, 54.0).toDouble();
    notifyListeners();
  }

  void setOpacity(double v) {
    opacity = v.clamp(0.2, 0.95).toDouble();
    notifyListeners();
  }

  void setSpeed(double v) {
    // 180 px/s covers fast talkers and long scripts without re-editing.
    speed = v.clamp(6.0, 180.0).toDouble();
    notifyListeners();
  }

  void togglePlay() {
    playing = !playing;
    notifyListeners();
  }

  void play() {
    if (!playing) togglePlay();
  }

  void pause() {
    if (playing) togglePlay();
  }
}

class TeleprompterOverlay extends StatefulWidget {
  final TeleprompterController controller;
  final VoidCallback onClose;

  const TeleprompterOverlay({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  State<TeleprompterOverlay> createState() => _TeleprompterOverlayState();
}

class _TeleprompterOverlayState extends State<TeleprompterOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ScrollController _scroll = ScrollController();
  Duration _last = Duration.zero;

  double _left = 16;
  double _top = 120;
  double _width = 320;
  bool _showSettings = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.controller.addListener(_syncTicker);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTicker());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    _width = (size.width - 32).clamp(220.0, 460.0).toDouble();
    _left = _left.clamp(8.0, size.width - _width - 8).toDouble();
    _top = _top.clamp(80.0, size.height - 220).toDouble();
  }

  void _syncTicker() {
    final c = widget.controller;
    if (c.playing && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!c.playing && _ticker.isActive) {
      _ticker.stop();
    }
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    if (!widget.controller.playing) return;
    final dt = _last == Duration.zero
        ? 0.016
        : (elapsed - _last).inMicroseconds / 1000000.0;
    _last = elapsed;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    var next = _scroll.offset + widget.controller.speed * dt;
    if (next >= pos.maxScrollExtent) {
      // End of a long script: hold the last line instead of snapping back.
      _scroll.jumpTo(pos.maxScrollExtent);
      widget.controller.pause();
      return;
    }
    _scroll.jumpTo(next);
  }

  void _restart() {
    _last = Duration.zero;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncTicker);
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final mq = MediaQuery.sizeOf(context);

    return Positioned(
      left: _left,
      top: _top,
      width: _width,
      child: GestureDetector(
        onPanStart: (_) => setState(() => _dragging = true),
        onPanUpdate: (d) {
          setState(() {
            _left = (_left + d.delta.dx)
                .clamp(8.0, mq.width - _width - 8)
                .toDouble();
            _top = (_top + d.delta.dy)
                .clamp(64.0, mq.height - 160)
                .toDouble();
          });
        },
        onPanEnd: (_) => setState(() => _dragging = false),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _dragging ? 0.95 : 1,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.30 * c.opacity),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _toolbar(c),
                if (_showSettings) _settings(c),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: mq.height * 0.34),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                    child: SingleChildScrollView(
                      controller: _scroll,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Text(
                        c.text,
                        style: TextStyle(
                          color: Colors.white.withOpacity(c.opacity),
                          fontSize: c.fontSize,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(color: Colors.black87, blurRadius: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(TeleprompterController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
      child: Row(
        children: [
          _icon(
            c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            c.playing ? kLime : Colors.white,
            c.togglePlay,
            tooltip: c.playing ? 'Pause scroll' : 'Auto-scroll',
          ),
          const Icon(Icons.drag_indicator_rounded,
              size: 16, color: Colors.white38),
          const Spacer(),
          _icon(Icons.restart_alt_rounded, Colors.white70, _restart,
              tooltip: 'Restart script'),
          _icon(Icons.edit_note_rounded, Colors.white70, _editText),
          _icon(Icons.tune_rounded, Colors.white70,
              () => setState(() => _showSettings = !_showSettings)),
          _icon(Icons.close_rounded, Colors.white70, widget.onClose),
        ],
      ),
    );
  }

  Future<void> _editText() async {
    final c = widget.controller;
    final next = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ScriptEditorPage(initial: c.text),
      ),
    );
    if (next != null) {
      c.setText(next);
      _restart();
    }
  }

  Widget _settings(TeleprompterController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sliderRow('Size', c.fontSize, 16, 54, c.setFontSize),
          _sliderRow('Opacity', c.opacity * 100, 20, 95,
              (v) => c.setOpacity(v / 100)),
          _sliderRow('Speed', c.speed, 6, 180, c.setSpeed),
        ],
      ),
    );
  }

  Widget _sliderRow(
      String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ),
        Expanded(
          child: SizedBox(
            height: 24,
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 26,
          child: Text(value.round().toString(),
              style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ),
      ],
    );
  }

  Widget _icon(IconData icon, Color color, VoidCallback onTap,
      {String? tooltip}) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18, color: color),
    );
  }
}

/// Full-screen editor so multi-page scripts stay comfortable to paste/edit.
class _ScriptEditorPage extends StatefulWidget {
  final String initial;

  const _ScriptEditorPage({required this.initial});

  @override
  State<_ScriptEditorPage> createState() => _ScriptEditorPageState();
}

class _ScriptEditorPageState extends State<_ScriptEditorPage> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  String _stats = '';

  @override
  void initState() {
    super.initState();
    _stats = _statsFor(_ctrl.text);
    _ctrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final next = _statsFor(_ctrl.text);
    if (next != _stats && mounted) setState(() => _stats = next);
  }

  String _statsFor(String raw) {
    final text = raw.trim();
    final words = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
    final mins = words / 150;
    final read = words == 0
        ? '0 min'
        : mins < 1
            ? '<1 min'
            : '${mins.round()} min';
    return '$words words · ~$read read · long scripts supported';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: const Text('Script', style: TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: kTextDim)),
          ),
          TextButton(
            onPressed: () {
              // Same cap as the web app: 200k characters is many hours of read.
              final text = _ctrl.text.length > 200000
                  ? _ctrl.text.substring(0, 200000)
                  : _ctrl.text;
              Navigator.pop(context, text);
            },
            child: const Text(
              'Save',
              style: TextStyle(color: kLime, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontSize: 14, height: 1.45),
                  decoration: const InputDecoration(
                    hintText: 'Paste your script here…',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _stats,
                  style: const TextStyle(color: kTextDim, fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
