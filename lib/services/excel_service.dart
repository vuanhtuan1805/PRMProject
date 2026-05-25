import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

class ExcelService {
  Future<String> exportResults(
    List<Map<String, dynamic>> results, {
    String? filePath,
  }) async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];

      // Add headers
      sheet.appendRow([
        TextCellValue('Student Name'),
        TextCellValue('Score'),
        TextCellValue('Feedback'),
      ]);

      // Add data rows
      for (final result in results) {
        final score = result['total'] ?? result['score'] ?? 0;
        final feedback = result['comment'] ?? result['feedback'] ?? 'N/A';
        sheet.appendRow([
          TextCellValue(result['studentName']?.toString() ?? 'N/A'),
          IntCellValue(int.tryParse(score.toString()) ?? 0),
          TextCellValue(feedback.toString()),
        ]);
      }

      // Get the documents directory
      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          'PMG_Scores_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final resolvedPath = filePath ?? '${dir.path}/$fileName';

      // Save the file
      final file = File(resolvedPath);
      await file.writeAsBytes(excel.encode() ?? []);

      return filePath ?? fileName;
    } catch (e) {
      throw Exception('Error exporting to Excel: ${e.toString()}');
    }
  }

  /// Export with detailed feedback
  Future<String> exportDetailedResults(
    List<Map<String, dynamic>> results,
  ) async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];

      // Add headers with styling
      sheet.appendRow([
        TextCellValue('Student Name'),
        TextCellValue('Score (out of 100)'),
        TextCellValue('Detailed Feedback'),
        TextCellValue('Evaluation Date'),
      ]);

      // Add data rows
      final now = DateTime.now().toString().split('.')[0];
      for (final result in results) {
        final score = result['total'] ?? result['score'] ?? 0;
        final feedback = result['comment'] ?? result['feedback'] ?? 'N/A';
        sheet.appendRow([
          TextCellValue(result['studentName']?.toString() ?? 'N/A'),
          IntCellValue(int.tryParse(score.toString()) ?? 0),
          TextCellValue(feedback.toString()),
          TextCellValue(now),
        ]);
      }

      // Auto-size columns
      sheet.setColumnWidth(0, 20);
      sheet.setColumnWidth(1, 15);
      sheet.setColumnWidth(2, 40);
      sheet.setColumnWidth(3, 20);

      // Get the documents directory
      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          'PMG_Scores_Detailed_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final filePath = '${dir.path}/$fileName';

      // Save the file
      final file = File(filePath);
      await file.writeAsBytes(excel.encode() ?? []);

      return fileName;
    } catch (e) {
      throw Exception('Error exporting detailed results: ${e.toString()}');
    }
  }

  Future<String> fillTemplate({
    required String templatePath,
    required List<Map<String, dynamic>> results,
  }) async {
    try {
      final file = File(templatePath);
      if (!await file.exists()) {
        throw Exception('Template file not found: $templatePath');
      }

      final bytes = await file.readAsBytes();
      final excel = Excel.decodeBytes(bytes);

      final sheet = _findSheetWithHeaders(excel);
      if (sheet == null) {
        throw Exception('Could not find header row in template');
      }

      final headerRowIndex = sheet.headerRowIndex;
      final colIndex = sheet.columnIndex;

      final byAlias = <String, Map<String, dynamic>>{};
      for (final result in results) {
        final alias = result['alias']?.toString().trim();
        if (alias != null && alias.isNotEmpty) {
          byAlias[alias] = result;
        }
      }

      final table = sheet.table;
      var lastRow = table.maxRows;

      for (var row = headerRowIndex + 1; row < table.maxRows; row++) {
        final aliasCell = table.cell(
          CellIndex.indexByColumnRow(
            columnIndex: colIndex.alias,
            rowIndex: row,
          ),
        );
        final aliasText = aliasCell.value?.toString().trim() ?? '';
        if (aliasText.isEmpty) {
          continue;
        }

        final result = byAlias.remove(aliasText);
        if (result == null) continue;
        _writeRow(table, row, colIndex, result);
      }

      // Append any results not found in the template
      for (final entry in byAlias.entries) {
        final row = lastRow;
        lastRow++;
        _writeRow(table, row, colIndex, entry.value);
      }

      final outBytes = excel.encode();
      if (outBytes == null) {
        throw Exception('Failed to encode updated Excel file');
      }
      final outputPath = templatePath.replaceFirst(
        RegExp(r'\.xlsx$', caseSensitive: false),
        '_filled.xlsx',
      );

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(outBytes, flush: true);

      return outputPath;
    } catch (e) {
      throw Exception('Error writing template Excel: ${e.toString()}');
    }
  }

  _SheetWithHeaders? _findSheetWithHeaders(Excel excel) {
    for (final name in excel.tables.keys) {
      final table = excel.tables[name];
      if (table == null) continue;

      for (var row = 0; row < table.maxRows && row < 10; row++) {
        // Try normal single-row header first
        final singleRowColumns = _mapHeaderRow(table, row);
        if (singleRowColumns != null) {
          return _SheetWithHeaders(table, row, singleRowColumns);
        }

        // Try two-row header: current row + next row
        if (row + 1 < table.maxRows) {
          final twoRowColumns = _mapTwoHeaderRows(table, row, row + 1);
          if (twoRowColumns != null) {
            return _SheetWithHeaders(table, row + 1, twoRowColumns);
          }
        }
      }
    }

    return null;
  }

  _ColumnIndex? _mapTwoHeaderRows(
    Sheet table,
    int topRowIndex,
    int bottomRowIndex,
  ) {
    int? alias;
    int? marker;
    int? q1;
    int? q2;
    int? q3;
    int? q4;
    int? total;
    int? comment;

    final maxCols = table.maxColumns;

    for (var col = 0; col < maxCols; col++) {
      final topValue =
          table
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: col,
                  rowIndex: topRowIndex,
                ),
              )
              .value
              ?.toString()
              .trim()
              .toLowerCase() ??
          '';

      final bottomValue =
          table
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: col,
                  rowIndex: bottomRowIndex,
                ),
              )
              .value
              ?.toString()
              .trim()
              .toLowerCase() ??
          '';

      final value = '$topValue $bottomValue'.trim();

      if (topValue == 'alias' || bottomValue == 'alias') alias = col;
      if (topValue == 'marker' || bottomValue == 'marker') marker = col;

      if (value.contains('question 1') || value == 'q1') q1 = col;
      if (value.contains('question 2') || value == 'q2') q2 = col;
      if (value.contains('question 3') || value == 'q3') q3 = col;
      if (value.contains('question 4') || value == 'q4') q4 = col;

      if (topValue == 'total' || bottomValue == 'total') total = col;
      if (topValue == 'comment' ||
          bottomValue == 'comment' ||
          topValue == 'comments' ||
          bottomValue == 'comments') {
        comment = col;
      }
    }

    if (alias == null ||
        q1 == null ||
        q2 == null ||
        q3 == null ||
        q4 == null ||
        total == null) {
      return null;
    }

    return _ColumnIndex(
      alias: alias,
      marker: marker,
      q1: q1,
      q2: q2,
      q3: q3,
      q4: q4,
      total: total,
      comment: comment,
    );
  }

  _ColumnIndex? _mapHeaderRow(Sheet table, int rowIndex) {
    int? alias;
    int? marker;
    int? q1;
    int? q2;
    int? q3;
    int? q4;
    int? total;
    int? comment;

    final rowCells = rowIndex < table.rows.length
        ? table.rows[rowIndex]
        : const [];
    for (var col = 0; col < rowCells.length; col++) {
      final value =
          table
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: col,
                  rowIndex: rowIndex,
                ),
              )
              .value
              ?.toString()
              .trim()
              .toLowerCase() ??
          '';
      if (value.isEmpty) continue;

      if (value == 'alias') alias = col;
      if (value == 'marker') marker = col;
      if (value == 'question 1' || value == 'q1') q1 = col;
      if (value == 'question 2' || value == 'q2') q2 = col;
      if (value == 'question 3' || value == 'q3') q3 = col;
      if (value == 'question 4' || value == 'q4') q4 = col;
      if (value == 'total') total = col;
      if (value == 'comment' || value == 'comments') comment = col;
    }

    if (alias == null ||
        q1 == null ||
        q2 == null ||
        q3 == null ||
        q4 == null ||
        total == null) {
      return null;
    }

    return _ColumnIndex(
      alias: alias,
      marker: marker,
      q1: q1,
      q2: q2,
      q3: q3,
      q4: q4,
      total: total,
      comment: comment,
    );
  }

  void _writeRow(
    Sheet table,
    int row,
    _ColumnIndex columns,
    Map<String, dynamic> result,
  ) {
    final alias = result['alias']?.toString().trim() ?? '';
    final q1 = _scaledScore(result['q1']);
    final q2 = _scaledScore(result['q2']);
    final q3 = _scaledScore(result['q3']);
    final q4 = _scaledScore(result['q4']);
    final total = _scaledScore(result['total']);
    final comment =
        result['comment']?.toString() ?? result['feedback']?.toString() ?? '';

    table
        .cell(
          CellIndex.indexByColumnRow(columnIndex: columns.alias, rowIndex: row),
        )
        .value = TextCellValue(
      alias,
    );
    table
        .cell(
          CellIndex.indexByColumnRow(columnIndex: columns.q1, rowIndex: row),
        )
        .value = DoubleCellValue(
      q1,
    );
    table
        .cell(
          CellIndex.indexByColumnRow(columnIndex: columns.q2, rowIndex: row),
        )
        .value = DoubleCellValue(
      q2,
    );
    table
        .cell(
          CellIndex.indexByColumnRow(columnIndex: columns.q3, rowIndex: row),
        )
        .value = DoubleCellValue(
      q3,
    );
    table
        .cell(
          CellIndex.indexByColumnRow(columnIndex: columns.q4, rowIndex: row),
        )
        .value = DoubleCellValue(
      q4,
    );
    table
        .cell(
          CellIndex.indexByColumnRow(columnIndex: columns.total, rowIndex: row),
        )
        .value = DoubleCellValue(
      total,
    );
    if (columns.comment != null) {
      table
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: columns.comment!,
              rowIndex: row,
            ),
          )
          .value = TextCellValue(
        comment,
      );
    }
  }

  double _scaledScore(dynamic value) {
    final raw = double.tryParse(value?.toString() ?? '') ?? 0.0;
    return raw / 10.0;
  }
}

class _ColumnIndex {
  final int alias;
  final int? marker;
  final int q1;
  final int q2;
  final int q3;
  final int q4;
  final int total;
  final int? comment;

  _ColumnIndex({
    required this.alias,
    required this.marker,
    required this.q1,
    required this.q2,
    required this.q3,
    required this.q4,
    required this.total,
    required this.comment,
  });
}

class _SheetWithHeaders {
  final Sheet table;
  final int headerRowIndex;
  final _ColumnIndex columnIndex;

  _SheetWithHeaders(this.table, this.headerRowIndex, this.columnIndex);
}
