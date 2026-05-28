import 'package:flutter/material.dart';

class TemplateExcelCard extends StatelessWidget {
  final VoidCallback onPickTemplateFile;

  const TemplateExcelCard({
    super.key,
    required this.onPickTemplateFile,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Template Excel (Optional)',
      subtitle: 'Select an existing XLSX to fill Alias, Q1-Q4, Total, Comment',
      child: Align(
        alignment: Alignment.centerLeft,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.upload_file, size: 14),
          label: const Text('Load'),
          onPressed: onPickTemplateFile,
          style: _compactButtonStyle(),
        ),
      ),
    );
  }
}

class SubmissionsCard extends StatelessWidget {
  final VoidCallback onPickSubmissionFile;
  final String? submissionFile;

  const SubmissionsCard({
    super.key,
    required this.onPickSubmissionFile,
    required this.submissionFile,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Student Submissions (Multiple)',
      subtitle: 'Load or paste submissions for multiple students',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.folder_open, size: 14),
              label: const Text('Load Folder'),
              onPressed: onPickSubmissionFile,
              style: _compactButtonStyle(),
            ),
          ),
          if (submissionFile != null)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: _LoadedBadge(text: '✓ Loaded: $submissionFile'),
            ),
        ],
      ),
    );
  }
}

class CriteriaCard extends StatelessWidget {
  final VoidCallback onPickCriteriaFile;
  final String? criteriaFile;

  const CriteriaCard({
    super.key,
    required this.onPickCriteriaFile,
    required this.criteriaFile,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Grading Criteria Document',
      subtitle: 'Define your grading standards and rubric',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.upload_file, size: 14),
              label: const Text('Load DOCX/TXT'),
              onPressed: onPickCriteriaFile,
              style: _compactButtonStyle(),
            ),
          ),
          if (criteriaFile != null)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: _LoadedBadge(text: '✓ Loaded: $criteriaFile'),
            ),
        ],
      ),
    );
  }
}

class OutputExcelCard extends StatelessWidget {
  final VoidCallback onPickExportPath;

  const OutputExcelCard({
    super.key,
    required this.onPickExportPath,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Excel Output File',
      subtitle: 'Choose where to save the exported .xlsx file',
      child: Align(
        alignment: Alignment.centerLeft,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.save_alt, size: 14),
          label: const Text('Browse'),
          onPressed: onPickExportPath,
          style: _compactButtonStyle(),
        ),
      ),
    );
  }
}

class QuestionImageCard extends StatelessWidget {
  final String? questionImagePath;
  final VoidCallback onPickQuestionImage;

  const QuestionImageCard({
    super.key,
    required this.questionImagePath,
    required this.onPickQuestionImage,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Question Image (PNG)',
      subtitle: 'Optional: attach the question image for reference',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            questionImagePath ?? 'No image selected',
            style: TextStyle(
              fontSize: 11,
              color:
                  questionImagePath == null ? Colors.grey[600] : Colors.black,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.image, size: 14),
              label: const Text('Choose PNG'),
              onPressed: onPickQuestionImage,
              style: _compactButtonStyle(),
            ),
          ),
        ],
      ),
    );
  }
}

class ProgressSection extends StatelessWidget {
  final int progressRead;
  final int progressTotal;

  const ProgressSection({
    super.key,
    required this.progressRead,
    required this.progressTotal,
  });

  @override
  Widget build(BuildContext context) {
    if (progressTotal <= 0) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Reading files: $progressRead / $progressTotal'),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progressTotal > 0 ? progressRead / progressTotal : null,
          minHeight: 8,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class EvaluateButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onEvaluate;

  const EvaluateButton({
    super.key,
    required this.isLoading,
    required this.onEvaluate,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: isLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.psychology),
      label: Text(isLoading ? 'Grading...' : 'Grade All Students'),
      onPressed: isLoading ? null : onEvaluate,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        backgroundColor: Colors.blue,
        disabledBackgroundColor: Colors.grey,
      ),
    );
  }
}

class ResultsCard extends StatelessWidget {
  final List<Map<String, dynamic>> results;
  final VoidCallback onExportToExcel;

  const ResultsCard({
    super.key,
    required this.results,
    required this.onExportToExcel,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const SizedBox.shrink();
    }

    return SectionCard(
      title: 'Results (${results.length} items)',
      trailing: ElevatedButton.icon(
        icon: const Icon(Icons.download, size: 14),
        label: const Text('Export'),
        onPressed: onExportToExcel,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          minimumSize: const Size(0, 36),
        ),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: results.length,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          final result = results[index];
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
    );
  }
}

class SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  const SectionCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _LoadedBadge extends StatelessWidget {
  final String text;

  const _LoadedBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.green[50],
        border: Border.all(color: Colors.green),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.green,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

ButtonStyle _compactButtonStyle() {
  return ElevatedButton.styleFrom(
    padding: const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
    minimumSize: const Size(0, 36),
  );
}
