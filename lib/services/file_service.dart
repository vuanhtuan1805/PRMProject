import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FileService {
  /// Read a text file and return its content
  static Future<String> readTextFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('File not found: $filePath');
      }
      return await file.readAsString();
    } catch (e) {
      throw Exception('Error reading file: ${e.toString()}');
    }
  }

  /// Get the documents directory for saving files
  static Future<String> getDocumentsPath() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return directory.path;
    } catch (e) {
      throw Exception('Error getting documents path: ${e.toString()}');
    }
  }

  /// Save content to a text file
  static Future<File> saveTextFile(String fileName, String content) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      return await file.writeAsString(content);
    } catch (e) {
      throw Exception('Error saving file: ${e.toString()}');
    }
  }

  /// Read a DOCX file and extract plain text by unzipping document.xml
  static Future<String> readDocxFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('File not found: $filePath');
      }
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      // find document.xml inside word/
      final doc = archive.files.firstWhere(
        (f) => f.name == 'word/document.xml',
        orElse: () => throw Exception('document.xml not found in docx'),
      );
      final content = utf8.decode(doc.content as List<int>);

      // Replace closing paragraph tags with newlines to preserve paragraphs
      final withParagraphs = content.replaceAll(RegExp(r'<\/w:p>'), '\n');

      // Extract all <w:t>...</w:t> text nodes
      final reg = RegExp(r'<w:t[^>]*>([^<]*)', dotAll: true);
      final buffer = StringBuffer();

      for (final m in reg.allMatches(withParagraphs)) {
        buffer.write(m.group(1));
      }

      // Basic cleanup of xml entities
      var text = buffer.toString();
      text = _decodeXmlEntities(text);
      return text;
    } catch (e) {
      throw Exception('Error reading DOCX: ${e.toString()}');
    }
  }

  static String _decodeXmlEntities(String input) {
    var output = input
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");

    // Decode numeric entities like &#123; or &#x1F4A9;
    output = output.replaceAllMapped(RegExp(r'&#(x?[0-9A-Fa-f]+);'), (m) {
      final raw = m.group(1) ?? '';
      final codePoint = raw.startsWith('x') || raw.startsWith('X')
          ? int.tryParse(raw.substring(1), radix: 16)
          : int.tryParse(raw, radix: 10);
      if (codePoint == null) return m.group(0) ?? '';
      return String.fromCharCode(codePoint);
    });

    return output;
  }

  /// Read a directory of student TXT files named like 1.txt, 2.txt, ... and
  /// return a combined submissions string in a structured format.
  static Future<String> readStudentFolder(String folderPath) async {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists())
        throw Exception('Directory not found: $folderPath');

      final files = await dir
          .list()
          .where(
            (e) => e is File && p.extension(e.path).toLowerCase() == '.txt',
          )
          .cast<File>()
          .toList();

      // filter files with numeric base name
      final numericFiles = <File>[];
      for (final f in files) {
        final base = p.basenameWithoutExtension(f.path);
        if (int.tryParse(base) != null) {
          numericFiles.add(f);
        }
      }

      // If no numeric files, fallback to any txt files
      List<File> toRead = numericFiles.isNotEmpty ? numericFiles : files;

      // sort numeric by integer if possible
      toRead.sort((a, b) {
        final ai = int.tryParse(p.basenameWithoutExtension(a.path)) ?? 0;
        final bi = int.tryParse(p.basenameWithoutExtension(b.path)) ?? 0;
        if (ai == 0 && bi == 0) return a.path.compareTo(b.path);
        return ai.compareTo(bi);
      });

      final buffer = StringBuffer();
      for (final f in toRead) {
        final name = p.basenameWithoutExtension(f.path);
        final content = await f.readAsString();
        final studentLabel = (int.tryParse(name) != null)
            ? 'Student $name'
            : name;
        buffer.writeln('--- Student Name: $studentLabel ---');
        buffer.writeln('Content:');
        buffer.writeln(content.trim());
        buffer.writeln();
      }

      return buffer.toString();
    } catch (e) {
      throw Exception('Error reading student folder: ${e.toString()}');
    }
  }

  /// Return list of txt files in folder sorted by numeric basename when possible
  static Future<List<String>> listStudentFiles(String folderPath) async {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists())
        throw Exception('Directory not found: $folderPath');

      final files = await dir
          .list()
          .where(
            (e) => e is File && p.extension(e.path).toLowerCase() == '.txt',
          )
          .cast<File>()
          .toList();

      files.sort((a, b) {
        final ai = int.tryParse(p.basenameWithoutExtension(a.path)) ?? 0;
        final bi = int.tryParse(p.basenameWithoutExtension(b.path)) ?? 0;
        if (ai == 0 && bi == 0) return a.path.compareTo(b.path);
        return ai.compareTo(bi);
      });

      return files.map((f) => f.path).toList();
    } catch (e) {
      throw Exception('Error listing student files: ${e.toString()}');
    }
  }
}
