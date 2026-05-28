# App Capabilities and Code Entry Points

This list maps user-visible app actions to the main functions that implement them.

## App startup and screen rendering
- Launch the app: main() -> MyApp.build() -> ScoringPage.createState()
- Render the scoring screen: _ScoringPageState.build()

## Load student submissions
- Pick a folder of .txt files: _ScoringPageState._pickSubmissionFile()
- Read and list student files: FileService.listStudentFiles()
- Parse text blocks (when files are combined): _ScoringPageState._parseStudentBlocks()

## Load grading criteria
- Pick criteria file (.txt or .docx): _ScoringPageState._pickCriteriaFile()
- Read DOCX and extract text: FileService.readDocxFile() -> FileService._decodeXmlEntities()

## Grade submissions with AI
- Start grading workflow: _ScoringPageState._evaluateWithAI()
- Batch grade a folder: BatchService.gradeFolder()
- Retry AI calls on failure: BatchService._callWithRetry()
- Build prompt and send grading request: AIService.buildPrompt() -> AIService.evaluateSubmissions() -> AIService._callGroqChatCompletions()
- Parse model JSON: AIService._parseJsonArray() / AIService._stripCodeFence()
- Normalize results for export: _ScoringPageState._normalizeResults()

## Track progress and show results
- Update progress counters: _ScoringPageState._evaluateWithAI()
- Render progress bar: ProgressSection.build()
- Render results list: ResultsCard.build()
- Show messages: _ScoringPageState._showSnackBar()

## Export results to Excel
- Choose output path: _ScoringPageState._pickExportPath()
- Export to new file: _ScoringPageState._exportToExcel() -> ExcelService.exportResults()
- Export detailed report: ExcelService.exportDetailedResults()
- Fill an existing template: _ScoringPageState._pickTemplateFile() -> ExcelService.fillTemplate()
- Match template headers: ExcelService._findSheetWithHeaders() -> ExcelService._mapHeaderRow() / ExcelService._mapTwoHeaderRows()
- Write rows and scale scores: ExcelService._writeRow() -> ExcelService._scaledScore()

## Optional UI actions
- Pick question image: _ScoringPageState._pickQuestionImage() -> QuestionImageCard.build()
- Load template button: TemplateExcelCard.build()
- Load submissions button: SubmissionsCard.build()
- Load criteria button: CriteriaCard.build()
- Export button: ResultsCard.build()
- Button styling: _compactButtonStyle()
