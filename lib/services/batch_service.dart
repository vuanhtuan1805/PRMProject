import 'dart:async';
import 'dart:io';
import 'ai_service.dart';
import 'file_service.dart';

class BatchService {
  // Safe defaults for Groq free tier
  static const int _defaultBatchSize = 3;       // students per request
  static const int _requestDelayMs = 3000;       // 3s between requests = 20 RPM max
  static const int _maxStudentChars = 6000;      // ~1,500 tokens per student
  static const int _maxPromptChars = 20000;      // ~5,000 tokens per request (safe under 6K TPM)

  static Future<List<Map<String, dynamic>>> gradeFolder({
    required String folderPath,
    required String criteria,
    required AIService aiService,
    required void Function(int, int, int) progressCallback,
    int batchSize = _defaultBatchSize,
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

        var normalized = content.trim();
        if (normalized.length > _maxStudentChars) {
          normalized = normalized.substring(0, _maxStudentChars) +
              '\n\n[TRUNCATED: original ${content.length} chars]';
        }

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

    // Step 2: Build batches respecting char limits
    final batches = <List<String>>[];
    var currentBatch = <String>[];
    var currentChars = 0;

    for (final block in studentBlocks) {
      final wouldBe = currentChars + block.length + 2;
      if (currentBatch.isNotEmpty &&
          (currentBatch.length >= batchSize || wouldBe > _maxPromptChars)) {
        batches.add(List<String>.from(currentBatch));
        currentBatch = [];
        currentChars = 0;
      }
      currentBatch.add(block);
      currentChars += block.length + 2;
    }
    if (currentBatch.isNotEmpty) batches.add(currentBatch);

    print('BatchService: ${studentBlocks.length} students → ${batches.length} batches of max $batchSize');

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
          // Don't retry a 413 — waiting won't help within the same minute.
          // Instead, wait a full minute and try once more.
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