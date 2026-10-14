# Import CSV reports

In **All reports**, choose **Import reports…** and select one or more CSV files exported by NetworkPortEval. The **Source computer (optional)** field applies to the selected files.

Reports are saved in the current reports folder. The **Imported** badge distinguishes their results from local tests. The overview shows the source file, import date, entered computer name and original network metadata. Importing a report never starts a network test.

Historical English and French CSV files are accepted. Translated statuses in supported languages are normalized. New CSV files contain a report identifier and format version. Duplicates are detected by that identifier or, for older files, by the fingerprint of normalized CSV content. Two different exports of an older report without an identifier may be treated as distinct.

Limits are 5 MB and 10,000 result rows per file. An invalid file is not partially saved; when multiple files are selected, other valid files can still be imported. Flow templates are not reports and are rejected here.

The historical format contains aggregated network context and a text summary of Internet checks. This information is preserved in the provenance without inventing per-attempt network observations. Names and comments from the original report are not translated. Source metadata is preserved when exporting again to CSV, PDF, TXT or JSON.
