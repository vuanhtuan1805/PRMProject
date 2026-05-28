import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

class PromptTemplateStats {
  final int baseLength;
  final int countOccurrences;
  final int criteriaOccurrences;
  final int submissionsOccurrences;

  const PromptTemplateStats({
    required this.baseLength,
    required this.countOccurrences,
    required this.criteriaOccurrences,
    required this.submissionsOccurrences,
  });
}

class AIService {
  final String apiKey;

  AIService({required this.apiKey});

  static const String _groqChatCompletionsUrl =
      'https://api.groq.com/openai/v1/chat/completions';

  static const String _countPlaceholder = '{{COUNT}}';
  static const String _criteriaPlaceholder = '{{CRITERIA}}';
  static const String _submissionsPlaceholder = '{{SUBMISSIONS}}';

  static const String _promptAssetPath = 'assets/prompts/ai_prompt.txt';

  static String? _cachedPromptTemplate;
  static PromptTemplateStats? _cachedPromptStats;

  static Future<String> _loadPromptTemplate() async {
    if (_cachedPromptTemplate != null) {
      return _cachedPromptTemplate!;
    }

    final template = await rootBundle.loadString(_promptAssetPath);
    _cachedPromptTemplate = template;
    _cachedPromptStats = _calculatePromptStats(template);
    return template;
  }

  static int _countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;
    return RegExp(RegExp.escape(needle)).allMatches(text).length;
  }

  static PromptTemplateStats _calculatePromptStats(String template) {
    final countOccurrences = _countOccurrences(template, _countPlaceholder);
    final criteriaOccurrences = _countOccurrences(template, _criteriaPlaceholder);
    final submissionsOccurrences =
        _countOccurrences(template, _submissionsPlaceholder);

    final baseLength = template.length -
        (countOccurrences * _countPlaceholder.length) -
        (criteriaOccurrences * _criteriaPlaceholder.length) -
        (submissionsOccurrences * _submissionsPlaceholder.length);

    return PromptTemplateStats(
      baseLength: baseLength,
      countOccurrences: countOccurrences,
      criteriaOccurrences: criteriaOccurrences,
      submissionsOccurrences: submissionsOccurrences,
    );
  }

  static Future<PromptTemplateStats> getPromptTemplateStats() async {
    if (_cachedPromptStats != null) {
      return _cachedPromptStats!;
    }

    await _loadPromptTemplate();
    return _cachedPromptStats!;
  }

  static Future<String> buildPrompt({
    required String criteria,
    required String submissions,
    required int expectedSubmissionCount,
  }) async {
    final template = await _loadPromptTemplate();
    return template
        .replaceAll(_countPlaceholder, expectedSubmissionCount.toString())
        .replaceAll(_criteriaPlaceholder, criteria)
        .replaceAll(_submissionsPlaceholder, submissions);
  }

  static Future<int> estimatePromptChars({
    required int expectedSubmissionCount,
    required int criteriaLength,
    required int submissionsLength,
  }) async {
    final stats = await getPromptTemplateStats();
    final countLength = expectedSubmissionCount.toString().length;

    return stats.baseLength +
        (countLength * stats.countOccurrences) +
        (criteriaLength * stats.criteriaOccurrences) +
        (submissionsLength * stats.submissionsOccurrences);
  }

  final List<String> _modelCandidates = [
    // 'llama-3.1-8b-instant',
    // 'llama-3.3-70b-versatile',
    'meta-llama/llama-4-scout-17b-16e-instruct'
  ];

  Future<List<Map<String, dynamic>>> evaluateSubmissions({
    required String submissions,
    required String criteria,
    required int expectedSubmissionCount,
  }) async {
    final prompt = await buildPrompt(
      criteria: criteria,
      submissions: submissions,
      expectedSubmissionCount: expectedSubmissionCount,
    );

    try {
      print('AIService: sending prompt to Groq (length=${prompt.length})');

      String? responseText;
      Exception? lastEx;
      for (final m in _modelCandidates) {
        try {
          print('AIService: attempting Groq model=$m');
          responseText = await _callGroqChatCompletions(model: m, prompt: prompt);
          print('AIService: model=$m response.text.length=${responseText.length}');
          if (responseText.isNotEmpty) {
            break;
          }
        } catch (e, st) {
          lastEx = Exception('model=$m error: $e');
          print('AIService: model=$m error: $e');
          print(st.toString());
        }
      }

      if (responseText == null || responseText.isEmpty) {
        throw lastEx ?? Exception('No valid response from any model candidates');
      }

      final cleanedResponseText = _stripCodeFence(responseText).trim();
      
      // Extract JSON from response (in case model adds extra text)
      final jsonStart = cleanedResponseText.indexOf('[');
      final jsonEnd = cleanedResponseText.lastIndexOf(']');
      
      if (jsonStart == -1 || jsonEnd == -1) {
        throw Exception('No valid JSON found in response');
      }

      final jsonString = cleanedResponseText.substring(jsonStart, jsonEnd + 1);
      
      // Parse JSON
      final List<dynamic> parsed = _parseJsonArray(jsonString);
      
      return parsed.cast<Map<String, dynamic>>();
    } catch (e, st) {
      // Log full error and stacktrace for debugging
      try {
        print('AIService: Exception during evaluateSubmissions: $e');
        print(st.toString());
      } catch (_) {}
      rethrow;
    }
  }

  Future<String> _callGroqChatCompletions({
    required String model,
    required String prompt,
  }) async {
    final response = await http.post(
      Uri.parse(_groqChatCompletionsUrl),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'temperature': 0,
        'messages': [
          {
            'role': 'system',
            'content':
                'You are a strict JSON API. Return only valid JSON with no markdown or explanations.',
          },
          {
            'role': 'user',
            'content': prompt,
          }
        ],
      }),
    );

    print('AIService: Groq status=${response.statusCode} model=$model');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Groq API error (${response.statusCode}) for model=$model: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw Exception('Groq response has no choices for model=$model');
    }

    final first = choices.first;
    if (first is! Map<String, dynamic>) {
      throw Exception('Groq response choice format invalid for model=$model');
    }

    final message = first['message'];
    if (message is! Map<String, dynamic>) {
      throw Exception('Groq response message missing for model=$model');
    }

    final content = message['content'];
    if (content is! String || content.trim().isEmpty) {
      throw Exception('Groq response content is empty for model=$model');
    }

    return content;
  }

  List<dynamic> _parseJsonArray(String jsonString) {
    final dynamic decoded = jsonDecode(jsonString);
    if (decoded is List) {
      return decoded;
    }

    throw Exception('Expected JSON array from model response');
  }

  String _stripCodeFence(String input) {
    var output = input.trim();
    if (output.startsWith('```')) {
      output = output.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      output = output.replaceFirst(RegExp(r'\s*```$'), '');
    }
    return output;
  }
}
