import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Represents a distinct grouped section of the report.
/// Contains a title, optional subtitle, and the raw data rows for the table.
class ReportSection {
  final String title;
  final String subtitle;
  final List<List<String>> rows;
  final List<String> summaryLines;

  const ReportSection({
    this.title = '',
    this.subtitle = '',
    required this.rows,
    this.summaryLines = const [],
  });
}

/// A pure data model representing the complete report structure.
/// The framework consumes this model to render the PDF.
class ReportConfig {
  final String reportTitle;
  final String businessName;
  final List<String> filters;
  final PdfPageFormat pageFormat;

  final List<String> headers;
  final Map<int, pw.Alignment> columnAlignments;
  final Map<int, pw.TableColumnWidth>? columnWidths;

  final List<ReportSection> sections;
  final List<String> grandTotals;

  const ReportConfig({
    required this.reportTitle,
    required this.businessName,
    this.filters = const [],
    this.pageFormat = PdfPageFormat.a4,
    required this.headers,
    required this.columnAlignments,
    this.columnWidths,
    required this.sections,
    this.grandTotals = const [],
  });
}
