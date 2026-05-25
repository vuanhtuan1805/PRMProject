import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:file_picker/file_picker.dart';
import 'services/file_service.dart';
import 'services/ai_service.dart';
import 'services/excel_service.dart';
import 'services/batch_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PMG Scoring Application',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const ScoringPage(),
    );
  }
}

class ScoringPage extends StatefulWidget {
  const ScoringPage({super.key});

  @override
  State<ScoringPage> createState() => _ScoringPageState();
}

class _ScoringPageState extends State<ScoringPage> {
  String get _groqApiKey => dotenv.env['GROQ_API_KEY'] ?? '';
  final TextEditingController _studentsController = TextEditingController();
  final TextEditingController _criteriaController = TextEditingController();
  final TextEditingController _exportPathController = TextEditingController();
  final TextEditingController _templatePathController = TextEditingController();

  String? _submissionFile;
  String? _criteriaFile;
  String? _questionImagePath;
  List<Map<String, dynamic>> _evaluationResults = [];
  bool _isLoading = false;
  int _progressRead = 0;
  int _progressTotal = 0;
  int _batchesProcessed = 0;

  Future<void> _pickSubmissionFile() async {
    // Prefer picking a directory containing numbered TXT files
    try {
      final folder = await FilePicker.platform.getDirectoryPath();
      if (folder != null) {
        final files = await FileService.listStudentFiles(folder);
        setState(() {
          _submissionFile = folder;
          _studentsController.text = '';
          _progressTotal = files.length;
          _progressRead = 0;
          _batchesProcessed = 0;
        });
        return;
      }

      // Fallback: allow selecting multiple txt files
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['txt'],
        withData: true,
      );
      if (result != null && result.files.isNotEmpty) {
        // combine selected files ordered by name
        final files = result.files.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        final buffer = StringBuffer();
        for (final f in files) {
          final name = f.name.replaceAll('.txt', '');
          final content = f.bytes != null ? String.fromCharCodes(f.bytes!) : '';
          buffer.writeln(
            '--- Student Name: ${int.tryParse(name) != null ? 'Student $name' : name} ---',
          );
          buffer.writeln('Alias: $name');
          buffer.writeln('Content:');
          buffer.writeln(content.trim());
          buffer.writeln();
        }
        setState(() {
          _submissionFile = '${files.length} files';
          _studentsController.text = buffer.toString();
          _progressTotal = files.length;
          _progressRead = files.length;
          _batchesProcessed = 0;
        });
      }
    } catch (e) {
      _showSnackBar('Error loading submissions: ${e.toString()}');
    }
  }

  Future<void> _pickCriteriaFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'docx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.extension == 'docx') {
        // write bytes to temp file and extract
        final bytes = file.bytes;
        if (bytes == null) {
          _showSnackBar('Could not read DOCX bytes');
          return;
        }
        final tempDir = await FileService.getDocumentsPath();
        final tmpPath = '$tempDir/${file.name}';
        final tmpFile = File(tmpPath);
        await tmpFile.writeAsBytes(bytes);
        final extracted = await FileService.readDocxFile(tmpPath);
        setState(() {
          _criteriaFile = file.name;
          _criteriaController.text = extracted;
        });
      } else {
        final content = file.bytes != null
            ? String.fromCharCodes(file.bytes!)
            : '';
        setState(() {
          _criteriaFile = file.name;
          _criteriaController.text = content;
        });
      }
    } catch (e) {
      _showSnackBar('Error loading criteria: ${e.toString()}');
    }
  }

  Future<void> _evaluateWithAI() async {
    if (_groqApiKey.trim().isEmpty) {
      _showSnackBar('Please set your Groq API key in the code');
      return;
    }
    if (_studentsController.text.isEmpty && _submissionFile == null) {
      _showSnackBar('Please load or enter student submissions');
      return;
    }
    if (_criteriaController.text.isEmpty) {
      _showSnackBar('Please load or enter scoring criteria');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final aiService = AIService(apiKey: _groqApiKey.trim());
      final criteria = _criteriaController.text;

      // PATH 1: Folder was selected — use BatchService (sequential, safe)
      if (_submissionFile != null && Directory(_submissionFile!).existsSync()) {
        setState(() {
          _progressRead = 0;
          _batchesProcessed = 0;
        });

        final results = await BatchService.gradeFolder(
          folderPath: _submissionFile!,
          criteria: criteria,
          aiService: aiService,
          progressCallback: (read, total, batches) {
            setState(() {
              _progressRead = read;
              _progressTotal = total;
              _batchesProcessed = batches;
            });
          },
          batchSize: 3,
        );

        setState(() => _evaluationResults = _normalizeResults(results));
        _showSnackBar('Done! ${results.length} students graded.');

        // PATH 2: Individual files were picked (stored in _studentsController)
        // Split and send one student at a time
      } else if (_studentsController.text.isNotEmpty) {
        final blocks = _parseStudentBlocks(_studentsController.text);

        if (blocks.isEmpty) {
          _showSnackBar('No student blocks found in text');
          return;
        }

        setState(() {
          _progressRead = 0;
          _progressTotal = blocks.length;
          _batchesProcessed = 0;
        });

        final allResults = <Map<String, dynamic>>[];

        for (int i = 0; i < blocks.length; i++) {
          setState(() => _progressRead = i + 1);

          try {
            final results = await aiService.evaluateSubmissions(
              submissions: blocks[i],
              criteria: criteria,
              expectedSubmissionCount: 1,
            );
            allResults.addAll(results);
          } catch (e) {
            // extract student name from block header
            final match = RegExp(
              r'Student Name: (.+?) ---',
            ).firstMatch(blocks[i]);
            final aliasMatch = RegExp(r'Alias: (.+?)\n').firstMatch(blocks[i]);
            allResults.add({
              'alias': aliasMatch?.group(1) ?? '',
              'studentName': match?.group(1) ?? 'Student ${i + 1}',
              'q1': 0,
              'q2': 0,
              'q3': 0,
              'q4': 0,
              'total': 0,
              'comment': 'Grading failed: $e',
            });
          }

          setState(() => _batchesProcessed = i + 1);

          // Delay between requests to respect TPM limits
          if (i < blocks.length - 1) {
            await Future.delayed(const Duration(milliseconds: 3000));
          }
        }

        setState(() => _evaluationResults = _normalizeResults(allResults));
        _showSnackBar('Done! ${allResults.length} students graded.');
      }
    } catch (e) {
      _showSnackBar('Error: ${e.toString()}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> _normalizeResults(
    List<Map<String, dynamic>> results,
  ) {
    return results.map((result) {
      final alias = result['alias']?.toString().trim() ?? '';
      if (alias.isNotEmpty) return result;

      final name = result['studentName']?.toString().trim() ?? '';
      final numberMatch = RegExp(r'\b(\d+)\b').firstMatch(name);
      if (numberMatch != null) {
        return {
          ...result,
          'alias': numberMatch.group(1),
        };
      }

      return result;
    }).toList();
  }

  /// Split concatenated student text into individual blocks
  List<String> _parseStudentBlocks(String text) {
    final blocks = <String>[];
    final parts = text.split(RegExp(r'(?=--- Student Name:)'));
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) blocks.add(trimmed);
    }
    return blocks;
  }

  Future<void> _exportToExcel() async {
    if (_evaluationResults.isEmpty) {
      _showSnackBar('No evaluation results to export');
      return;
    }

    try {
      final excelService = ExcelService();
      final exportPath = _exportPathController.text.trim();
      final templatePath = _templatePathController.text.trim();

      if (templatePath.isNotEmpty) {
        final fileName = await excelService.fillTemplate(
          templatePath: templatePath,
          results: _evaluationResults,
        );
        _showSnackBar('Updated template: $fileName');
        return;
      }

      final fileName = await excelService.exportResults(
        _evaluationResults,
        filePath: exportPath.isEmpty ? null : exportPath,
      );
      _showSnackBar('Exported to: $fileName');
    } catch (e) {
      _showSnackBar('Export error: ${e.toString()}');
    }
  }

  Future<void> _pickExportPath() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Excel File As',
      fileName: 'PMG_Scores.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (path == null) return;
    setState(() {
      _exportPathController.text = path;
    });
  }

  Future<void> _pickQuestionImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;
    setState(() {
      _questionImagePath = file.path;
    });
  }

  Future<void> _pickTemplateFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;
    setState(() {
      _templatePathController.text = file.path!;
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    _studentsController.dispose();
    _criteriaController.dispose();
    _exportPathController.dispose();
    _templatePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PMG Scoring Application'),
        elevation: 0,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isTwoColumn = constraints.maxWidth >= 900;
          final leftColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Template Excel
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Template Excel (Optional)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Select an existing XLSX to fill Alias, Q1-Q4, Total, Comment',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _templatePathController,
                              decoration: InputDecoration(
                                hintText: 'Select template .xlsx...',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.upload_file, size: 14),
                            label: const Text('Load'),
                            onPressed: _pickTemplateFile,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(0, 36),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Student Submissions
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Student Submissions (Multiple)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Load or paste submissions for multiple students',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            children: [
                              ElevatedButton.icon(
                                icon: const Icon(Icons.folder_open, size: 14),
                                label: const Text('Load Folder'),
                                onPressed: _pickSubmissionFile,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  minimumSize: const Size(0, 36),
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                          ),
                        ],
                      ),
                      if (_submissionFile != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.green[50],
                              border: Border.all(color: Colors.green),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '✓ Loaded: $_submissionFile',
                              style: const TextStyle(
                                color: Colors.green,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Scoring Criteria
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Grading Criteria Document',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Define your grading standards and rubric',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.upload_file, size: 14),
                            label: const Text('Load DOCX/TXT'),
                            onPressed: _pickCriteriaFile,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(0, 36),
                            ),
                          ),
                        ],
                      ),
                      if (_criteriaFile != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.green[50],
                              border: Border.all(color: Colors.green),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '✓ Loaded: $_criteriaFile',
                              style: const TextStyle(
                                color: Colors.green,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );

          final rightColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Output Excel File
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Excel Output File',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Choose where to save the exported .xlsx file',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _exportPathController,
                              decoration: InputDecoration(
                                hintText: 'Select a save location...',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.save_alt, size: 14),
                            label: const Text('Browse'),
                            onPressed: _pickExportPath,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(0, 36),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Question Image (PNG)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Question Image (PNG)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Optional: attach the question image for reference',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _questionImagePath ?? 'No image selected',
                              style: TextStyle(
                                fontSize: 11,
                                color: _questionImagePath == null
                                    ? Colors.grey[600]
                                    : Colors.black,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.image, size: 14),
                            label: const Text('Choose PNG'),
                            onPressed: _pickQuestionImage,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              minimumSize: const Size(0, 36),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Progress (folder mode)
              if (_submissionFile != null && _progressTotal > 0) ...[
                Text('Reading files: $_progressRead / $_progressTotal'),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: _progressTotal > 0
                      ? _progressRead / _progressTotal
                      : null,
                  minHeight: 8,
                ),
                const SizedBox(height: 8),
              ],

              // Evaluate Button
              ElevatedButton.icon(
                icon: _isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.psychology),
                label: Text(_isLoading ? 'Grading...' : 'Grade All Students'),
                onPressed: _isLoading ? null : _evaluateWithAI,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: Colors.blue,
                  disabledBackgroundColor: Colors.grey,
                ),
              ),
              const SizedBox(height: 10),

              // Results Display
              if (_evaluationResults.isNotEmpty) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Results (${_evaluationResults.length} items)',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.download, size: 14),
                              label: const Text('Export'),
                              onPressed: _exportToExcel,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                minimumSize: const Size(0, 36),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _evaluationResults.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (context, index) {
                            final result = _evaluationResults[index];
                            final total = result['total'] ?? result['score'];
                            final comment = result['comment'] ?? result['feedback'];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Student ${index + 1}: ${result['studentName'] ?? 'N/A'}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Score: ${total ?? 'N/A'}/100',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.blue,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Feedback: ${comment ?? 'N/A'}',
                                    style: const TextStyle(fontSize: 11),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );

          return SingleChildScrollView(
            padding: const EdgeInsets.all(12.0),
            child: isTwoColumn
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: leftColumn),
                      const SizedBox(width: 12),
                      Expanded(child: rightColumn),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      leftColumn,
                      const SizedBox(height: 10),
                      rightColumn,
                    ],
                  ),
          );
        },
      ),
    );
  }
}
