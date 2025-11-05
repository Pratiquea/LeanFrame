import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const LeanFrameApp());

/// ----------------------------------------------------------------------------
/// App State & API
/// ----------------------------------------------------------------------------
class AppState extends ChangeNotifier {
  String frameName = "My Frame";
  String? serverBase; // e.g. http://192.168.1.50:8765
  String authToken = "change-me";
  bool connected = false;

  final List<MediaItem> media = [];

  int get imageCount => media.length;

  void setServer({required String base, required String token}) {
    serverBase = base.trim();
    authToken = token.trim();
    notifyListeners();
  }

  void setFrameName(String name) {
    frameName = name.trim().isEmpty ? frameName : name.trim();
    notifyListeners();
  }

  void setConnection(bool ok) {
    connected = ok;
    notifyListeners();
  }

  void addMedia(MediaItem item) {
    media.add(item);
    notifyListeners();
  }
}

class MediaItem {
  final String id;
  final String thumbPath; // placeholder for now
  MediaItem({required this.id, required this.thumbPath});
}

class Api {
  final String base;
  final String token;
  Api(this.base, this.token);

  Map<String, String> get _headers => {'X-Auth-Token': token};

  Future<bool> ping() async {
    try {
      final res = await http.get(Uri.parse('$base/config/runtime'), headers: _headers)
                          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) {
        debugPrint('Ping failed ${res.statusCode}: ${res.body}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Ping exception: $e');
      return false;
    }
  }

  Future<bool> uploadFile(File file) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse("$base/upload"));
      req.headers.addAll(_headers);
      req.files.add(await http.MultipartFile.fromPath('file', file.path));
      final streamed = await req.send();
      return streamed.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

class QrParseResult {
  final String? wifiSsid;
  final String? wifiPassword;
  final String? wifiAuth; // WPA/WEP/nopass
  final bool? wifiHidden;
  final Uri? setupBase;
  final Map<String, dynamic>? jsonPayload;
  QrParseResult({
    this.wifiSsid,
    this.wifiPassword,
    this.wifiAuth,
    this.wifiHidden,
    this.setupBase,
    this.jsonPayload,
  });
}

final _wifiRe = RegExp(
  r'^WIFI:'
  r'(?:T:(?<T>WPA|WEP|nopass);)?'
  r'(?:S:(?<S>[^;]*);)?'
  r'(?:P:(?<P>[^;]*);)?'
  r'(?:H:(?<H>true|false);)?'
  r'(?:;)*$',
);

QrParseResult parseQr(String raw) {
  final s = raw.trim();

  // 1) WIFI: schema (Android/iOS standard)
  final m = _wifiRe.firstMatch(s);
  if (m != null) {
    final ssid = m.namedGroup('S') ?? '';
    final pwd  = m.namedGroup('P') ?? '';
    final auth = m.namedGroup('T') ?? 'WPA';
    final hid  = (m.namedGroup('H') ?? 'false').toLowerCase() == 'true';

    // Optional: also look for an http URL in the same string (rare, but ok)
    Uri? setup;
    try {
      final maybeUrl = s.split(';').firstWhere(
        (p) => p.startsWith('http://') || p.startsWith('https://'),
        orElse: () => '',
      );
      setup = maybeUrl.isNotEmpty ? Uri.parse(maybeUrl) : null;
    } catch (_) {}

    return QrParseResult(
      wifiSsid: ssid,
      wifiPassword: pwd,
      wifiAuth: auth,
      wifiHidden: hid,
      setupBase: setup,
    );
  }

  // 2) JSON (your legacy/custom payload)
  try {
    final obj = jsonDecode(s) as Map<String, dynamic>;
    // If you want, validate a "kind" discriminator:
    // if (obj['kind'] != 'leanframe_setup_v1') throw FormatException('wrong kind');
    final base = (obj['setup_base'] is String) ? Uri.tryParse(obj['setup_base']) : null;
    return QrParseResult(
      jsonPayload: obj,
      setupBase: base,
      wifiSsid: obj['ap_ssid'],
      wifiPassword: obj['ap_psk'],
    );
  } catch (_) {
    // fall through
  }

  // 3) Plain URL (fallback)
  final u = Uri.tryParse(s);
  if (u != null && (u.isScheme('http') || u.isScheme('https'))) {
    return QrParseResult(setupBase: u);
  }

  // 4) Nothing matched
  throw FormatException('Invalid QR payload');
}

class RuntimeConfig {
  // Render
  String mode;           // "cover" | "contain"
  String paddingStyle;   // "blur" | "solid"
  String paddingColor;   // "#RRGGBB"
  double blurAmount;     // e.g., 16.0 (used when style == "blur")

  // Playback
  double slideDurationS; // better name for default_image_seconds
  bool shuffle;
  bool loop;
  int crossfadeMs;       // better name for transition_crossfade_ms

  RuntimeConfig({
    required this.mode,
    required this.paddingStyle,
    required this.paddingColor,
    required this.blurAmount,
    required this.slideDurationS,
    required this.shuffle,
    required this.loop,
    required this.crossfadeMs,
  });

  factory RuntimeConfig.fromJson(Map<String,dynamic> j) => RuntimeConfig(
    mode: j["render"]["mode"],
    paddingStyle: j["render"]["padding"]["style"],
    paddingColor: j["render"]["padding"]["color"],
    blurAmount: (j["render"]["padding"]["blur_amount"] ?? 16).toDouble(),
    slideDurationS: (j["playback"]["slide_duration_s"]).toDouble(),
    shuffle: j["playback"]["shuffle"] == true,
    loop: j["playback"]["loop"] == true,
    crossfadeMs: j["playback"]["crossfade_ms"],
  );

  Map<String,dynamic> toJson() => {
    "render": {
      "mode": mode,
      "padding": {
        "style": paddingStyle,
        "color": paddingColor,
        "blur_amount": blurAmount,
      }
    },
    "playback": {
      "slide_duration_s": slideDurationS,
      "shuffle": shuffle,
      "loop": loop,
      "crossfade_ms": crossfadeMs,
    }
  };
}

extension ApiRuntime on Api {
  Future<RuntimeConfig> getRuntime() async {
    final res = await http.get(Uri.parse("$base/config/runtime"), headers: _headers);
    if (res.statusCode != 200) { throw Exception("get runtime ${res.statusCode}"); }
    return RuntimeConfig.fromJson(json.decode(res.body));
  }
  Future<bool> putRuntime(RuntimeConfig cfg) async {
    final res = await http.put(
      Uri.parse("$base/config/runtime"),
      headers: {..._headers, "Content-Type": "application/json"},
      body: json.encode(cfg.toJson()),
    );
    return res.statusCode == 200;
  }
}

/// ----------------------------------------------------------------------------
/// First-run wizard
/// ----------------------------------------------------------------------------
class FirstRunWizard extends StatefulWidget {
  const FirstRunWizard({super.key});
  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  int step = 0;
  PairPayload? payload;
  final ssidCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  bool posting = false;
  bool _handledScan = false; 
  String? error;
  // Wi-Fi scan + dropdown state 
  List<WifiNetwork> _nearby = const [];
  String? _selectedSsid;
  bool _scanning = false;
  bool _showPass = false;          // 👁 toggle for password field
  String _currSsid = "";           // live device Wi-Fi status
  String _currIp = "";             // live device Wi-Fi status
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discSub;

  Future<void> _discoverFrameAndAutoConnect() async {
    try {
      const String serviceType = '_leanframe._tcp'; // <-- match your frame's advertised type
      final discovery = BonsoirDiscovery(type: serviceType);
      _discovery = discovery;

      // v6: initialize() replaces the old "ready" getter
      await discovery.initialize();

      // Listen BEFORE starting
      _discSub = discovery.eventStream!.listen((event) async {
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          // v6: resolve requires a resolver
          event.service!.resolve(discovery.serviceResolver);
        } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final s = event.service!;
          // v6: no "ip" field; use addresses or host
          final Map<String, dynamic> j = s.toJson();
          final List addrs = (j['addresses'] as List?) ?? const [];
          final String host = addrs.isNotEmpty ? addrs.first as String : (s.host ?? '');
          final int port = s.port ?? 8765;
          if (host.isEmpty) return;

          final base = 'http://$host:$port';
          debugPrint('Discovered LeanFrame at $base');

          final app = InheritedAppState.of(context);
          app.setServer(base: base, token: app.authToken);
          final ok = await Api(base, app.authToken).ping();
          app.setConnection(ok);

          // Found one → stop discovery
          await _discovery?.stop();
          await _discSub?.cancel();
        }
        // Other events (updated/lost) can be ignored for this flow
      });

      await discovery.start();
    } catch (e) {
      debugPrint('mDNS discovery error: $e');
    }
  }

  Future<void> _readWifiStatus() async {
    try {
      final ssid = await WiFiForIoTPlugin.getSSID() ?? "";
      final ip   = await WiFiForIoTPlugin.getIP() ?? "";
      setState(() { _currSsid = ssid; _currIp = ip; });
      debugPrint("Wi-Fi status: ssid='$_currSsid' ip='$_currIp'");
    } catch (e) {
      debugPrint("Wi-Fi status error: $e");
    }
  }

  /// Try hard to connect to the target AP, and only return true when
  /// SSID == target and IP looks like 192.168.4.x
  Future<bool> _connectToApAndVerify({required String targetSsid, required String psk}) async {
    // Android requirements
    if (Platform.isAndroid) {
      final loc = await Permission.location.request();
      if (!loc.isGranted) {
        setState(() => error = "Location permission is required to connect Wi-Fi.");
        return false;
      }
      // Ensure Wi-Fi radio is ON
      if (!await WiFiForIoTPlugin.isEnabled()) {
        await WiFiForIoTPlugin.setEnabled(true);
      }
    }

    // If already on the AP, great
    await _readWifiStatus();
    if (_currSsid == targetSsid && _currIp.startsWith("192.168.4.")) {
      // ensure routing over Wi-Fi for local-only network
      if (Platform.isAndroid) await WiFiForIoTPlugin.forceWifiUsage(true);
      return true;
    }

    // Proactively disconnect from whatever we’re on (some OEMs cling)
    try { await WiFiForIoTPlugin.disconnect(); } catch (_) {}

    // Ask plugin to connect to our AP
    final ok = await WiFiForIoTPlugin.connect(
      targetSsid,
      password: psk,
      security: NetworkSecurity.WPA,
      joinOnce: true,         // don’t persist
      withInternet: false,    // local-only AP
    );

    if (!ok) {
      setState(() => error = "Couldn’t initiate connection to '$targetSsid'. Open Wi-Fi settings and join it, then return.");
      return false;
    }

    // Force sockets over this Wi-Fi even without internet
    if (Platform.isAndroid) {
      await WiFiForIoTPlugin.forceWifiUsage(true);
    }

    // Poll until actually connected to the right SSID + IP in 192.168.4.*
    final good = await _waitForApReady(
      wantSsid: targetSsid,
      wantSubnetPrefix: "192.168.4.",
      maxWait: const Duration(seconds: 25),
    );
    await _readWifiStatus(); // update banner

    return good;
  }


  Future<void> _refreshPairFromServer() async {
    // Must already be connected to the frame AP.
    final p = payload!;
    final uri = Uri.parse("${p.setupBase}/pair");
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final j = json.decode(res.body) as Map<String, dynamic>;
        final newPair = (j['pair_code'] as String?)?.trim();
        final dev     = (j['device_id'] as String?)?.trim();
        if (newPair != null && newPair.isNotEmpty) {
          // Rebuild payload with the real pair code (keep ssid/psk/setupBase/deviceId best-effort)
          setState(() {
            payload = PairPayload(
              p.ssid,
              p.psk,
              newPair,
              (dev?.isNotEmpty == true ? dev! : p.deviceId),
              p.setupBase,
            );
          });
        }
      } else {
        debugPrint("GET /pair -> ${res.statusCode} ${res.body}");
      }
    } catch (e) {
      debugPrint("GET /pair failed: $e");
    }
  }

  Future<bool> _waitForApReady({
  required String wantSsid,
  required String wantSubnetPrefix,
  Duration maxWait = const Duration(seconds: 20),
  }) async {
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < maxWait) {
      try {
        final ssid = await WiFiForIoTPlugin.getSSID() ?? "";
        final ip   = await WiFiForIoTPlugin.getIP() ?? "";
        debugPrint("Wi-Fi status → SSID='$ssid' IP='$ip'");

        final onTarget = ssid == wantSsid && ip.startsWith(wantSubnetPrefix);
        if (onTarget) return true;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<bool> _probeSetupBase(Uri url) async {
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 3));
      debugPrint("Probe ${url} → ${res.statusCode}");
      return res.statusCode < 500;
    } catch (e) {
      debugPrint("Probe error: $e");
      return false;
    }
  }


  Future<void> _scanNearbyWifi() async {
    setState(() { _scanning = true; error = null; });
    try {
      // Android 10+: location permission is required to scan Wi-Fi
      if (Platform.isAndroid) {
        final st = await Permission.location.request();
        if (!st.isGranted) {
          setState(() { error = "Location permission is required to scan nearby Wi-Fi."; _scanning = false; });
          return;
        }
      }
      final list = await WiFiForIoTPlugin.loadWifiList(); // returns List<WifiNetwork>
      // De-duplicate by SSID, drop empties
      final ssids = <String>{};
      final cleaned = <WifiNetwork>[];
      for (final w in list) {
        final s = (w.ssid ?? '').trim();
        if (s.isEmpty) continue;
        if (ssids.add(s)) cleaned.add(w);
      }
      cleaned.sort((a,b) => (a.level ?? -100).compareTo(b.level ?? -100)); // weak→strong; reverse if you prefer
      setState(() {
        _nearby = cleaned.reversed.toList(); // strong→weak
        // keep previous selection if still visible
        if (_selectedSsid == null || !_nearby.any((w) => w.ssid == _selectedSsid)) {
          _selectedSsid = _nearby.isNotEmpty ? _nearby.first.ssid : null;
        }
      });
    } catch (e) {
      setState(() => error = "Scan error: $e");
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _discSub?.cancel();
    _discovery?.stop();
    ssidCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  void _onScan(String qrText) {
    try {
      final res = parseQr(qrText);

      final Uri setup = res.setupBase ?? Uri.parse('http://192.168.4.1:8765');
      final ssid = res.wifiSsid ?? (res.jsonPayload?['ap_ssid'] as String? ?? '');
      final psk  = res.wifiPassword ?? (res.jsonPayload?['ap_psk'] as String? ?? '');
      final pair = (res.jsonPayload?['pair_code'] as String?) ?? '0000';
      final dev  = (res.jsonPayload?['device_id'] as String?) ?? 'unknown';

      if (ssid.isEmpty || psk.isEmpty) {
        throw const FormatException('QR missing SSID/PSK');
      }

      setState(() {
        payload = PairPayload(ssid, psk, pair, dev, setup.toString());
        _handledScan = true;
        step = 2; // “Connect to setup Wi-Fi”
      });
    } catch (e) {
      setState(() => error = "Invalid QR: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      _stepWelcome(),
      _stepScanQR(),
      _stepConnectAP(),
      _stepEnterHomeWifi(),
      _stepDone(),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text("Set up your frame")),
      body: steps[step],
    );
  }

  Widget _stepWelcome() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Welcome", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text("Plug in your LeanFrame. When the QR appears, continue."),
        const Spacer(),
        Row(children: [
          const Spacer(),
          FilledButton(onPressed: () => setState(() => step = 1), child: const Text("Continue")),
        ]),
      ]),
    );
  }

  Widget _stepScanQR() {
    return Column(children: [
      const SizedBox(height: 8),
      const Text("Scan the QR on your frame"),
      const SizedBox(height: 12),
      Expanded(
        child: MobileScanner(
          onDetect: (capture) {
          if (_handledScan) return;
          final raw = capture.barcodes.firstOrNull?.rawValue;
          if (raw == null || raw.isEmpty) return;
          _onScan(raw);
        },
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(error!, style: const TextStyle(color: Colors.red)),
        ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _stepConnectAP() {
    if (payload == null) {
      // user navigated here without a valid scan
      return _inlineError("Please scan the QR first", backTo: 1);
    }

    final p = payload!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Connect to setup Wi-Fi", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text("Join this temporary Wi-Fi network:\n\nSSID: ${p.ssid}\nPassword: ${p.psk}"),
        const SizedBox(height: 12),
        const Text("After connecting, return to this app."),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.wifi),
          label: const Text("Connect now"),
          onPressed: () async {
            final p = payload!;
            setState(() { error = null; });

            final good = await _connectToApAndVerify(targetSsid: p.ssid, psk: p.psk);
            if (!good) {
              setState(() => error = "Wi-Fi didn’t fully connect. Check the password on the frame QR or try again.");
              return;
            }

            // We should now be on the AP. Double-check the setup server before proceeding.
            final probe = await _probeSetupBase(Uri.parse("${p.setupBase}/pair"));
            if (!probe) {
              setState(() => error = "Connected to '${p.ssid}', but ${p.setupBase} is not reachable. Stay on frame Wi-Fi and retry.");
              return;
            }

            // Pull the fresh pair code (in case placeholder)
            await _refreshPairFromServer();

            if (mounted) setState(() => step = 3);
          }
        ),
        const Spacer(),
        /// Controls + status stacked vertically (no Row here)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => step = 1),
                  child: const Text("Back"),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => setState(() => step = 3),
                  child: const Text("I’m connected"),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Phone connection status", style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text("SSID: ${_currSsid.isEmpty ? '—' : _currSsid}"),
                  Text("IP:   ${_currIp.isEmpty   ? '—' : _currIp}"),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _readWifiStatus,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text("Refresh"),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ]),
    );
  }

  Widget _stepEnterHomeWifi() {
    if (payload == null) {
      return _inlineError("Please scan the QR first", backTo: 1);
    }
    // Best-effort: if we still have a placeholder, refresh pair_code on step entry.
    if (payload!.pairCode == '0000' || payload!.pairCode.trim().isEmpty) {
      // fire and forget; UI doesn't block
      _refreshPairFromServer();
    }

    final p = payload!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Your home Wi-Fi", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),

        //  Android gets a dropdown of nearby SSIDs
        //  Android gets a dropdown of nearby SSIDs
        if (Platform.isAndroid) ...[
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                value: _selectedSsid,
                hint: const Text("Select a Wi-Fi network"),
                items: _nearby.map((w) {
                  final s = (w.ssid ?? '').trim();
                  // we already filtered empties in _scanNearbyWifi()
                  return DropdownMenuItem<String>(
                    value: s,                      // <- non-null
                    child: Text(s, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: (v) => setState(() {
                  _selectedSsid = v;
                  if ((v ?? '').isNotEmpty) {
                    ssidCtrl.text = v!;           // keep the text field in sync
                  }
                }),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _scanning ? null : _scanNearbyWifi,
              icon: _scanning
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              label: const Text("Scan"),
            ),
          ]),
          const SizedBox(height: 8),
        ],


        // iOS fallback OR manual override: allow entering SSID if needed 
        if (!Platform.isAndroid) ...[
          TextField(controller: ssidCtrl, decoration: const InputDecoration(labelText: "Home Wi-Fi SSID")),
          const SizedBox(height: 8),
          const Text("Tip: iOS doesn’t permit apps to list nearby SSIDs; enter your network name.", style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
        ],

        TextField(
          controller: passCtrl,
          decoration: InputDecoration(
            labelText: "Password",
            suffixIcon: IconButton(
              tooltip: _showPass ? "Hide password" : "Show password",
              icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPass = !_showPass),
            ),
          ),
          obscureText: !_showPass,
        ),

        const SizedBox(height: 12),

        if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),

        const Spacer(),
        Row(children: [
          TextButton(onPressed: () => setState(() => step = 2), child: const Text("Back")),
          const Spacer(),
          FilledButton.icon(
            icon: posting
                ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2))
                : const Icon(Icons.check),
            label: const Text("Connect"),
            onPressed: posting ? null : () async {
              setState(() { posting = true; error = null; });
              final p = payload!;
              try {
                // Make sure we’re still on the AP
                final probeOk = await _probeSetupBase(Uri.parse("${p.setupBase}/status"));
                if (!probeOk) {
                  setState(() => error = "Not connected to the frame’s Wi-Fi. Stay on '${p.ssid}' while provisioning.");
                  return;
                }

                // Ensure we have a real pair code (not the "0000" placeholder)
                if (p.pairCode == '0000' || p.pairCode.trim().isEmpty) {
                  await _refreshPairFromServer();
                }

                // Use dropdown on Android; text field elsewhere
                final homeSsid = Platform.isAndroid ? (_selectedSsid ?? '') : ssidCtrl.text.trim();
                if (homeSsid.isEmpty) {
                  setState(() => error = "Please select/enter your home Wi-Fi SSID.");
                  return;
                }
                final payloadBody = {
                  "pair_code": payload!.pairCode, // may have been updated by _refreshPairFromServer()
                  "wifi": {"ssid": homeSsid, "password": passCtrl.text.trim()},
                };

                Future<http.Response> _post() => http
                    .post(
                      Uri.parse("${payload!.setupBase}/provision"),
                      headers: {"Content-Type":"application/json"},
                      body: json.encode(payloadBody),
                    )
                    .timeout(const Duration(seconds: 8));

                http.Response res = await _post();

                // If backend says 400 (e.g., stale/invalid code), fetch new pair_code once and retry once
                if (res.statusCode == 400) {
                  await _refreshPairFromServer(); // update payload!.pairCode if changed
                  final retryBody = {
                    "pair_code": payload!.pairCode,
                    "wifi": {"ssid": homeSsid, "password": passCtrl.text.trim()},
                  };
                  res = await http
                      .post(
                        Uri.parse("${payload!.setupBase}/provision"),
                        headers: {"Content-Type":"application/json"},
                        body: json.encode(retryBody),
                      )
                      .timeout(const Duration(seconds: 8));
                }

                if (res.statusCode == 200) {
                  if (mounted) {
                    setState(() => step = 4);
                    // Fire and forget: discover the frame on the home network and auto-fill Server URL.
                    _discoverFrameAndAutoConnect();
                  }
                } else {
                  setState(() => error = "Provision failed: ${res.statusCode} ${res.body}");
                }
              } catch (e) {
                setState(() => error = "Network error: $e");
              } finally {
                if (mounted) setState(() => posting = false);
              }
            },
          ),
        ]),
      ]),
    );

  }

  Widget _inlineError(String msg, {required int backTo}) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(msg, style: const TextStyle(color: Colors.red)),
          const Spacer(),
          Row(children: [
            const Spacer(),
            FilledButton(
              onPressed: () => setState(() => step = backTo),
              child: const Text("Go back"),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _stepDone() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoDiscoverAndConnect(context);
    });
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("All set!", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text("Your frame is joining your home Wi-Fi. Reconnect your phone to your normal Wi-Fi."),
        const SizedBox(height: 8),
        const Text("Then open Home → Settings (gear) and press Connect."),
        const Spacer(),
        Row(children: [
          const Spacer(),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text("Finish")),
        ]),
      ]),
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}


/// ----------------------------------------------------------------------------
/// QR code payload for initial setup
/// ----------------------------------------------------------------------------
class PairPayload {
  final String ssid, psk, pairCode, deviceId, setupBase;
  PairPayload(this.ssid, this.psk, this.pairCode, this.deviceId, this.setupBase);

  factory PairPayload.fromJson(Map<String, dynamic> j) {
    final kind = j["kind"] ?? "leanframe_setup_v1";
    if (kind != "leanframe_setup_v1") {
      throw Exception("Unsupported QR kind '$kind'");
    }
    String req(String k) {
      final v = j[k];
      if (v is String && v.isNotEmpty) return v;
      throw Exception("QR is missing '$k'");
    }
    return PairPayload(
      req("ap_ssid"),
      req("ap_psk"),
      req("pair_code"),
      req("device_id"),
      req("setup_base"),
    );
  }
}

/// ----------------------------------------------------------------------------
/// App root
/// ----------------------------------------------------------------------------
class LeanFrameApp extends StatelessWidget {
  const LeanFrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LeanFrame',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
      home: InheritedAppState(
        notifier: AppState(),
        child: const HomeScreen(),
      ),
    );
  }
}

class InheritedAppState extends InheritedNotifier<AppState> {
  const InheritedAppState({super.key, required super.notifier, required super.child});
  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedAppState>()!.notifier!;
}

/// ----------------------------------------------------------------------------
/// Home (system picker; new UI tweaks)
/// ----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.thisdiscoverOverride});

  /// If provided, this is used instead of _refreshAndDiscover().
  final Future<void> Function()? thisdiscoverOverride;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HubTab { photos, settings}

class _HomeScreenState extends State<HomeScreen> {
  HubTab tab = HubTab.photos;

  Future<void> _refreshAndDiscover({int tries = 4}) async {
    final state = InheritedAppState.of(context);
    for (var i = 0; i < tries; i++) {
      await autoDiscoverAndConnect(context, timeout: const Duration(seconds: 4));
      if (!mounted) return;
      if (state.connected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Frame found and connected")),
        );
        return;
      }
      await Future.delayed(const Duration(milliseconds: 350));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("No frame discovered on your network")),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAndDiscover(tries: 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);

    // compute this BEFORE returning the widget tree
    final bool needsSetup = state.serverBase == null || !state.connected;

    return Scaffold(
      drawer: const _AppDrawer(),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                state.frameName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () async {
                final newName = await _promptForText(context, "Rename frame", state.frameName);
                if (newName != null) state.setFrameName(newName);
              },
              child: const Icon(Icons.edit, size: 18),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          Icon(
            state.connected ? Icons.circle : Icons.circle_outlined,
            color: state.connected ? Colors.green : Colors.grey,
            size: 12,
          ),
          IconButton(
            tooltip: 'Find connected device',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              final fn = widget.thisdiscoverOverride ?? (() => _refreshAndDiscover());
              fn();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final out = await showDialog<_ServerCfg>(
                context: context,
                builder: (_) => _ServerConfigDialog(
                  initialBase: state.serverBase ?? "http://192.168.1.104:8765",
                  initialToken: state.authToken,
                ),
              );
              if (out != null) {
                state.setServer(base: out.base, token: out.token);
                final up = await Api(out.base, out.token).ping();
                state.setConnection(up);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(up ? "Connected" : "Server not reachable")),
                );
              }
            },
          ),
        ],
      ),

      body: Column(
        children: [
          const SizedBox(height: 8),

          // Use collection-if here (no declarations inside the list)
          if (needsSetup)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                color: Colors.amber.shade100,
                child: ListTile(
                  leading: const Icon(Icons.qr_code_2),
                  title: const Text("Set up your new frame"),
                  subtitle: const Text("Scan QR, join setup Wi-Fi, and provision"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FirstRunWizard()),
                    );
                  },
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: CupertinoSegmentedControl<HubTab>(
              groupValue: tab,
              onValueChanged: (v) => setState(() => tab = v),
              children: const {
                HubTab.photos: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.grid_on, size: 16), SizedBox(width: 6), Text("Photos")
                  ]),
                ),
                HubTab.settings: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.settings, size: 16), SizedBox(width: 6), Text("Settings")
                  ]),
                ),
              },
            ),
          ),

          const SizedBox(height: 8),
          if (tab == HubTab.photos)
            _PhotosHeaderRow(count: state.imageCount)
          else
            const _ActivityPlaceholder(),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () {
                final fn = widget.thisdiscoverOverride ?? (() => _refreshAndDiscover());
                return fn();
              },
              child: tab == HubTab.photos
                  ? const _PhotoGrid()
                  : const FrameSettingsTab(),
            ),
          ),
        ],
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async => _runSystemPickerFlow(context),
              icon: const Icon(Icons.add),
              label: const Text("Add Photos"),
            ),
          ),
        ),
      ),
    );
  }

  /// -------------------- System picker flow -----------------------
  Future<void> _runSystemPickerFlow(BuildContext context) async {
    final state = InheritedAppState.of(context);
    if (state.serverBase == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Open settings (gear) and set Server URL/Token first.")),
      );
      return;
    }
    final api = Api(state.serverBase!, state.authToken);

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image, // or FileType.media for images+videos
    );
    if (result == null || result.files.isEmpty) return;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ConfirmUploadSheet(count: result.files.length),
    );
    if (confirmed != true) return;

    int ok = 0, fail = 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Uploading ${result.files.length} file(s)…")),
    );

    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      final success = await api.uploadFile(File(path));
      if (success) {
        ok++;
        InheritedAppState.of(context).addMedia(MediaItem(id: path, thumbPath: path));
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Uploaded $ok file(s)${fail > 0 ? ", $fail failed" : ""}")),
    );
  }
}

/// Drawer with two sections:
///  - Section 1: App name + '>' right-aligned
///  - Section 2: Frame name + green/gray indicator
class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);
    final dotColor = state.connected ? Colors.green : Colors.grey;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // Section 1
            ListTile(
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "LeanFrame",
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                  const Text(">", style: TextStyle(fontSize: 16)),
                ],
              ),
              onTap: () => Navigator.pop(context), // no-op; reserved for future
            ),
            const Divider(height: 1),

            // Section 2
            ListTile(
              leading: Icon(Icons.smart_display, color: dotColor),
              title: Text(
                state.frameName,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              trailing: Icon(
                Icons.circle,
                color: dotColor,
                size: 12,
              ),
              onTap: () => Navigator.pop(context),
            ),

            // (Optional) More items later:
            const SizedBox(height: 8),
            const Divider(height: 1),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("About"),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header row on Photos tab
class _PhotosHeaderRow extends StatelessWidget {
  final int count;
  const _PhotosHeaderRow({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Text("Photos ($count)", style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SelectionEditor()));
            },
            icon: const Icon(Icons.check_box),
            label: const Text("Select"),
          ),
        ],
      ),
    );
  }
}

class _ActivityPlaceholder extends StatelessWidget {
  const _ActivityPlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Align(alignment: Alignment.centerLeft, child: Text("Activity")),
    );
  }
}

class _ActivityCenter extends StatelessWidget {
  const _ActivityCenter();
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Recent uploads & sync events will appear here."));
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid();
  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);
    if (state.media.isEmpty) {
      return const Center(child: Text("No photos yet — tap Add Photos to begin."));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
      itemCount: state.media.length,
      itemBuilder: (_, i) {
        final m = state.media[i];
        return Container(
          color: Colors.grey.shade300,
          child: const Center(child: Icon(Icons.photo, size: 36, color: Colors.white70)),
        );
      },
    );
  }
}

class FrameSettingsTab extends StatefulWidget {
  const FrameSettingsTab({super.key});
  @override
  State<FrameSettingsTab> createState() => _FrameSettingsTabState();
}

class _FrameSettingsTabState extends State<FrameSettingsTab> {
  RuntimeConfig? cfg;
  bool saving = false;
  String? error;

  // temp UI state bindings
  late String _mode;
  late String _style;
  late String _colorHex;
  double _blur = 16;
  double _slideS = 12;
  bool _shuffle = false;
  bool _loop = true;
  int _crossfadeMs = 300;
  bool _loadedOnce = false; 

  static const _allStyles = <String>[
    "solid",
    "blur",
    "average",
    "mirror",
    "stretch",
    "gradient_linear",
    "gradient_radial",
    "glass",
    "motion",
    "texture",
    "dim",
  ];

  // Helpers for conditional controls
  bool get _usesBlur => _style == "blur" || _style == "glass";
  bool get _styleUsesColor => _style == "solid" || _style == "gradient_linear" || _style == "gradient_radial";

  String _labelForStyle(String s) {
    switch (s) {
      case "solid": return "Solid color";
      case "blur": return "Blur";
      case "average": return "Average color";
      case "mirror": return "Mirror pad";
      case "stretch": return "Stretch edges";
      case "gradient_linear": return "Gradient (linear)";
      case "gradient_radial": return "Gradient (radial)";
      case "glass": return "Glass (blurred tint)";
      case "motion": return "Motion smear";
      case "texture": return "Texture (grain)";
      case "dim": return "Dimmed avg";
      default: return s;
    }
  }

  @override
  void initState() {
    super.initState(); 
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoDiscoverAndConnect(context);
      //  _refreshAndDiscover(tries: 2);
    });
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedOnce) {
      _loadedOnce = true;
      // Safe: runs after the element is mounted so Inherited lookups work
      _load();
    }
  }


  Future<void> _load() async {
    final state = InheritedAppState.of(context);
    if (state.serverBase == null) { setState(() => error = "Set Server URL/Token in settings."); return; }
    try {
      final api = Api(state.serverBase!, state.authToken);
      final r = await api.getRuntime();
      setState(() {
        cfg = r;
        _mode = r.mode;
        _style = r.paddingStyle;
        _colorHex = r.paddingColor;
        _blur = r.blurAmount;
        _slideS = r.slideDurationS;
        _shuffle = r.shuffle;
        _loop = r.loop;
        _crossfadeMs = r.crossfadeMs;
      });
    } catch (e) {
      setState(() => error = "Failed to load: $e");
    }
  }

  Future<void> _save() async {
    final state = InheritedAppState.of(context);
    if (state.serverBase == null) return;
    setState(() { saving = true; error = null; });
    try {
      final api = Api(state.serverBase!, state.authToken);
      final ok = await api.putRuntime(RuntimeConfig(
        mode: _mode,
        paddingStyle: _style,         // includes "glass"
        paddingColor: _colorHex,      // only used when "solid"
        blurAmount: _usesBlur ? _blur : 0.0,
        slideDurationS: _slideS,
        shuffle: _shuffle,
        loop: _loop,
        crossfadeMs: _crossfadeMs,
      ));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? "Saved" : "Save failed")),
      );
      if (!ok) setState(() => error = "Save failed");
    } catch (e) {
      setState(() => error = "Save error: $e");
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      final app = InheritedAppState.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text("Open server settings"),
              onPressed: () async {
                final out = await showDialog<_ServerCfg>(
                  context: context,
                  builder: (_) => _ServerConfigDialog(
                    initialBase: app.serverBase ?? "http://192.168.1.104:8765",
                    initialToken: app.authToken,
                  ),
                );
                if (out != null) {
                  app.setServer(base: out.base, token: out.token);
                  final up = await Api(out.base, out.token).ping();
                  app.setConnection(up);
                  if (!mounted) return;
                  if (up) {
                    setState(() {
                      error = null;  // clear the error so UI can load
                      cfg = null;    // force spinner then reload
                    });
                    _load();         // fetch /config/runtime
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Server not reachable")),
                    );
                  }
                }
              },
            ),
          ],
        ),
      );
    }

    if (cfg == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
      children: [
        Text("Render", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),

        // 1.1 Mode: cover / contain
        Row(children: [
          const SizedBox(width: 140, child: Text("Fit mode")),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _mode,
            items: const [
              DropdownMenuItem(value: "cover", child: Text("Cover")),
              DropdownMenuItem(value: "contain", child: Text("Contain")),
            ],
            onChanged: (v) => setState(() => _mode = v!),
          ),
        ]),
        const SizedBox(height: 8),

        // 1.2/1.3 Padding style + 1.4 Color (if solid) + 1.5 Blur (if blur)
        Row(children: [
          const SizedBox(width: 140, child: Text("Padding style")),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _style,
            items: _allStyles
                .map((s) => DropdownMenuItem(value: s, child: Text(_labelForStyle(s))))
                .toList(),
            onChanged: (v) => setState(() => _style = v!),
          ),
        ]),
        const SizedBox(height: 8),

        // if (_style == "solid")
        //   Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        //     const SizedBox(width: 140, child: Text("Color")),
        //     const SizedBox(width: 12),
        //     GestureDetector(
        //       onTap: () async {
        //         Color current = _parseHex(_colorHex);
        //         final picked = await showDialog<Color>(
        //           context: context,
        //           builder: (_) => AlertDialog(
        //             title: const Text("Pick color"),
        //             content: SingleChildScrollView(child: BlockPicker(
        //               pickerColor: current,
        //               onColorChanged: (c) => current = c,
        //             )),
        //             actions: [
        //               TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        //               FilledButton(onPressed: () => Navigator.pop(context, current), child: const Text("Select")),
        //             ],
        //           ),
        //         );
        //         if (picked != null) setState(() => _colorHex = _toHex(picked));
        //       },
        //       child: Container(
        //         width: 48, height: 28, decoration: BoxDecoration(
        //           color: _parseHex(_colorHex),
        //           borderRadius: BorderRadius.circular(6),
        //           border: Border.all(color: Colors.black12),
        //         ),
        //       ),
        //     ),
        //     const SizedBox(width: 12),
        //     Expanded(child: Text(_colorHex)),
        //   ]),

        if (_styleUsesColor)
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(width: 140, child: Text("Color")),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () async {
                Color current = _parseHex(_colorHex);
                final picked = await showDialog<Color>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text("Pick color"),
                    content: SingleChildScrollView(
                      child: BlockPicker(
                        pickerColor: current,
                        onColorChanged: (c) => current = c,
                      ),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                      FilledButton(onPressed: () => Navigator.pop(context, current), child: const Text("Select")),
                    ],
                  ),
                );
                if (picked != null) setState(() => _colorHex = _toHex(picked));
              },
              child: Container(
                width: 48, height: 28,
                decoration: BoxDecoration(
                  color: _parseHex(_colorHex),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.black12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(_colorHex)),
          ]),

        if (_usesBlur)
          Row(children: [
            const SizedBox(width: 140, child: Text("Blur amount")),
            const SizedBox(width: 12),
            Expanded(
              child: Slider(
                min: 0, max: 64, divisions: 64,
                value: _blur,
                label: _blur.toStringAsFixed(0),
                onChanged: (v) => setState(() => _blur = v),
              ),
            ),
            SizedBox(
              width: 70,
              child: TextField(
                controller: TextEditingController(text: _blur.toStringAsFixed(0)),
                keyboardType: TextInputType.number,
                onSubmitted: (s) {
                  final v = double.tryParse(s) ?? _blur;
                  setState(() => _blur = v.clamp(0, 64));
                },
              ),
            ),
          ]),

        const SizedBox(height: 24),
        Text("Playback", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),

        // 2.1 Slide duration (seconds)
        Row(children: [
          const SizedBox(width: 140, child: Text("Slide duration (s)")),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              min: 1, max: 120, divisions: 119,
              value: _slideS,
              label: _slideS.toStringAsFixed(0),
              onChanged: (v) => setState(() => _slideS = v),
            ),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              controller: TextEditingController(text: _slideS.toStringAsFixed(0)),
              keyboardType: TextInputType.number,
              onSubmitted: (s) {
                final v = double.tryParse(s) ?? _slideS;
                setState(() => _slideS = v.clamp(1, 120));
              },
            ),
          ),
        ]),

        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Shuffle"),
          value: _shuffle,
          onChanged: (v) => setState(() => _shuffle = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Loop"),
          value: _loop,
          onChanged: (v) => setState(() => _loop = v),
        ),

        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(width: 140, child: Text("Crossfade (ms)")),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              min: 0, max: 3000, divisions: 60,
              value: _crossfadeMs.toDouble(),
              label: _crossfadeMs.toString(),
              onChanged: (v) => setState(() => _crossfadeMs = v.round()),
            ),
          ),
          SizedBox(
            width: 90,
            child: TextField(
              controller: TextEditingController(text: _crossfadeMs.toString()),
              keyboardType: TextInputType.number,
              onSubmitted: (s) {
                final v = int.tryParse(s) ?? _crossfadeMs;
                setState(() => _crossfadeMs = v.clamp(0, 10000));
              },
            ),
          ),
        ]),

        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: saving ? null : _save,
          icon: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
          label: const Text("Save"),
        ),
      ],
    );
  }

  // helpers
  Color _parseHex(String hex) {
    final h = hex.replaceAll("#", "");
    final v = int.parse(h, radix: 16);
    return Color(0xFF000000 | v);
  }
  String _toHex(Color c) {
    final argb = c.toARGB32();          // 0xAARRGGBB
    final rgb  = argb & 0x00FFFFFF;     // strip alpha
    return "#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}";
  }
}


/// ----------------------------------------------------------------------------
/// Selection editor (for already-uploaded grid items; optional stub)
/// ----------------------------------------------------------------------------
class SelectionEditor extends StatefulWidget {
  const SelectionEditor({super.key});
  @override
  State<SelectionEditor> createState() => _SelectionEditorState();
}

class _SelectionEditorState extends State<SelectionEditor> {
  final Set<String> selected = {};
  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);
    final items = state.media;

    return Scaffold(
      appBar: AppBar(
        leading: TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        title: Text("${selected.length} selected"),
        actions: [
          TextButton(
            onPressed: selected.isEmpty ? null : () async {
              await showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (_) => const _SelectionActionsSheet(),
              );
              if (mounted) Navigator.pop(context);
            },
            child: Text("Next", style: TextStyle(color: selected.isEmpty ? Colors.grey : Colors.blue)),
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final m = items[i];
          final isSel = selected.contains(m.id);
          return GestureDetector(
            onTap: () {
              setState(() { isSel ? selected.remove(m.id) : selected.add(m.id); });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: Colors.grey.shade300, child: const Center(child: Icon(Icons.photo, color: Colors.white70))),
                if (isSel)
                  Container(
                    color: Colors.black26,
                    alignment: Alignment.topRight,
                    padding: const EdgeInsets.all(6),
                    child: const Icon(Icons.check_circle, color: Colors.lightBlueAccent),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SelectionActionsSheet extends StatelessWidget {
  const _SelectionActionsSheet();
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: const [
        ListTile(leading: Icon(Icons.slideshow), title: Text("Include in slideshow")),
        ListTile(leading: Icon(Icons.block), title: Text("Exclude from slideshow")),
        ListTile(leading: Icon(Icons.delete_outline), title: Text("Remove from frame")),
        SizedBox(height: 8),
      ]),
    );
  }
}

/// ----------------------------------------------------------------------------
/// Small UI helpers
/// ----------------------------------------------------------------------------
class _ConfirmUploadSheet extends StatelessWidget {
  final int count;
  const _ConfirmUploadSheet({required this.count});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Ready to upload", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text("$count file(s) selected"),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(onPressed: () => Navigator.pop(context, false), icon: const Icon(Icons.close), label: const Text("Cancel")),
              const Spacer(),
              FilledButton.icon(onPressed: () => Navigator.pop(context, true), icon: const Icon(Icons.cloud_upload), label: const Text("Upload")),
            ],
          ),
        ]),
      ),
    );
  }
}

class _ServerCfg { final String base, token; _ServerCfg(this.base, this.token); }

class _ServerConfigDialog extends StatefulWidget {
  final String initialBase, initialToken;
  const _ServerConfigDialog({required this.initialBase, required this.initialToken});
  @override
  State<_ServerConfigDialog> createState() => _ServerConfigDialogState();
}
class _ServerConfigDialogState extends State<_ServerConfigDialog> {
  late final TextEditingController _base = TextEditingController(text: widget.initialBase);
  late final TextEditingController _token = TextEditingController(text: widget.initialToken);
  @override
  void dispose() { _base.dispose(); _token.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Server settings"),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _base, decoration: const InputDecoration(labelText: "Server URL (http://ip:8765)")),
        const SizedBox(height: 8),
        TextField(controller: _token, decoration: const InputDecoration(labelText: "Auth token")),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(onPressed: () => Navigator.pop(context, _ServerCfg(_base.text.trim(), _token.text.trim())), child: const Text("Save")),
      ],
    );
  }
}
Future<void> autoDiscoverAndConnect(
  BuildContext context, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final state = InheritedAppState.of(context);

  // If we already have a working base URL, keep it.
  if (state.serverBase != null) {
    try {
      final ok = await Api(state.serverBase!, state.authToken).ping();
      if (ok) {
        state.setConnection(true);
        return;
      }
    } catch (_) {}
  }

  final discovery = BonsoirDiscovery(type: '_leanframe._tcp');

  // v6: initialize() instead of "ready"
  await discovery.initialize();

  BonsoirService? chosen;

  // v6: type-checked events instead of BonsoirDiscoveryEventType enum
  final sub = discovery.eventStream!.listen((event) {
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      // v6: resolve requires the resolver from the discovery instance
      event.service!.resolve(discovery.serviceResolver);
    } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
      chosen ??= event.service!;
    }
  });

  await discovery.start();
  await Future<void>.delayed(timeout);
  await discovery.stop();
  await sub.cancel();

  if (chosen == null) {
    // Optional fallback to your known mDNS hostname
    final guess = 'http://radxa-zero3.local:8765';
    await _trySetBase(context, guess);
    return;
  }

  // v6: no "ip" getter; use addresses/host/port
  final Map<String, dynamic> j = chosen!.toJson();
  final List addrs = (j['addresses'] as List?) ?? const [];
  final String host = addrs.isNotEmpty ? addrs.first as String : (chosen!.host ?? '');
  final int port = chosen!.port ?? 8765;
  if (host.isEmpty) return;

  final base = 'http://$host:$port';
  await _trySetBase(context, base);
}

Future<bool> _trySetBase(BuildContext context, String base) async {
  final state = InheritedAppState.of(context);
  try {
    final res = await http
        .get(Uri.parse('$base/config/runtime'),
             headers: {'X-Auth-Token': state.authToken})
        .timeout(const Duration(seconds: 3));
    if (res.statusCode == 200) {
      state.setServer(base: base, token: state.authToken);
      state.setConnection(true);
      return true;
    }
  } catch (_) {}
  return false;
}


Future<String?> _promptForText(BuildContext context, String title, String initial) async {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text("Save")),
      ],
    ),
  );
}
