import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = FlutterSoundRecorder();
  final List<Map<String, dynamic>> _messages = [];
  StreamSubscription<DatabaseEvent>? _subscription;
  StreamSubscription<RecordingDisposition>? _recordingSubscription;
  Map<String, dynamic>? _reply;
  String _uid = '', _name = '';
  bool _recording = false, _recorderReady = false, _sending = false;
  int _seconds = 0;
  final List<double> _levels = [];
  Timer? _timer;

  @override
  void initState() { super.initState(); _init(); }
  Future<void> _init() async {
    final p = await SharedPreferences.getInstance(); _uid = p.getString('uid') ?? ''; _name = p.getString('name') ?? '';
    try { await _recorder.openRecorder(); await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100)); _recorderReady = true; } catch (_) {}
    try { _subscription = FirebaseDatabase.instance.ref('messages').limitToLast(100).onValue.listen(_readMessages); } catch (_) {}
    if (mounted) setState(() {});
  }
  void _readMessages(DatabaseEvent event) { final value = event.snapshot.value; if (value is! Map) return; final list = <Map<String, dynamic>>[]; value.forEach((key, val) { if (val is Map) { final m = Map<String, dynamic>.from(val); m['id'] = key.toString(); list.add(m); } }); list.sort((a, b) => ((a['time'] as num?) ?? 0).compareTo((b['time'] as num?) ?? 0)); if (mounted) setState(() { _messages..clear()..addAll(list); }); }
  @override
  void dispose() { _subscription?.cancel(); _recordingSubscription?.cancel(); _timer?.cancel(); _recorder.closeRecorder(); _input.dispose(); _scroll.dispose(); super.dispose(); }

  Future<void> _sendText() async {
    final text = _input.text.trim(); if (text.isEmpty || _sending) return; setState(() => _sending = true);
    final data = <String, dynamic>{'text': text, 'senderId': _uid, 'senderName': _name, 'time': ServerValue.timestamp}; if (_reply != null) data['replyTo'] = {'id': _reply!['id'], 'name': _reply!['senderName'], 'text': _reply!['text']};
    try { await FirebaseDatabase.instance.ref('messages').push().set(data); _input.clear(); setState(() => _reply = null); } catch (_) { _toast('تعذر إرسال الرسالة'); } finally { if (mounted) setState(() => _sending = false); }
  }

  Future<void> _startRecording() async {
    if (!_recorderReady || _recording) return; try {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) { _toast('اسمح للتطبيق باستخدام الميكروفون أولًا'); return; }
      final dir = await getTemporaryDirectory(); final path = '${dir.path}/record_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.startRecorder(toFile: path, codec: Codec.aacMP4, audioSource: AudioSource.voice_recognition);
      _levels.clear(); _seconds = 0; _recording = true; _timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() => _seconds++); });
      _recordingSubscription = _recorder.onProgress?.listen((d) { final db = d.decibels ?? -45; if (mounted) setState(() => _levels.add(((db + 45) / 45).clamp(.08, 1.0))); });
      setState(() {});
    } catch (_) { _toast('لا يمكن تشغيل الميكروفون'); }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return; final path = await _recorder.stopRecorder(); _timer?.cancel(); await _recordingSubscription?.cancel(); _recordingSubscription = null; setState(() => _recording = false);
    if (path == null) return; final file = File(path); if (!await file.exists()) return; final bytes = await file.readAsBytes(); if (bytes.length < 512) { _toast('التسجيل قصير جدًا'); return; }
    try { final data = {'audioBase64': base64Encode(bytes), 'audioDuration': _seconds, 'waveform': _levels.map((x) => x.toStringAsFixed(2)).join(','), 'senderId': _uid, 'senderName': _name, 'time': ServerValue.timestamp}; await FirebaseDatabase.instance.ref('messages').push().set(data); } catch (_) { _toast('تعذر إرسال التسجيل'); }
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text, textDirection: TextDirection.rtl)));
  void _replyTo(Map<String, dynamic> m) => setState(() => _reply = m);

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: const Color(0xFFFFF8F8), appBar: AppBar(backgroundColor: const Color(0xFFE85C5C), title: const Text('Ahmed Saad Community'), actions: [IconButton(onPressed: _editProfile, icon: const Icon(Icons.account_circle))]), body: Column(children: [
        Expanded(child: ListView.builder(controller: _scroll, reverse: false, padding: const EdgeInsets.only(top: 12, bottom: 8), itemCount: _messages.length, itemBuilder: (_, i) { final m = _messages[i]; return MessageBubble(message: m, mine: m['senderId'] == _uid, onReply: () => _replyTo(m)); })),
        if (_reply != null) ListTile(dense: true, title: Text('الرد على ${_reply!['senderName']}', textDirection: TextDirection.rtl), subtitle: Text('${_reply!['text'] ?? 'تسجيل صوتي'}', maxLines: 1, overflow: TextOverflow.ellipsis, textDirection: TextDirection.rtl), trailing: IconButton(onPressed: () => setState(() => _reply = null), icon: const Icon(Icons.close))),
        if (_recording) _recordingBar() else _inputBar(),
      ]));

  Widget _inputBar() => SafeArea(child: Row(children: [IconButton(icon: Icon(_input.text.trim().isEmpty ? Icons.mic : Icons.send, color: const Color(0xFF111111)), onPressed: _input.text.trim().isEmpty ? _startRecording : _sendText), Expanded(child: TextField(controller: _input, maxLines: 4, textDirection: TextDirection.rtl, onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'اكتب رسالتك...', border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(25))))))]));
  Widget _recordingBar() => SafeArea(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10), height: 64, child: Row(children: [Text('${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}'), Expanded(child: CustomPaint(painter: _LiveWavePainter(_levels), size: const Size(double.infinity, 48))), IconButton(onPressed: _stopRecording, icon: const Icon(Icons.stop_circle, color: Color(0xFFE85C5C), size: 32))])));

  Future<void> _editProfile() async { final c = TextEditingController(text: _name); final value = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('Edit name'), content: TextField(controller: c, textDirection: TextDirection.rtl), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Save'))])); if (value == null || value.isEmpty) return; final p = await SharedPreferences.getInstance(); await p.setString('name', value); setState(() => _name = value); try { await FirebaseDatabase.instance.ref('users/$_uid/name').set(value); } catch (_) {} }
}

class _LiveWavePainter extends CustomPainter { final List<double> values; _LiveWavePainter(this.values); @override void paint(Canvas c, Size s) { final p = Paint()..color = const Color(0xFFE85C5C)..strokeWidth = 3..strokeCap = StrokeCap.round; final n = values.isEmpty ? 24 : values.length; final step = s.width / n; for (var i = 0; i < n; i++) { final h = (i < values.length ? values[i] : .15) * s.height; final x = i * step + step / 2; c.drawLine(Offset(x, s.height / 2 - h / 2), Offset(x, s.height / 2 + h / 2), p); } } @override bool shouldRepaint(covariant _LiveWavePainter old) => true; }
