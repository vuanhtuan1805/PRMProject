import 'dart:convert';

import 'package:http/http.dart' as http;

class AIService {
  final String apiKey;

  AIService({required this.apiKey});

  static const String _groqChatCompletionsUrl =
      'https://api.groq.com/openai/v1/chat/completions';

  /// Try Meta Llama 4 models on Groq until one succeeds.
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
    final prompt = '''
You are an expert academic evaluator for the PMG (Project Management Group) subject.
Your task is to evaluate student submissions and provide individual scores for each.

There may be ONE or MULTIPLE student submissions.

Expected number of submissions: $expectedSubmissionCount

Rules:
- Return exactly $expectedSubmissionCount result item(s).
- Do not split one file into multiple students unless the text clearly contains separate student submissions.
- If expectedSubmissionCount is 1, return exactly one student result.
- If multiple, return one result per submission.

GRADING CRITERIA:
$criteria

STUDENT SUBMISSIONS (Multiple Students):
$submissions

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
          // continue to next model
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
