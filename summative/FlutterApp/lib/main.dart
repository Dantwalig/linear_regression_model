import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Public address of the deployed API on Render (no slash at the end)
const String apiBaseUrl = 'https://anaemia-risk-api.onrender.com';

void main() => runApp(const AnaemiaApp());

class AnaemiaApp extends StatelessWidget {
  const AnaemiaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anaemia Risk Estimator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const PredictPage(),
    );
  }
}

// One input of the model: its name in the API, the label the nurse sees, and its allowed range
class FieldSpec {
  final String key;
  final String label;
  final String hint;
  final num min;
  final num max;
  final bool isInt;

  const FieldSpec(
    this.key,
    this.label,
    this.hint,
    this.min,
    this.max, {
    this.isInt = true,
  });
}

// A yes or no sign: the nurse types 1 for yes or 0 for no
FieldSpec yesNo(String key, String label) =>
    FieldSpec(key, '$label (1 = yes, 0 = no)', '0 or 1', 0, 1);

// The 18 inputs, in the same order and with the same ranges as the API
final List<FieldSpec> fieldSpecs = [
  FieldSpec('sex', 'Sex (1 = male, 0 = female)', '0 or 1', 0, 1),
  yesNo('temp_gradient', 'Temperature gradient between limbs'),
  yesNo('pallor', 'Pallor'),
  yesNo('indrawing', 'Chest indrawing'),
  yesNo('resp_deep', 'Deep breathing'),
  FieldSpec(
    'age_months',
    'Age in months (2 to 180)',
    '2 to 180',
    2,
    180,
    isInt: false,
  ),
  yesNo('fever_high', 'High fever'),
  yesNo('waz_low', 'Low weight for age'),
  yesNo('tachyc', 'Fast heart rate'),
  yesNo('refill3', 'Capillary refill longer than 3 seconds'),
  yesNo('pulse_vol_weak', 'Weak pulse'),
  yesNo('shock', 'Shock'),
  yesNo('mal_par', 'Malaria parasites on rapid test'),
  yesNo('muac2', 'Arm circumference 11.5 cm or less'),
  yesNo('dehydration', 'Dehydration'),
  yesNo('oxysat_cat', 'Oxygen saturation below 90 percent'),
  yesNo('jaundice', 'Jaundice'),
  yesNo('coma', 'Coma'),
];

class PredictPage extends StatefulWidget {
  const PredictPage({super.key});

  @override
  State<PredictPage> createState() => _PredictPageState();
}

class _PredictPageState extends State<PredictPage> {
  final Map<String, TextEditingController> _controllers = {
    for (final f in fieldSpecs) f.key: TextEditingController(),
  };
  bool _loading = false;
  String? _result;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Checks every field. Returns an error message, or null when all values are fine.
  String? _buildPayload(Map<String, dynamic> payload) {
    for (final f in fieldSpecs) {
      final text = _controllers[f.key]!.text.trim();
      if (text.isEmpty) {
        return 'Missing value: ${f.label}';
      }
      final num? value = f.isInt ? int.tryParse(text) : double.tryParse(text);
      if (value == null) {
        return 'Wrong type: ${f.label} must be ${f.isInt ? 'a whole number' : 'a number'}';
      }
      if (value < f.min || value > f.max) {
        return 'Out of range: ${f.label} must be between ${f.min} and ${f.max}';
      }
      payload[f.key] = value;
    }
    return null;
  }

  // Turns the API's validation reply (HTTP 422) into one readable sentence
  String _readValidationError(String body) {
    try {
      final detail = jsonDecode(body)['detail'];
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        final field = (first['loc'] as List).last;
        return 'Invalid input for $field: ${first['msg']}';
      }
    } catch (_) {}
    return 'Some values were rejected by the server. Please check every field.';
  }

  Future<void> _predict() async {
    FocusScope.of(context).unfocus();

    final payload = <String, dynamic>{};
    final problem = _buildPayload(payload);
    if (problem != null) {
      setState(() {
        _result = null;
        _error = problem;
      });
      return;
    }

    setState(() {
      _loading = true;
      _result = null;
      _error = null;
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
        final hb = (body['predicted_hb'] as num).toStringAsFixed(2);
        setState(() => _result = 'Estimated haemoglobin: $hb g/dL');
      } else if (response.statusCode == 422) {
        setState(() => _error = _readValidationError(response.body));
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

  // The display area: shows the prediction, an error, or a hint
  Widget _buildDisplay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color background = Colors.grey.shade200;
    Widget content = const Text('Fill in every field, then press Predict.');

    if (_loading) {
      content = const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Contacting the server. The first request can take up to a minute.',
            ),
          ),
        ],
      );
    } else if (_error != null) {
      background = scheme.errorContainer;
      content = Text(
        _error!,
        style: TextStyle(
          color: scheme.onErrorContainer,
          fontWeight: FontWeight.w600,
        ),
      );
    } else if (_result != null) {
      background = scheme.primaryContainer;
      content = Text(
        _result!,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bedside Anaemia Risk Estimator')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: fieldSpecs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final f = fieldSpecs[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.label,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _controllers[f.key],
                        keyboardType: TextInputType.numberWithOptions(
                          decimal: !f.isInt,
                        ),
                        decoration: InputDecoration(
                          hintText: f.hint,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: const [
                  BoxShadow(blurRadius: 6, color: Colors.black26),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDisplay(context),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: _loading ? null : _predict,
                      child: const Text('Predict'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
