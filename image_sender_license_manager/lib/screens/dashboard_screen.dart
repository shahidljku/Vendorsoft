import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'history_screen.dart';
import '../services/license_generator_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _formKey = GlobalKey<FormState>();
  final _deviceIdController = TextEditingController();
  final _customerNameController = TextEditingController();

  String _customerType = 'Demo';
  DateTime? _customExpiryDate;

  String? _generatedLicense;
  bool _isGenerating = false;

  final List<String> _customerTypes = ['Demo', 'Lifetime', 'Custom'];

  void _generateLicense() async {
    if (!_formKey.currentState!.validate()) return;

    if (_customerType == 'Custom' && _customExpiryDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an expiry date for Custom type'),
        ),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _generatedLicense = null;
    });

    DateTime? expiry;
    if (_customerType == 'Demo') {
      expiry = DateTime.now().add(const Duration(days: 30));
    } else if (_customerType == 'Custom') {
      expiry = _customExpiryDate;
    } // Lifetime stays null

    try {
      final license = await LicenseGeneratorService().generateLicense(
        deviceId: _deviceIdController.text,
        customerName: _customerNameController.text,
        customerType: _customerType,
        expiryDate: expiry,
      );

      setState(() {
        _generatedLicense = license;
        _isGenerating = false;
      });
    } catch (e) {
      setState(() {
        _isGenerating = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating license: \$e')),
        );
      }
    }
  }

  void _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime(2050),
    );
    if (picked != null) {
      setState(() {
        _customExpiryDate = picked;
      });
    }
  }

  void _copyLicense() {
    if (_generatedLicense != null) {
      Clipboard.setData(ClipboardData(text: _generatedLicense!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('License copied to clipboard')),
      );
    }
  }

  @override
  void dispose() {
    _deviceIdController.dispose();
    _customerNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DateFormat formatter = DateFormat('dd MMM yyyy');

    return Scaffold(
      appBar: AppBar(
        title: const Text('License Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const HistoryScreen()),
              );
            },
            tooltip: 'History',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Generate New License',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _deviceIdController,
                            decoration: const InputDecoration(
                              labelText: 'Device ID',
                              prefixIcon: Icon(Icons.phone_android),
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? 'Required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _customerNameController,
                            decoration: const InputDecoration(
                              labelText: 'Customer Name',
                              prefixIcon: Icon(Icons.person),
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? 'Required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            initialValue: _customerType,
                            decoration: const InputDecoration(
                              labelText: 'Customer Type',
                              prefixIcon: Icon(Icons.category),
                              border: OutlineInputBorder(),
                            ),
                            items: _customerTypes.map((type) {
                              return DropdownMenuItem(
                                value: type,
                                child: Text(type),
                              );
                            }).toList(),
                            onChanged: (val) {
                              setState(() {
                                _customerType = val!;
                                if (_customerType != 'Custom') {
                                  _customExpiryDate = null;
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 16),
                          if (_customerType == 'Custom') ...[
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Expiry Date'),
                              subtitle: Text(
                                _customExpiryDate == null
                                    ? 'Not selected'
                                    : formatter.format(_customExpiryDate!),
                              ),
                              trailing: ElevatedButton(
                                onPressed: _selectDate,
                                child: const Text('Select Date'),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (_customerType == 'Demo') ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8.0),
                              child: Text(
                                'Demo licenses expire automatically 30 days from today.',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _isGenerating
                                  ? null
                                  : _generateLicense,
                              icon: _isGenerating
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.generating_tokens),
                              label: Text(
                                _isGenerating
                                    ? 'Generating...'
                                    : 'Generate License',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_generatedLicense != null) ...[
                    const SizedBox(height: 24),
                    Card(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Generated License Key',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy),
                                  onPressed: _copyLicense,
                                  tooltip: 'Copy to Clipboard',
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: SelectableText(
                                _generatedLicense!,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
