import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/clip.dart';
import '../services/analytics.dart';
import '../services/procam_engine.dart';

/// Post-recording review: thumbnails, size/date, 1-tap share, delete.
/// Thumbnails are generated lazily by the native layer (never blocks the UI).
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<Clip> _clips = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final clips = await ClipRepository.list();
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _loading = false;
    });
  }

  int get _totalBytes => _clips.fold(0, (s, c) => s + c.sizeBytes);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: const Text('REELS',
            style: TextStyle(
                fontSize: 13,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 19),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: Colors.black,
        backgroundColor: Colors.white,
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : _clips.isEmpty
                ? _empty()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Text(
                          '${_clips.length} clips · ${fmtSize(_totalBytes)} · '
                          'stored on this device',
                          style:
                              const TextStyle(color: kTextDim, fontSize: 11),
                        ),
                      ),
                      Expanded(
                        child: GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: _clips.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 0.70,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemBuilder: (ctx, i) => _ClipTile(
                            clip: _clips[i],
                            onTap: () => _actions(_clips[i]),
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _empty() {
    return ListView(
      children: const [
        SizedBox(height: 140),
        Icon(Icons.video_library_outlined, size: 40, color: kTextDim),
        SizedBox(height: 12),
        Center(
          child: Text('No recordings yet',
              style: TextStyle(color: kTextDim, fontSize: 13)),
        ),
        SizedBox(height: 6),
        Center(
          child: Text('Record a take, then export it for Reels.',
              style: TextStyle(color: kTextDim, fontSize: 11)),
        ),
      ],
    );
  }

  Future<void> _actions(Clip clip) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: const Text('Play', style: TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.pop(ctx);
                ClipRepository.open(clip.path);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.camera_alt_outlined,
                  color: Color(0xFFE1306C)),
              title: const Text('Share to Instagram',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('opens Reels composer',
                  style: TextStyle(fontSize: 10, color: kTextDim)),
              onTap: () => _share(ctx, clip, ShareTarget.instagram),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.facebook_rounded,
                  color: Color(0xFF1877F2)),
              title: const Text('Share to Facebook',
                  style: TextStyle(fontSize: 13)),
              onTap: () => _share(ctx, clip, ShareTarget.facebook),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.smart_display_rounded,
                  color: Color(0xFFFF0000)),
              title: const Text('Share to YouTube',
                  style: TextStyle(fontSize: 13)),
              onTap: () => _share(ctx, clip, ShareTarget.youtube),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('More apps…', style: TextStyle(fontSize: 13)),
              onTap: () => _share(ctx, clip, ShareTarget.generic),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline_rounded,
                  color: kAccent),
              title: const Text('Delete',
                  style: TextStyle(fontSize: 13, color: kAccent)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await _confirmDelete();
                if (ok) {
                  await ClipRepository.delete(clip.path);
                  await _load();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _share(BuildContext sheetCtx, Clip clip, ShareTarget t) async {
    Navigator.pop(sheetCtx);
    final ok = await ClipRepository.share(clip.path, t);
    Analytics.instance.log('share', {
      'target': t.name,
      'source': 'gallery',
      'ok': ok ? 1 : 0,
    });
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app available to share')),
      );
    }
  }

  Future<bool> _confirmDelete() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Delete clip?', style: TextStyle(fontSize: 16)),
        content: const Text('This removes the file from your device.',
            style: TextStyle(fontSize: 12, color: kTextDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: kAccent)),
          ),
        ],
      ),
    );
    return res ?? false;
  }
}

class _ClipTile extends StatelessWidget {
  final Clip clip;
  final VoidCallback onTap;

  const _ClipTile({required this.clip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: kSurface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Thumb(clip: clip),
              // Readability scrim, no blur (cheap on low-end GPUs).
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                    stops: [0.45, 1],
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    clip.durationLabel,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (clip.exported)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: kLime,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('REEL',
                        style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            color: Colors.black)),
                  ),
                )
              else
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('MASTER',
                        style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70)),
                  ),
                ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 9,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clip.sizeLabel,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${clip.date.day}/${clip.date.month}/${clip.date.year}  '
                      '${clip.date.hour.toString().padLeft(2, '0')}:'
                      '${clip.date.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: kTextDim, fontSize: 9),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loads the native thumbnail once per tile; keeps memory low by decoding a
/// 360 px JPEG instead of a full video frame.
class _Thumb extends StatefulWidget {
  final Clip clip;
  const _Thumb({required this.clip});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  String? _path;

  @override
  void initState() {
    super.initState();
    _path = widget.clip.thumbPath;
    if (_path == null) _load();
  }

  Future<void> _load() async {
    final p = await ClipRepository.thumbnail(widget.clip.path);
    if (mounted) setState(() => _path = p);
  }

  @override
  Widget build(BuildContext context) {
    final p = _path;
    if (p == null) {
      return const Center(
        child: Icon(Icons.movie_outlined, size: 22, color: kTextDim),
      );
    }
    return Image.file(
      File(p),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const Center(
        child: Icon(Icons.movie_outlined, size: 22, color: kTextDim),
      ),
    );
  }
}
