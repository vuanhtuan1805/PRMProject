import 'dart:async';
import 'dart:io';
import 'ai_service.dart';
import 'file_service.dart';

class BatchService {
  static const int _requestDelayMs = 60000;      // 1 request per minute
  static const int _maxPromptTokens = 30000;     // total prompt token cap
  static const int _approxCharsPerToken = 4;     // rough approx

  static Future<List<Map<String, dynamic>>> gradeFolder({
    required String folderPath,
    required String criteria,
    required AIService aiService,
    required void Function(int, int, int) progressCallback,
  }) async {
    final filePaths = await FileService.listStudentFiles(folderPath);
    final total = filePaths.length;
    final results = <Map<String, dynamic>>[];
    var batchesProcessed = 0;
    var readCount = 0;

    // Step 1: Read ALL files first (fast, local IO)
    final studentBlocks = <String>[];
    for (final path in filePaths) {
      try {
        final content = await File(path).readAsString();
        final name = path.split(Platform.pathSeparator).last.split('.').first;
        final label = int.tryParse(name) != null ? 'Student $name' : name;

        final normalized = content.trim();
        studentBlocks.add(
          '--- Student Name: $label ---\nAlias: $name\nContent:\n$normalized',
        );
        readCount++;
        progressCallback(readCount, total, batchesProcessed);
      } catch (e) {
        print('BatchService: failed to read $path: $e');
        readCount++;
        progressCallback(readCount, total, batchesProcessed);
      }
    }

    // Step 2: Build batches respecting prompt token limits
    final promptStats = await AIService.getPromptTemplateStats();
    final criteriaLength = criteria.length;
    final batches = <List<String>>[];
    var currentBatch = <String>[];
    var currentChars = 0;

    for (final block in studentBlocks) {
      final separator = currentBatch.isEmpty ? 0 : 2;
      final blockSize = block.length + separator;
      final prospectiveSubmissionsLength = currentChars + blockSize;
      final countLength = (currentBatch.length + 1).toString().length;
      final estimatedPromptChars = promptStats.baseLength +
          (countLength * promptStats.countOccurrences) +
          (criteriaLength * promptStats.criteriaOccurrences) +
          (prospectiveSubmissionsLength *
              promptStats.submissionsOccurrences);
      final estimatedPromptTokens =
          (estimatedPromptChars / _approxCharsPerToken).ceil();

      if (currentBatch.isNotEmpty &&
          estimatedPromptTokens > _maxPromptTokens) {
        batches.add(List<String>.from(currentBatch));
        currentBatch = [];
        currentChars = 0;
      }

      final actualSeparator = currentBatch.isEmpty ? 0 : 2;
      currentBatch.add(block);
      currentChars += block.length + actualSeparator;
    }
    if (currentBatch.isNotEmpty) batches.add(currentBatch);

    print('BatchService: ${studentBlocks.length} students → ${batches.length} batches (prompt cap ${_maxPromptTokens} tokens)');

    // Step 3: Fire batches SEQUENTIALLY with delay — no concurrency
    for (int i = 0; i < batches.length; i++) {
      final batch = batches[i];
      final promptInput = batch.join('\n\n');

      print('BatchService: batch ${i + 1}/${batches.length} '
            '(${batch.length} students, ${promptInput.length} chars, '
            '~${promptInput.length ~/ 4} tokens)');

      try {
        final batchResults = await _callWithRetry(
          aiService: aiService,
          submissions: promptInput,
          criteria: criteria,
          batch: batch,
        );
        results.addAll(batchResults);
      } catch (e) {
        print('BatchService: batch ${i + 1} failed permanently: $e');
        // Add error placeholders so UI stays consistent
        for (final block in batch) {
          final nameMatch = RegExp(r'Student Name: (.+?) ---').firstMatch(block);
          final aliasMatch = RegExp(r'Alias: (.+?)\n').firstMatch(block);
          results.add({
            'alias': aliasMatch?.group(1) ?? '',
            'studentName': nameMatch?.group(1) ?? 'Unknown',
            'q1': 0,
            'q2': 0,
            'q3': 0,
            'q4': 0,
            'total': 0,
            'comment': 'Grading failed: ${e.toString()}',
          });
        }
      }

      batchesProcessed++;
      progressCallback(readCount, total, batchesProcessed);

      // Always wait between batches — even the last one (guards against
      // a quick follow-up call from the UI)
      if (i < batches.length - 1) {
        print('BatchService: waiting ${_requestDelayMs}ms before next batch...');
        await Future.delayed(const Duration(milliseconds: _requestDelayMs));
      }
    }

    return results;
  }

  static Future<List<Map<String, dynamic>>> _callWithRetry({
    required AIService aiService,
    required String submissions,
    required String criteria,
    required List<String> batch,
    int maxAttempts = 3,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await aiService.evaluateSubmissions(
          submissions: submissions,
          criteria: criteria,
          expectedSubmissionCount: batch.length,
        );
      } catch (e) {
        final is413 = e.toString().contains('413') ||
            e.toString().contains('rate_limit_exceeded') ||
            e.toString().contains('tokens per minute');

        if (is413) {
          if (attempt == 1) {
            print('BatchService: 413 hit, waiting 60s for TPM reset...');
            await Future.delayed(const Duration(seconds: 60));
            continue;
          }
          rethrow;
        }

        if (attempt == maxAttempts) rethrow;

        final waitMs = 1000 * attempt * 2;
        print('BatchService: attempt $attempt failed, retrying in ${waitMs}ms: $e');
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
    throw Exception('All $maxAttempts attempts failed');
  }
}