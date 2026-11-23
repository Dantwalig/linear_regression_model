import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

// Public address of the deployed API on Render (no slash at the end)
const String apiBaseUrl = 'https://anaemia-risk-api.onrender.com';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Let the gradient header run under the status bar, with light icons
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const AnaemiaApp());
}

// "Pomegranate and saffron": warm colours that echo blood and the sun, and no blue anywhere
class Palette {
  static const cream = Color(0xFFFFF4E6);
  static const card = Color(0xFFFFFBF5);
  static const border = Color(0xFFF0D9BE);
  static const cocoa = Color(0xFF2D1B14);
  static const cocoaSoft = Color(0xFF7B6558);
  static const hint = Color(0xFFB9A595);
  static const pomegranate = Color(0xFF9E1B32);
  static const pomegranateDeep = Color(0xFF6E0F26);
  static const wine = Color(0xFF7A0E26);
  static const apricot = Color(0xFFF08A3C);
  static const saffron = Color(0xFFFFB627);
  static const terracotta = Color(0xFFC4552D);
  static const raspberry = Color(0xFFC2185B);
  static const olive = Color(0xFF6B8F23);
}

class AnaemiaApp extends StatelessWidget {
  const AnaemiaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anaemia Risk Estimator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Palette.pomegranate),
        scaffoldBackgroundColor: Palette.cream,
      ),
      home: const PredictPage(),
    );
  }
}

// The model inputs: name in the API, label, note for the nurse, allowed range

class FieldSpec {
  final String key;
  final String label;
  final String note;
  final String hint;
  final num min;
  final num max;
  final bool isInt;
  final IconData icon;

  const FieldSpec({
    required this.key,
    required this.label,
    required this.note,
    required this.hint,
    required this.min,
    required this.max,
    required this.icon,
    this.isInt = true,
  });
}

// A yes or no sign: the nurse types 1 for yes or 0 for no
FieldSpec yesNo(String key, String label, IconData icon) => FieldSpec(
  key: key,
  label: label,
  note: '1 = yes, 0 = no',
  hint: '0 or 1',
  min: 0,
  max: 1,
  icon: icon,
);

class SectionSpec {
  final String title;
  final IconData icon;
  final Color color;
  final List<FieldSpec> fields;

  const SectionSpec({
    required this.title,
    required this.icon,
    required this.color,
    required this.fields,
  });
}

// The 18 inputs, grouped so the form is easy to scan. Names and ranges match the API.
final List<SectionSpec> sections = [
  SectionSpec(
    title: 'About the child',
    icon: Icons.child_care,
    color: Palette.pomegranate,
    fields: [
      FieldSpec(
        key: 'sex',
        label: 'Sex',
        note: '1 = male, 0 = female',
        hint: '0 or 1',
        min: 0,
        max: 1,
        icon: Icons.wc,
      ),
      FieldSpec(
        key: 'age_months',
        label: 'Age in months',
        note: 'Between 2 and 180',
        hint: '2 to 180',
        min: 2,
        max: 180,
        icon: Icons.cake,
        isInt: false,
      ),
    ],
  ),
  SectionSpec(
    title: 'Look and feel',
    icon: Icons.visibility,
    color: Color(0xFFD98A00),
    fields: [
      yesNo('pallor', 'Pallor (pale palms or lips)', Icons.water_drop),
      yesNo('jaundice', 'Jaundice', Icons.wb_sunny),
      yesNo('dehydration', 'Dehydration', Icons.local_drink),
      yesNo('coma', 'Coma', Icons.bedtime),
      yesNo('waz_low', 'Low weight for age', Icons.scale),
      yesNo('muac2', 'Arm circumference 11.5 cm or less', Icons.straighten),
    ],
  ),
  SectionSpec(
    title: 'Breathing and temperature',
    icon: Icons.air,
    color: Palette.terracotta,
    fields: [
      yesNo('indrawing', 'Chest indrawing', Icons.compress),
      yesNo('resp_deep', 'Deep breathing', Icons.air),
      yesNo('fever_high', 'High fever', Icons.thermostat),
      yesNo(
        'temp_gradient',
        'Temperature gradient between limbs',
        Icons.device_thermostat,
      ),
      yesNo('oxysat_cat', 'Oxygen saturation below 90 percent', Icons.sensors),
    ],
  ),
  SectionSpec(
    title: 'Heart and circulation',
    icon: Icons.favorite,
    color: Palette.raspberry,
    fields: [
      yesNo('tachyc', 'Fast heart rate', Icons.favorite),
      yesNo('refill3', 'Capillary refill over 3 seconds', Icons.timer),
      yesNo('pulse_vol_weak', 'Weak pulse', Icons.graphic_eq),
      yesNo('shock', 'Shock', Icons.bolt),
    ],
  ),
  SectionSpec(
    title: 'Rapid test',
    icon: Icons.biotech,
    color: Palette.olive,
    fields: [
      yesNo('mal_par', 'Malaria parasites on rapid test', Icons.bug_report),
    ],
  ),
];

// All 18 fields in one list, used to build controllers and to validate
final List<FieldSpec> allFields = [for (final s in sections) ...s.fields];

// WHO style cut offs by age, used only for the colour band (a screening hint)

double cutOffFor(double ageMonths) =>
    ageMonths < 60 ? 11.0 : (ageMonths < 144 ? 11.5 : 12.0);

double severeFor(double ageMonths) => ageMonths < 60 ? 7.0 : 8.0;

class Band {
  final String text;
  final Color color;
  const Band(this.text, this.color);
}

Band bandFor(double hb, double ageMonths) {
  if (hb < severeFor(ageMonths)) {
    return const Band('Severe anaemia range: refer urgently', Palette.wine);
  }
  if (hb < cutOffFor(ageMonths)) {
    return const Band('Anaemia range: mild or moderate', Palette.terracotta);
  }
  return const Band('Above the anaemia cut off', Palette.olive);
}

// The page

class PredictPage extends StatefulWidget {
  const PredictPage({super.key});

  @override
  State<PredictPage> createState() => _PredictPageState();
}

class _PredictPageState extends State<PredictPage> {
  final Map<String, TextEditingController> _controllers = {
    for (final f in allFields) f.key: TextEditingController(),
  };
  bool _loading = false;
  double? _hb; // the predicted haemoglobin, when there is one
  double _age = 0; // the age that was sent, used for the colour band
  String? _error; // the error message shown in the display area
  String? _badKey; // the field to highlight in red

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Checks every field. Returns (field key, message) for the first problem, or null.
  MapEntry<String, String>? _validate(Map<String, dynamic> payload) {
    for (final f in allFields) {
      final text = _controllers[f.key]!.text.trim();
      if (text.isEmpty) {
        return MapEntry(f.key, 'Missing value: ${f.label}');
      }
      final num? value = f.isInt ? int.tryParse(text) : double.tryParse(text);
      if (value == null) {
        return MapEntry(
          f.key,
          'Wrong type: ${f.label} must be ${f.isInt ? 'a whole number' : 'a number'}',
        );
      }
      if (value < f.min || value > f.max) {
        return MapEntry(
          f.key,
          'Out of range: ${f.label} must be between ${f.min} and ${f.max}',
        );
      }
      payload[f.key] = value;
    }
    return null;
  }

  // Turns the API's validation reply (HTTP 422) into one readable sentence
  ({String message, String? key}) _readValidationError(String body) {
    try {
      final detail = jsonDecode(body)['detail'];
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        final field = (first['loc'] as List).last.toString();
        return (
          message: 'Invalid input for $field: ${first['msg']}',
          key: field,
        );
      }
    } catch (_) {}
    return (
      message:
          'Some values were rejected by the server. Please check every field.',
      key: null,
    );
  }

  Future<void> _predict() async {
    FocusScope.of(context).unfocus();

    final payload = <String, dynamic>{};
    final problem = _validate(payload);
    if (problem != null) {
      setState(() {
        _hb = null;
        _error = problem.value;
        _badKey = problem.key;
      });
      return;
    }

    setState(() {
      _loading = true;
      _hb = null;
      _error = null;
      _badKey = null;
    });

    try {
      // This is the call to the public /predict endpoint on Render
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/predict'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 70));

      if (!mounted) return;
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        setState(() {
          _hb = (body['predicted_hb'] as num).toDouble();
          _age = (payload['age_months'] as num).toDouble();
        });
      } else if (response.statusCode == 422) {
        final parsed = _readValidationError(response.body);
        setState(() {
          _error = parsed.message;
          _badKey = parsed.key;
        });
      } else {
        setState(
          () => _error =
              'The server returned an error (${response.statusCode}). Please try again.',
        );
      }
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _error = 'The server took too long to answer. It may be waking up, so try again in a minute.',
        );
      }
    } on SocketException {
      if (mounted) {
        setState(
          () => _error = 'Could not reach the server. Check your internet connection and try again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not reach the server. Check your internet connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // The display area: idle hint, loading, error, or the result with its gauge
  Widget _buildDisplay() {
    if (_loading) {
      return _DisplayShell(
        key: const ValueKey('loading'),
        color: Palette.cream,
        borderColor: Palette.border,
        child: const Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Palette.pomegranate,
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                'Contacting the server. The first request can take up to a minute.',
                style: TextStyle(color: Palette.cocoa, fontSize: 14),
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return _DisplayShell(
        key: const ValueKey('error'),
        color: Palette.terracotta.withValues(alpha: 0.12),
        borderColor: Palette.terracotta,
        child: Row(
          children: [
            const Icon(
              Icons.error_outline,
              color: Palette.terracotta,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(
                  color: Palette.cocoa,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final hb = _hb;
    if (hb != null) {
      final band = bandFor(hb, _age);
      return _DisplayShell(
        key: ValueKey('result-$hb'),
        color: Palette.card,
        borderColor: band.color,
        child: Row(
          children: [
            SizedBox(
              width: 132,
              height: 78,
              // The needle sweeps from 0 up to the predicted value
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: hb),
                duration: const Duration(milliseconds: 1000),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => CustomPaint(
                  painter: GaugePainter(
                    value: value,
                    severe: severeFor(_age),
                    cutOff: cutOffFor(_age),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Estimated haemoglobin',
                    style: TextStyle(
                      fontSize: 12,
                      color: Palette.cocoaSoft,
                      letterSpacing: 0.3,
                    ),
                  ),
                  Text(
                    '${hb.toStringAsFixed(2)} g/dL',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Palette.cocoa,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: band.color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      band.text,
                      maxLines: 2,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return const _DisplayShell(
      key: ValueKey('idle'),
      color: Palette.cream,
      borderColor: Palette.border,
      child: Row(
        children: [
          Icon(Icons.touch_app, color: Palette.apricot, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Fill in all 18 fields, then press Predict.',
              style: TextStyle(color: Palette.cocoa, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.cream,
      body: Column(
        children: [
          // The scrolling form: header, then one card per group of fields
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                const _Header(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                  child: Column(
                    children: [
                      for (final s in sections) ...[
                        _SectionCard(
                          spec: s,
                          controllers: _controllers,
                          badKey: _badKey,
                        ),
                        const SizedBox(height: 16),
                      ],
                      const Text(
                        'A screening aid, not a diagnosis. A blood test confirms anaemia.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Palette.cocoaSoft,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The pinned bottom panel: display area and the Predict button
          Container(
            decoration: BoxDecoration(
              color: Palette.card,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              boxShadow: [
                BoxShadow(
                  color: Palette.pomegranate.withValues(alpha: 0.18),
                  blurRadius: 22,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    switchInCurve: Curves.easeOut,
                    child: _buildDisplay(),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _predict,
                      style: FilledButton.styleFrom(
                        backgroundColor: Palette.pomegranate,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Palette.pomegranate.withValues(
                          alpha: 0.45,
                        ),
                        disabledForegroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 20),
                      label: const Text('Predict'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Small building blocks

// The rounded box that holds whatever the display area shows
class _DisplayShell extends StatelessWidget {
  final Color color;
  final Color borderColor;
  final Widget child;

  const _DisplayShell({
    super.key,
    required this.color,
    required this.borderColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 102),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }
}

// The gradient header with soft decorative circles
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Palette.pomegranateDeep,
            Palette.pomegranate,
            Palette.apricot,
          ],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(36),
          bottomRight: Radius.circular(36),
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -34,
            top: -28,
            child: _Bubble(
              size: 150,
              color: Palette.saffron.withValues(alpha: 0.30),
            ),
          ),
          Positioned(
            right: 58,
            bottom: -34,
            child: _Bubble(
              size: 96,
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          Positioned(
            left: -26,
            bottom: 24,
            child: _Bubble(
              size: 70,
              color: Palette.saffron.withValues(alpha: 0.18),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.water_drop,
                      color: Palette.pomegranate,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Bedside Anaemia\nRisk Estimator',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Estimate a child\'s haemoglobin from signs you can see, with no lab needed.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.88),
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Pill(text: '18 bedside signs', icon: Icons.checklist),
                      _Pill(text: 'Instant estimate', icon: Icons.bolt),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final double size;
  final Color color;

  const _Bubble({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData icon;

  const _Pill({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Palette.saffron, size: 16),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// One card per group of fields
class _SectionCard extends StatelessWidget {
  final SectionSpec spec;
  final Map<String, TextEditingController> controllers;
  final String? badKey;

  const _SectionCard({
    required this.spec,
    required this.controllers,
    required this.badKey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: Palette.card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Palette.border),
        boxShadow: [
          BoxShadow(
            color: Palette.pomegranate.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 24,
                decoration: BoxDecoration(
                  color: spec.color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                spec.title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Palette.cocoa,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < spec.fields.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Palette.border),
            _FieldRow(
              spec: spec.fields[i],
              accent: spec.color,
              controller: controllers[spec.fields[i].key]!,
              hasError: badKey == spec.fields[i].key,
            ),
          ],
        ],
      ),
    );
  }
}

// One labelled text field: icon and label on the left, the input box on the right
class _FieldRow extends StatelessWidget {
  final FieldSpec spec;
  final Color accent;
  final TextEditingController controller;
  final bool hasError;

  const _FieldRow({
    required this.spec,
    required this.accent,
    required this.controller,
    required this.hasError,
  });

  @override
  Widget build(BuildContext context) {
    final normalBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: hasError ? Palette.terracotta : Palette.border,
        width: hasError ? 1.8 : 1,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(spec.icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.label,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Palette.cocoa,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  spec.note,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Palette.cocoaSoft,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 84,
            child: TextField(
              controller: controller,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              cursorColor: accent,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Palette.cocoa,
              ),
              decoration: InputDecoration(
                hintText: spec.hint,
                hintStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Palette.hint,
                ),
                isDense: true,
                filled: true,
                fillColor: hasError
                    ? Palette.terracotta.withValues(alpha: 0.12)
                    : Palette.cream,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 6,
                ),
                border: normalBorder,
                enabledBorder: normalBorder,
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: accent, width: 2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// The gauge: three coloured zones and a needle that points at the estimate

class GaugePainter extends CustomPainter {
  final double value;
  final double severe;
  final double cutOff;

  const GaugePainter({
    required this.value,
    required this.severe,
    required this.cutOff,
  });

  static const double maxValue = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 6);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // A haemoglobin value becomes an angle on the top half of a circle
    double angleFor(double v) => math.pi + math.pi * (v / maxValue);

    void zone(double from, double to, Color color) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = color;
      canvas.drawArc(
        rect,
        angleFor(from),
        angleFor(to) - angleFor(from),
        false,
        paint,
      );
    }

    zone(0, severe, Palette.wine);
    zone(severe, cutOff, Palette.apricot);
    zone(cutOff, maxValue, Palette.olive);

    // The needle
    final angle = angleFor(value.clamp(0.0, maxValue));
    final tip = Offset(
      center.dx + (radius - 20) * math.cos(angle),
      center.dy + (radius - 20) * math.sin(angle),
    );
    final needle = Paint()
      ..color = Palette.cocoa
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, needle);
    canvas.drawCircle(center, 7, Paint()..color = Palette.cocoa);
    canvas.drawCircle(center, 3, Paint()..color = Palette.saffron);
  }

  @override
  bool shouldRepaint(GaugePainter old) =>
      old.value != value || old.severe != severe || old.cutOff != cutOff;
}
