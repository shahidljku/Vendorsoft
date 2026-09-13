class BatchSummary {
  final int totalQueued;
  final int confirmed;
  final int failed;
  final int uncertain;
  final int skipped;
  final String? haltReason;
  final Duration duration;

  const BatchSummary({
    required this.totalQueued,
    required this.confirmed,
    required this.failed,
    required this.uncertain,
    required this.skipped,
    this.haltReason,
    this.duration = Duration.zero,
  });

  bool get hasFailuresOrUncertain => failed > 0 || uncertain > 0;
  bool get wasHalted => haltReason != null && haltReason != 'Completed';
}
