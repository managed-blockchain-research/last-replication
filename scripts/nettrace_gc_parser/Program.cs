using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.EventPipe;
using Microsoft.Diagnostics.Tracing.Parsers;

namespace NettraceGcParser
{
    internal static class Program
    {
        private static void Main(string[] args)
        {
            if (args.Length < 2)
            {
                Console.WriteLine("Usage: dotnet run -- <trace.nettrace> <output.json>");
                return;
            }

            var tracePath = args[0];
            var outputPath = args[1];

            if (!File.Exists(tracePath))
            {
                Console.Error.WriteLine($"Trace not found: {tracePath}");
                Environment.Exit(1);
            }

            var gcStart = new Dictionary<int, double>();
            var gcTypeByCount = new Dictionary<int, string>();
            var gcPauseMs = new List<double>();
            var gen2Count = 0;
            var fullBlockingCount = 0;
            double totalGcPauseMs = 0;

            double minTs = double.MaxValue;
            double maxTs = 0;

            long eventCount = 0;
            long gcDynamicEvents = 0;

            double? maxLohSize = null;
            double? maxLohFragmentation = null;
            double? lastLohSize = null;
            double? lastLohFragmentation = null;

            var counterValues = new Dictionary<string, List<double>>(StringComparer.OrdinalIgnoreCase)
            {
                ["loh-size"] = new List<double>(),
                ["gen-2-size"] = new List<double>(),
                ["time-in-gc"] = new List<double>()
            };

            void UpdateTs(TraceEvent data)
            {
                var ts = data.TimeStampRelativeMSec;
                if (ts < minTs) minTs = ts;
                if (ts > maxTs) maxTs = ts;
            }

            try
            {
            using var source = new EventPipeEventSource(tracePath);
            var clr = new ClrTraceEventParser(source);

            clr.GCStart += data =>
            {
                UpdateTs(data);
                gcStart[data.Count] = data.TimeStampRelativeMSec;

                var gen = GetPayloadInt(data, new[]
                {
                    "Generation",
                    "GenerationToCollect",
                    "Gen"
                });
                if (gen.HasValue && gen.Value == 2)
                {
                    gen2Count++;
                }

                var typeText = GetPayloadString(data, new[] { "Type", "GCType" }) ?? string.Empty;
                gcTypeByCount[data.Count] = typeText;
                if (typeText.Contains("NonConcurrent", StringComparison.OrdinalIgnoreCase) ||
                    typeText.Contains("Blocking", StringComparison.OrdinalIgnoreCase))
                {
                    fullBlockingCount++;
                }
            };

            clr.GCStop += data =>
            {
                UpdateTs(data);
                if (gcStart.TryGetValue(data.Count, out var start))
                {
                    var dur = data.TimeStampRelativeMSec - start;
                    if (dur >= 0)
                    {
                        gcPauseMs.Add(dur);
                        totalGcPauseMs += dur;
                    }
                }
            };

            clr.GCHeapStats += data =>
            {
                UpdateTs(data);
                var lohSize = GetPayloadDouble(data, new[]
                {
                    "LargeObjectHeapSize",
                    "LOHSize",
                    "Gen3Size"
                });

                var lohFrag = GetPayloadDouble(data, new[]
                {
                    "LOHFragmentation",
                    "LOHFragmentationPercent",
                    "LargeObjectHeapFragmentation"
                });

                if (lohSize.HasValue)
                {
                    lastLohSize = lohSize;
                    maxLohSize = maxLohSize.HasValue ? Math.Max(maxLohSize.Value, lohSize.Value) : lohSize.Value;
                }

                if (lohFrag.HasValue)
                {
                    lastLohFragmentation = lohFrag;
                    maxLohFragmentation = maxLohFragmentation.HasValue ? Math.Max(maxLohFragmentation.Value, lohFrag.Value) : lohFrag.Value;
                }
            };

            source.Dynamic.All += data =>
            {
                eventCount++;
                UpdateTs(data);
                if (!data.EventName.Contains("GC", StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                gcDynamicEvents++;
                if (data.EventName.Contains("GCStart", StringComparison.OrdinalIgnoreCase))
                {
                    var count = GetPayloadInt(data, new[] { "Count", "GCNumber", "GCIndex" });
                    if (count.HasValue)
                    {
                        gcStart[count.Value] = data.TimeStampRelativeMSec;
                        var gen = GetPayloadInt(data, new[] { "Generation", "GenerationToCollect", "Gen" });
                        if (gen.HasValue && gen.Value == 2)
                        {
                            gen2Count++;
                        }
                        var typeText = GetPayloadString(data, new[] { "Type", "GCType" }) ?? string.Empty;
                        gcTypeByCount[count.Value] = typeText;
                        if (typeText.Contains("NonConcurrent", StringComparison.OrdinalIgnoreCase) ||
                            typeText.Contains("Blocking", StringComparison.OrdinalIgnoreCase))
                        {
                            fullBlockingCount++;
                        }
                    }
                }
                else if (data.EventName.Contains("GCEnd", StringComparison.OrdinalIgnoreCase) ||
                         data.EventName.Contains("GCStop", StringComparison.OrdinalIgnoreCase))
                {
                    var count = GetPayloadInt(data, new[] { "Count", "GCNumber", "GCIndex" });
                    if (count.HasValue && gcStart.TryGetValue(count.Value, out var start))
                    {
                        var dur = data.TimeStampRelativeMSec - start;
                        if (dur >= 0)
                        {
                            gcPauseMs.Add(dur);
                            totalGcPauseMs += dur;
                        }
                    }
                }

                if (data.EventName.Contains("GCHeapStats", StringComparison.OrdinalIgnoreCase))
                {
                    var lohSize = GetPayloadDouble(data, new[]
                    {
                        "LargeObjectHeapSize",
                        "LOHSize",
                        "Gen3Size"
                    });
                    var lohFrag = GetPayloadDouble(data, new[]
                    {
                        "LOHFragmentation",
                        "LOHFragmentationPercent",
                        "LargeObjectHeapFragmentation"
                    });
                    if (lohSize.HasValue)
                    {
                        lastLohSize = lohSize;
                        maxLohSize = maxLohSize.HasValue ? Math.Max(maxLohSize.Value, lohSize.Value) : lohSize.Value;
                    }
                    if (lohFrag.HasValue)
                    {
                        lastLohFragmentation = lohFrag;
                        maxLohFragmentation = maxLohFragmentation.HasValue ? Math.Max(maxLohFragmentation.Value, lohFrag.Value) : lohFrag.Value;
                    }
                }

                if (data.ProviderName.Equals("System.Runtime", StringComparison.OrdinalIgnoreCase) &&
                    data.EventName.Equals("EventCounters", StringComparison.OrdinalIgnoreCase))
                {
                    var payload = data.PayloadByName("Payload");
                    string? counterName = null;
                    double? counterValue = null;

                    if (payload is System.Collections.IDictionary dict)
                    {
                        counterName = dict["Name"]?.ToString();
                        if (dict.Contains("Mean"))
                        {
                            counterValue = ToDouble(dict["Mean"]);
                        }
                        else if (dict.Contains("Increment"))
                        {
                            counterValue = ToDouble(dict["Increment"]);
                        }
                    }
                    else
                    {
                        counterName = GetPayloadString(data, new[] { "Name" });
                        if (counterName != null)
                        {
                            var mean = GetPayloadDouble(data, new[] { "Mean" });
                            var increment = GetPayloadDouble(data, new[] { "Increment" });
                            counterValue = mean ?? increment;
                        }
                    }

                    if (counterName != null && counterValue.HasValue &&
                        counterValues.TryGetValue(counterName, out var list))
                    {
                        list.Add(counterValue.Value);
                    }
                }
            };

            source.Process();

            var totalRuntimeMs = maxTs > minTs ? (maxTs - minTs) : 0;
            var timeInGcPercent = totalRuntimeMs > 0 ? (totalGcPauseMs / totalRuntimeMs) * 100.0 : 0.0;

            var summary = new Dictionary<string, object?>
            {
                ["trace"] = tracePath,
                ["total_runtime_ms"] = totalRuntimeMs,
                ["gc_pause_total_ms"] = totalGcPauseMs,
                ["time_in_gc_percent"] = timeInGcPercent,
                ["gc_pause_p95_ms"] = Percentile(gcPauseMs, 95),
                ["gc_pause_p99_ms"] = Percentile(gcPauseMs, 99),
                ["gc_pause_max_ms"] = gcPauseMs.Count > 0 ? gcPauseMs.Max() : null,
                ["gen2_gc_count"] = gen2Count,
                ["full_blocking_gc_count"] = fullBlockingCount,
                ["event_count"] = eventCount,
                ["gc_dynamic_events"] = gcDynamicEvents,
                ["loh_size_bytes_max"] = maxLohSize,
                ["loh_fragmentation_max"] = maxLohFragmentation,
                ["loh_size_bytes_last"] = lastLohSize,
                ["loh_fragmentation_last"] = lastLohFragmentation,
                ["event_counters"] = new Dictionary<string, object?>
                {
                    ["loh_size_bytes_avg"] = Average(counterValues["loh-size"]),
                    ["loh_size_bytes_max"] = Max(counterValues["loh-size"]),
                    ["gen2_size_bytes_avg"] = Average(counterValues["gen-2-size"]),
                    ["gen2_size_bytes_max"] = Max(counterValues["gen-2-size"]),
                    ["time_in_gc_percent_avg"] = Average(counterValues["time-in-gc"]),
                    ["time_in_gc_percent_max"] = Max(counterValues["time-in-gc"])
                }
            };

            File.WriteAllText(outputPath, System.Text.Json.JsonSerializer.Serialize(summary, new System.Text.Json.JsonSerializerOptions
            {
                WriteIndented = true
            }));
            Console.WriteLine($"Wrote GC summary: {outputPath}");
            }
            catch (Exception ex)
            {
                WriteErrorSummary(outputPath, tracePath,
                    ex is System.FormatException || ex.Message.Contains("read") || ex.Message.Contains("stream")
                        ? "Trace file truncated or corrupted (ensure dotnet-trace was not killed before flush)"
                        : "Failed to parse trace", ex);
                Environment.Exit(1);
            }
        }

        private static void WriteErrorSummary(string outputPath, string tracePath, string message, Exception ex)
        {
            var errorSummary = new Dictionary<string, object?>
            {
                ["error"] = message,
                ["trace"] = tracePath,
                ["exception_type"] = ex.GetType().FullName,
                ["exception_message"] = ex.Message
            };
            try
            {
                File.WriteAllText(outputPath, System.Text.Json.JsonSerializer.Serialize(errorSummary, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
                Console.Error.WriteLine($"Error: {message}. Wrote error summary to {outputPath}");
            }
            catch
            {
                Console.Error.WriteLine($"Error: {message}. Exception: {ex}");
            }
        }

        private static double? GetPayloadDouble(TraceEvent data, string[] names)
        {
            foreach (var name in names)
            {
                try
                {
                    var value = data.PayloadByName(name);
                    if (value == null) continue;
                    if (value is double d) return d;
                    if (value is float f) return f;
                    if (value is long l) return l;
                    if (value is int i) return i;
                    if (double.TryParse(value.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
                    {
                        return parsed;
                    }
                }
                catch
                {
                    // ignore missing payload
                }
            }
            return null;
        }

        private static int? GetPayloadInt(TraceEvent data, string[] names)
        {
            foreach (var name in names)
            {
                try
                {
                    var value = data.PayloadByName(name);
                    if (value == null) continue;
                    if (value is int i) return i;
                    if (value is long l) return (int)l;
                    if (int.TryParse(value.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
                    {
                        return parsed;
                    }
                }
                catch
                {
                    // ignore missing payload
                }
            }
            return null;
        }

        private static string? GetPayloadString(TraceEvent data, string[] names)
        {
            foreach (var name in names)
            {
                try
                {
                    var value = data.PayloadByName(name);
                    if (value == null) continue;
                    return value.ToString();
                }
                catch
                {
                    // ignore missing payload
                }
            }
            return null;
        }

        private static double? Percentile(List<double> values, double p)
        {
            if (values.Count == 0) return null;
            var ordered = values.OrderBy(v => v).ToArray();
            var k = (ordered.Length - 1) * (p / 100.0);
            var f = (int)Math.Floor(k);
            var c = (int)Math.Ceiling(k);
            if (f == c) return ordered[f];
            return ordered[f] * (c - k) + ordered[c] * (k - f);
        }

        private static double? Average(List<double> values)
        {
            if (values.Count == 0) return null;
            return values.Average();
        }

        private static double? Max(List<double> values)
        {
            if (values.Count == 0) return null;
            return values.Max();
        }

        private static double? ToDouble(object? value)
        {
            if (value == null) return null;
            if (value is double d) return d;
            if (value is float f) return f;
            if (value is long l) return l;
            if (value is int i) return i;
            if (double.TryParse(value.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
            {
                return parsed;
            }
            return null;
        }
    }
}
