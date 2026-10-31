using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

namespace KhcCpuWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RawFileTime
    {
        public uint Low;
        public uint High;
        public ulong Value { get { return checked(((ulong)High << 32) + (ulong)Low); } }
        // JSON を読む側で浮動小数点へ丸めないため、整数の十進文字列も保持する。
        public string Decimal { get { return Value.ToString(CultureInfo.InvariantCulture); } }
    }

    public sealed class Snapshot
    {
        public RawFileTime Idle;
        public RawFileTime Kernel;
        public RawFileTime User;
        public long ApiStartTicks;
        public long ApiEndTicks;
        public string ApiStartUtc;
        public string ApiEndUtc;
        public int LogicalProcessors;
    }

    public sealed class Delta
    {
        public string Idle100ns;
        public string Kernel100ns;
        public string User100ns;
        public string Total100ns;
        public string Busy100ns;
        public double BusyPercent;
        public bool AtOrBelow15PercentExact;
        public double WindowMinimumMs;
        public double WindowMaximumMs;
    }

    public static class NativeTimes
    {
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemTimes(out RawFileTime idle, out RawFileTime kernel, out RawFileTime user);

        private static void AssertCpuCount(int count)
        {
            if (count < 1 || count > 64) throw new ArgumentOutOfRangeException("count", "Logical CPU count must be 1..64.");
        }

        public static Snapshot Capture(int logicalProcessors)
        {
            AssertCpuCount(logicalProcessors);
            var snapshot = new Snapshot { LogicalProcessors = logicalProcessors };
            snapshot.ApiStartUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            snapshot.ApiStartTicks = Stopwatch.GetTimestamp();
            bool ok = GetSystemTimes(out snapshot.Idle, out snapshot.Kernel, out snapshot.User);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            snapshot.ApiEndTicks = Stopwatch.GetTimestamp();
            snapshot.ApiEndUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            if (!ok) throw new Win32Exception(error, "GetSystemTimes failed.");
            if (snapshot.ApiEndTicks < snapshot.ApiStartTicks) throw new InvalidOperationException("Stopwatch moved backwards.");
            return snapshot;
        }

        public static Delta Calculate(Snapshot start, Snapshot end)
        {
            if (start == null || end == null) throw new ArgumentNullException("snapshot");
            AssertCpuCount(start.LogicalProcessors);
            if (end.LogicalProcessors != start.LogicalProcessors) throw new InvalidOperationException("CPU count changed.");
            long minimumTicks = checked(end.ApiStartTicks - start.ApiEndTicks);
            long maximumTicks = checked(end.ApiEndTicks - start.ApiStartTicks);
            if (start.ApiEndTicks < start.ApiStartTicks || end.ApiEndTicks < end.ApiStartTicks || minimumTicks < 0 || maximumTicks < minimumTicks)
                throw new InvalidOperationException("Invalid or overlapping snapshot boundaries.");
            double minimumMs = checked((double)minimumTicks) * 1000.0 / checked((double)Stopwatch.Frequency);
            double maximumMs = checked((double)maximumTicks) * 1000.0 / checked((double)Stopwatch.Frequency);
            if (!double.IsFinite(minimumMs) || !double.IsFinite(maximumMs)) throw new InvalidOperationException("Non-finite window duration.");
            if (end.Idle.Value < start.Idle.Value || end.Kernel.Value < start.Kernel.Value || end.User.Value < start.User.Value)
                throw new InvalidOperationException("System CPU counter moved backwards.");
            ulong idle = checked(end.Idle.Value - start.Idle.Value);
            ulong kernel = checked(end.Kernel.Value - start.Kernel.Value);
            ulong user = checked(end.User.Value - start.User.Value);
            ulong total = checked(kernel + user);
            if (total == 0 || idle > total) throw new InvalidOperationException("Invalid system CPU total or idle delta.");
            ulong busy = checked(total - idle);
            double percent = 100.0 * checked((double)busy) / checked((double)total);
            if (!double.IsFinite(percent) || percent < 0 || percent > 100) throw new InvalidOperationException("Invalid busy percentage.");
            if (minimumMs < 1000.0) throw new InvalidOperationException("CPU window must span at least 1000 ms between API boundaries.");
            // ulong最大値の100倍もdecimalに収まり、15%境界を丸めず比較できる。
            bool exact = checked((decimal)busy * 100m) <= checked((decimal)total * 15m);
            return new Delta {
                Idle100ns = idle.ToString(CultureInfo.InvariantCulture), Kernel100ns = kernel.ToString(CultureInfo.InvariantCulture),
                User100ns = user.ToString(CultureInfo.InvariantCulture), Total100ns = total.ToString(CultureInfo.InvariantCulture),
                Busy100ns = busy.ToString(CultureInfo.InvariantCulture), BusyPercent = percent, AtOrBelow15PercentExact = exact,
                WindowMinimumMs = minimumMs, WindowMaximumMs = maximumMs
            };
        }
    }
}
