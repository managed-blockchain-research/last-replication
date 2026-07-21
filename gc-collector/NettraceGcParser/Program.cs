using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Parsers.Clr;

if (args.Length < 1)
{
    Console.Error.WriteLine($"Usage: NettraceGcParser <file.nettrace> [--csv]");
    return 1;
}

string path = args[0];
bool csvMode = args.Length > 1 && args[1] == "--csv";

if (!File.Exists(path))
{
    Console.Error.WriteLine($"ERROR: file not found: {path}");
    return 1;
}

int gen0 = 0, gen1 = 0, gen2 = 0;
double firstTs = -1, lastTs = 0;
int totalSuspend = 0;
double totalPauseMs = 0;
double suspendStart = 0;
int currentGen = -1;
var pauseEvents = new List<(int gen, double pauseMs)>();

using var source = new EventPipeEventSource(path);
var clrParser = new ClrTraceEventParser(source);

clrParser.GCStart += e =>
{
    if (firstTs < 0) firstTs = e.TimeStampRelativeMSec;
    lastTs = e.TimeStampRelativeMSec;
    currentGen = e.Depth;
    switch (e.Depth)
    {
        case 0: gen0++; break;
        case 1: gen1++; break;
        case 2: gen2++; break;
    }
};

clrParser.GCSuspendEEStop += e =>
{
    suspendStart = e.TimeStampRelativeMSec;
};

clrParser.GCRestartEEStart += e =>
{
    if (suspendStart > 0)
    {
        double pauseMs = e.TimeStampRelativeMSec - suspendStart;
        totalPauseMs += pauseMs;
        totalSuspend++;
        pauseEvents.Add((currentGen, pauseMs));
        suspendStart = 0;
    }
    lastTs = e.TimeStampRelativeMSec;
};

source.Process();

int total = gen0 + gen1 + gen2;
double durS = (lastTs - (firstTs < 0 ? 0 : firstTs)) / 1000.0;

if (csvMode)
{
    Console.WriteLine("gen,pause_ms");
    foreach (var (gen, pauseMs) in pauseEvents)
        Console.WriteLine($"{gen},{pauseMs:F2}");
}
else
{
    Console.WriteLine($"gen0_gc_count={gen0}");
    Console.WriteLine($"gen1_gc_count={gen1}");
    Console.WriteLine($"gen2_gc_count={gen2}");
    Console.WriteLine($"total_gc_count={total}");
    Console.WriteLine($"trace_duration_s={durS:F1}");
    Console.WriteLine($"total_pause_count={totalSuspend}");
    Console.WriteLine($"total_pause_ms={totalPauseMs:F1}");
    if (totalSuspend > 0)
        Console.WriteLine($"avg_pause_ms={totalPauseMs / totalSuspend:F2}");
    else
        Console.WriteLine("avg_pause_ms=0.00");
}

return 0;
