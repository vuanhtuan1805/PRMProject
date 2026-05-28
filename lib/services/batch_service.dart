import 'dart:async';
import 'dart:io';
import 'ai_service.dart';
import 'file_service.dart';

class BatchService {
  // Safe defaults for Groq free tier
  static const int _requestDelayMs = 60000;      // 1 request per minute
  static const int _maxStudentChars = 6000;      // ~1,500 tokens per student
  static const int _maxPromptTokens = 30000;     // total prompt token cap
  static const int _approxCharsPerToken = 4;     // rough heuristic

  static const String _countPlaceholder = '{{COUNT}}';
  static const String _criteriaPlaceholder = '{{CRITERIA}}';
  static const String _submissionsPlaceholder = '{{SUBMISSIONS}}';

  static const String _promptTemplate = '''
You are an expert academic evaluator for the PMG (Project Management Group) subject.
Your task is to evaluate student submissions and provide individual scores for each.

There may be ONE or MULTIPLE student submissions.

Expected number of submissions: {{COUNT}}

Rules:
- Return exactly {{COUNT}} result item(s).
- Do not split one file into multiple students unless the text clearly contains separate student submissions.
- If expectedSubmissionCount is 1, return exactly one student result.
- If multiple, return one result per submission.

GRADING CRITERIA:
{{CRITERIA}}

STUDENT SUBMISSIONS (Multiple Students):
{{SUBMISSIONS}}

Use the rubric strictly.

For each question:
1. Score each sub-criterion separately.
2. Sum the sub-criteria to get q1, q2, q3, q4.
3. Do not assign a holistic score.
4. Do not give credit unless there is clear evidence in the submission.
5. Total must equal q1 + q2 + q3 + q4.

IMPORTANT:
- Process ALL students in the submission
- Each student should have their own score entry
- Ensure consistent scoring

Format your response as a JSON array. Example:
[
  {"alias": "1", "studentName": "John Doe", "q1": 18, "q2": 16, "q3": 25, "q4": 26, "total": 85, "comment": "Good understanding..."},
  {"alias": "2", "studentName": "Jane Smith", "q1": 20, "q2": 18, "q3": 27, "q4": 27, "total": 92, "comment": "Excellent work..."}
]

Provide ONLY the valid JSON array, no additional text or markdown.
''';

  static const int _promptTemplateBaseLength = _promptTemplate.length -
      (_countPlaceholder.length * 2) -
      _criteriaPlaceholder.length -
      _submissionsPlaceholder.length;

  static int _estimatePromptChars({
    required int expectedSubmissionCount,
    required int criteriaLength,
    required int submissionsLength,
  }) {
    return _promptTemplateBaseLength +
        (expectedSubmissionCount.toString().length * 2) +
        criteriaLength +
        submissionsLength;
  }

  static int _estimatePromptTokens({
    required int expectedSubmissionCount,
    required int criteriaLength,
    required int submissionsLength,
  }) {
    final chars = _estimatePromptChars(
      expectedSubmissionCount: expectedSubmissionCount,
      criteriaLength: criteriaLength,
      submissionsLength: submissionsLength,
    );
    return (chars / _approxCharsPerToken).ceil();
  }

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

        var normalized = content.trim();
        if (normalized.length > _maxStudentChars) {
          normalized = '${normalized.substring(0, _maxStudentChars)}\n\n[TRUNCATED: original ${content.length} chars]';
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

    // Step 2: Build batches respecting prompt token limits
    final batches = <List<String>>[];
    var currentBatch = <String>[];
    var currentChars = 0;

    for (final block in studentBlocks) {
      final separator = currentBatch.isEmpty ? 0 : 2;
      final blockSize = block.length + separator;
      final prospectiveSubmissionsLength = currentChars + blockSize;
      final estimatedPromptTokens = _estimatePromptTokens(
        expectedSubmissionCount: currentBatch.length + 1,
        criteriaLength: criteria.length,
        submissionsLength: prospectiveSubmissionsLength,
      );

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