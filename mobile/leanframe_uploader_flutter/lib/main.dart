import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LeanFrame Uploader',
      home: const UploaderPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class UploaderPage extends StatefulWidget {
  const UploaderPage({super.key});
  @override
  State<UploaderPage> createState() => _UploaderPageState();
}

class _UploaderPageState extends State<UploaderPage> {
  final hostCtrl = TextEditingController(text: 'http://leanframe.local:8765');
  final tokenCtrl = TextEditingController(text: 'change-me');
  String status = '';

  Future<void> pickAndUpload() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    for (final f in res.files) {
      final file = File(f.path!);
      final uri = Uri.parse('${hostCtrl.text}/upload');
      final req = http.MultipartRequest('POST', uri)
        ..headers['X-Auth-Token'] = tokenCtrl.text
        ..files.add(await http.MultipartFile.fromPath('file', file.path));
      final resp = await req.send();
      setState(() => status = 'Uploading ${file.path} → ${resp.statusCode}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LeanFrame Uploader')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(children: [
          TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: 'Server URL')),
          TextField(controller: tokenCtrl, decoration: const InputDecoration(labelText: 'Auth Token')),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: pickAndUpload, child: const Text('Pick files & upload')),
          const SizedBox(height: 12),
          Text(status),
        ]),
      ),
    );
  }
}