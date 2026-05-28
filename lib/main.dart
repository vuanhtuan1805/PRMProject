import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:file_picker/file_picker.dart';
import 'services/file_service.dart';
import 'services/ai_service.dart';
import 'services/excel_service.dart';
import 'services/batch_service.dart';
import 'widgets/scoring_sections.dart';

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
              TemplateExcelCard(
                onPickTemplateFile: _pickTemplateFile,
              ),
              const SizedBox(height: 10),

              SubmissionsCard(
                onPickSubmissionFile: _pickSubmissionFile,
                submissionFile: _submissionFile,
              ),
              const SizedBox(height: 10),

              CriteriaCard(
                onPickCriteriaFile: _pickCriteriaFile,
                criteriaFile: _criteriaFile,
              ),
            ],
          );

          final rightColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutputExcelCard(
                onPickExportPath: _pickExportPath,
              ),
              const SizedBox(height: 10),

              QuestionImageCard(
                questionImagePath: _questionImagePath,
                onPickQuestionImage: _pickQuestionImage,
              ),
              const SizedBox(height: 10),

              if (_submissionFile != null)
                ProgressSection(
                  progressRead: _progressRead,
                  progressTotal: _progressTotal,
                ),
              EvaluateButton(
                isLoading: _isLoading,
                onEvaluate: _evaluateWithAI,
              ),
              const SizedBox(height: 10),

              ResultsCard(
                results: _evaluationResults,
                onExportToExcel: _exportToExcel,
              ),
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
