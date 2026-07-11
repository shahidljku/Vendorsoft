import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../services/settings_service.dart';
import '../services/file_access_service.dart';
import '../services/log_service.dart';

class LogsTab extends StatefulWidget {
  final SettingsService settingsService;
  
  const LogsTab({super.key, required this.settingsService});

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  List<String> _logLines = [];
  bool _isLoading = true;
  bool _logsEnabled = true;
  String _logFilter = 'All';

  @override
  void initState() {
    super.initState();
    _loadLogs();
    LogService().addListener(_onLogUpdated);
    widget.settingsService.addListener(_onSettingsUpdated);
  }

  void _onSettingsUpdated() {
    if (mounted) {
      _loadLogs();
    }
  }

  void _onLogUpdated() {
    if (mounted) {
      setState(() {
        _isLoading = true;
      });
      _loadLogs();
    }
  }

  @override
  void dispose() {
    LogService().removeListener(_onLogUpdated);
    widget.settingsService.removeListener(_onSettingsUpdated);
    super.dispose();
  }

  Future<void> _loadLogs() async {
    try {
      bool enabled = await widget.settingsService.getEnableLogs();
      if (mounted) {
        setState(() {
          _logsEnabled = enabled;
        });
      }
      
      if (!enabled) {
        if (mounted) {
          setState(() {
            _logLines = [];
            _isLoading = false;
          });
        }
        return;
      }

      final directory = await getApplicationDocumentsDirectory();
      final logFile = File('${directory.path}/VendSoft/logs.txt');
      
      if (await logFile.exists()) {
        final lines = await logFile.readAsLines();
        setState(() {
          _logLines = lines.reversed.toList(); // Newest first
          _isLoading = false;
        });
      } else {
        setState(() {
          _logLines = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _logLines = [];
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Logs',
            onPressed: () {
              setState(() {
                _isLoading = true;
              });
              _loadLogs();
            },
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download Logs',
            onPressed: () async {
              if (_logLines.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No logs to download.')));
                return;
              }
              String content = _logLines.join('\n');
              String? uri = await FileAccessService.exportLogFile(content);
              if (context.mounted) {
                if (uri != null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs saved successfully.')));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs download cancelled or failed.')));
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear Logs',
            onPressed: () async {
              final directory = await getApplicationDocumentsDirectory();
              final logFile = File('${directory.path}/VendSoft/logs.txt');
              if (await logFile.exists()) {
                await logFile.delete();
                if (context.mounted) {
                  setState(() {
                    _logLines = [];
                  });
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs cleared')));
                }
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_alt_outlined),
            tooltip: 'Filter Logs',
            color: const Color(0xFF161B22),
            onSelected: (String result) {
              setState(() {
                _logFilter = result;
              });
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'All',
                child: Text('All Logs', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem<String>(
                value: 'Info',
                child: Text('Info Only', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem<String>(
                value: 'Error',
                child: Text('Errors Only', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : !_logsEnabled
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.event_busy, size: 64, color: Colors.grey.withValues(alpha: 0.5)),
                      const SizedBox(height: 16),
                      const Text('Logs are currently disabled', style: TextStyle(fontSize: 18, color: Colors.white)),
                      const SizedBox(height: 8),
                      const Text('Go to Settings to enable logging', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Builder(
                builder: (context) {
                  List<String> filteredLogs = _logLines;
                  if (_logFilter == 'Info') {
                    filteredLogs = _logLines.where((line) => !line.toLowerCase().contains('failed') && !line.toLowerCase().contains('error')).toList();
                  } else if (_logFilter == 'Error') {
                    filteredLogs = _logLines.where((line) => line.toLowerCase().contains('failed') || line.toLowerCase().contains('error')).toList();
                  }
                  
                  if (filteredLogs.isEmpty) {
                    return const Center(child: Text('No logs found for this filter.', style: TextStyle(color: Colors.grey)));
                  }
                  
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      return _buildLogItem(filteredLogs[index]);
                    },
                  );
                },
              ),
            ),
    );
  }

  Widget _buildLogItem(String logLine) {
    // Expected format: DateTime | mobile | status
    final parts = logLine.split(' | ');
    if (parts.length < 3) return const SizedBox();

    final dateTimeStr = parts[0];
    final mobile = parts[1];
    final status = parts[2];

    DateTime? date = DateTime.tryParse(dateTimeStr);
    String timeStr = date != null ? DateFormat('hh:mm:ss a').format(date) : dateTimeStr;

    bool isSuccess = status.toLowerCase().contains('sent') || status.toLowerCase().contains('success');
    Color iconColor = isSuccess ? const Color(0xFF00E676) : Colors.red;
    IconData leadingIcon = isSuccess ? Icons.send : Icons.error;
    IconData trailingIcon = isSuccess ? Icons.check_circle_outline : Icons.cancel_outlined;

    String displayStatus = isSuccess ? 'Message sent successfully' : 'Failed to send ($status)';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(leadingIcon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(timeStr, style: TextStyle(color: Colors.grey.withValues(alpha: 0.8), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(displayStatus, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(mobile, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            Icon(trailingIcon, color: iconColor),
          ],
        ),
      ),
    );
  }
}
