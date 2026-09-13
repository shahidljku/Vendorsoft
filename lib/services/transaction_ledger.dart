import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/bill_transaction.dart';
import '../models/customer.dart';
import 'log_service.dart';

/// Thread-safe, atomic file-backed ledger for bill transactions.
///
/// Guarantees:
/// 1. Crash-safety: Every write is atomic via .tmp -> rename.
/// 2. Quarantine: Any transaction left in IN_FLIGHT on startup becomes UNCERTAIN.
/// 3. Idempotency: Confirmed and Uncertain bills cannot be automatically re-sent.
class TransactionLedger {
  static final TransactionLedger _instance = TransactionLedger._internal();
  factory TransactionLedger() => _instance;
  TransactionLedger._internal();

  static const String _fileName = 'transaction_ledger.json';
  final Map<String, BillTransaction> _transactions = {};
  bool _initialized = false;
  File? _ledgerFile;
  final LogService _log = LogService();

  /// Simple sequential lock queue to prevent race conditions during disk writes.
  Future<void> _lock = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final prev = _lock;
    final completer = Completer<T>();
    _lock = prev.then((_) => action()).then((result) {
      completer.complete(result);
    }).catchError((error, stackTrace) {
      completer.completeError(error, stackTrace);
    });
    return completer.future;
  }

  /// Initializes the ledger from disk and runs the startup quarantine pass.
  Future<void> initialize() async {
    if (_initialized) return;

    await _synchronized(() async {
      final dir = await getApplicationDocumentsDirectory();
      _ledgerFile = File('${dir.path}/$_fileName');

      if (await _ledgerFile!.exists()) {
        try {
          final content = await _ledgerFile!.readAsString();
          if (content.trim().isNotEmpty) {
            final dynamic parsed = jsonDecode(content);
            if (parsed is List) {
              for (final item in parsed) {
                if (item is Map<String, dynamic>) {
                  final tx = BillTransaction.fromJson(item);
                  _transactions[tx.transactionId] = tx;
                }
              }
            }
          }
        } catch (e) {
          await _log.writeLog("LEDGER", "Error reading ledger file: $e");
        }
      }

      // Startup Quarantine Rule:
      // Any transaction left IN_FLIGHT was interrupted by app kill, crash, or OS LMK.
      // It must be quarantined to UNCERTAIN so it is never blindly re-sent.
      bool quarantineChanged = false;
      for (final txId in _transactions.keys.toList()) {
        final tx = _transactions[txId]!;
        if (tx.status == BillTransactionStatus.inFlight) {
          _transactions[txId] = tx.copyWith(
            status: BillTransactionStatus.uncertain,
            diagnosticNote:
                'Quarantined on startup: process died while transaction was IN_FLIGHT',
          );
          quarantineChanged = true;
          await _log.writeLog(
            tx.phoneNumber,
            'QUARANTINED -> UNCERTAIN (app process died mid-flight)',
          );
        }
      }

      if (quarantineChanged) {
        await _saveToDiskAtomic();
      }

      _initialized = true;
    });
  }

  /// Creates and stages a new transaction for a customer bill.
  Future<BillTransaction> stageTransaction({
    required Customer customer,
    required String billId,
    required String billingPeriod,
  }) async {
    await initialize();

    return _synchronized(() async {
      final txId = 'tx_${customer.custNo}_${billId}_${DateTime.now().millisecondsSinceEpoch}';

      final tx = await BillTransaction.create(
        transactionId: txId,
        customerId: customer.custNo,
        customerName: customer.custName,
        phoneNumber: customer.mobile,
        billId: billId,
        billingPeriod: billingPeriod,
        imagePath: customer.resolvedImagePath,
      );

      _transactions[tx.transactionId] = tx;
      await _saveToDiskAtomic();
      return tx;
    });
  }

  /// Transitions transaction to IN_FLIGHT before launching WhatsApp.
  Future<void> markInFlight(String transactionId) async {
    await initialize();

    await _synchronized(() async {
      final tx = _transactions[transactionId];
      if (tx == null) return;

      _transactions[transactionId] = tx.copyWith(
        status: BillTransactionStatus.inFlight,
        attemptCount: tx.attemptCount,
      );
      await _saveToDiskAtomic();
    });
  }

  /// Transitions transaction to CONFIRMED. Irreversible state.
  Future<void> markConfirmed(
    String transactionId, {
    String? diagnosticNote,
  }) async {
    await initialize();

    await _synchronized(() async {
      final tx = _transactions[transactionId];
      if (tx == null) return;

      _transactions[transactionId] = tx.copyWith(
        status: BillTransactionStatus.confirmed,
        diagnosticNote: diagnosticNote ?? 'Verified delivered in Conversation',
      );
      await _saveToDiskAtomic();
    });
  }

  /// Transitions transaction to FAILED. Safe to retry manually.
  Future<void> markFailed(
    String transactionId, {
    required String error,
  }) async {
    await initialize();

    await _synchronized(() async {
      final tx = _transactions[transactionId];
      if (tx == null) return;

      _transactions[transactionId] = tx.copyWith(
        status: BillTransactionStatus.failed,
        lastError: error,
      );
      await _saveToDiskAtomic();
    });
  }

  /// Transitions transaction to UNCERTAIN. Locked state; never auto-resent.
  Future<void> markUncertain(
    String transactionId, {
    required String reason,
  }) async {
    await initialize();

    await _synchronized(() async {
      final tx = _transactions[transactionId];
      if (tx == null) return;

      _transactions[transactionId] = tx.copyWith(
        status: BillTransactionStatus.uncertain,
        diagnosticNote: reason,
      );
      await _saveToDiskAtomic();
    });
  }

  /// Checks whether a customer's bill for this billing period is already confirmed.
  bool isBillConfirmed(String customerId, String billId, String billingPeriod) {
    return _transactions.values.any(
      (tx) =>
          tx.customerId == customerId &&
          tx.billId == billId &&
          tx.billingPeriod == billingPeriod &&
          tx.status == BillTransactionStatus.confirmed,
    );
  }

  /// Checks whether a customer's bill is in an uncertain state.
  bool isBillUncertain(String customerId, String billId, String billingPeriod) {
    return _transactions.values.any(
      (tx) =>
          tx.customerId == customerId &&
          tx.billId == billId &&
          tx.billingPeriod == billingPeriod &&
          tx.status == BillTransactionStatus.uncertain,
    );
  }

  /// Retrieves a transaction by its unique ID.
  BillTransaction? getTransaction(String transactionId) {
    return _transactions[transactionId];
  }

  /// Returns all stored transactions.
  List<BillTransaction> getAllTransactions() {
    return _transactions.values.toList();
  }

  /// Returns transactions filtered by status.
  List<BillTransaction> getTransactionsByStatus(BillTransactionStatus status) {
    return _transactions.values.where((tx) => tx.status == status).toList();
  }

  /// Counts transactions by status.
  int countByStatus(BillTransactionStatus status) {
    return _transactions.values.where((tx) => tx.status == status).length;
  }

  /// Atomic persistence: writes to .tmp file then renames over destination.
  Future<void> _saveToDiskAtomic() async {
    if (_ledgerFile == null) return;

    final tempFile = File('${_ledgerFile!.path}.tmp');
    final jsonList = _transactions.values.map((t) => t.toJson()).toList();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(jsonList);

    await tempFile.writeAsString(jsonStr, flush: true);
    if (await tempFile.exists()) {
      await tempFile.rename(_ledgerFile!.path);
    }
  }
}
