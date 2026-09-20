library;

/// No isolates and no transcription mode on the web, so one is both the safe
/// answer and the true one.
int get cpuCount => 1;
