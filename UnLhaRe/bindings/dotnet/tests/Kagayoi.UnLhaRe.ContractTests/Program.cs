using System.Text;
using Kagayoi.UnLhaRe;

return ContractTests.Run();

internal static class ContractTests
{
    internal static int Run()
    {
        var root = Path.Combine(Path.GetTempPath(), $"Kagayoi.UnLhaRe-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            RunContracts(root);
            Console.WriteLine("Kagayoi.UnLhaRe managed/native contract tests passed.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static void RunContracts(string root)
    {
        var sourceDirectory = Path.Combine(root, "入力元");
        Directory.CreateDirectory(sourceDirectory);
        var firstSource = Path.Combine(sourceDirectory, "こんにちは.txt");
        var secondSource = Path.Combine(sourceDirectory, "除外.txt");
        var emptyDirectory = Path.Combine(sourceDirectory, "空ディレクトリ");
        Directory.CreateDirectory(emptyDirectory);
        const string firstContents = "こんにちは、UnLhaRe。";
        const string secondContents = "selected extraction must omit this file";
        File.WriteAllText(firstSource, firstContents, new UTF8Encoding(false));
        File.WriteAllText(secondSource, secondContents, new UTF8Encoding(false));
        var sourceModifiedAt = new DateTimeOffset(2001, 2, 3, 4, 5, 6, TimeSpan.Zero);
        File.SetLastWriteTimeUtc(firstSource, sourceModifiedAt.UtcDateTime);

        var archive = Path.Combine(root, "日本語書庫.lzh");
        var sources = new[]
        {
            new ArchiveSourceEntry(firstSource, "資料/こんにちは.txt"),
            new ArchiveSourceEntry(secondSource, "除外.txt"),
            new ArchiveSourceEntry(emptyDirectory, "空/"),
        };
        ArchiveClient.Create(archive, sources, CompressionMethod.Lh5);

        var entries = ArchiveClient.List(archive);
        Assert(entries.Count == 3, "List must return every created entry.");
        Assert(entries.Any(entry => entry.Name == "資料/こんにちは.txt"), "List lost a Unicode entry name.");
        Assert(entries.Any(entry => entry.Name == "除外.txt"), "List lost the second entry.");
        Assert(entries.Any(entry => entry.Name == "空" && entry.IsDirectory),
            "Create did not preserve an explicitly supplied empty directory.");
        var firstEntry = entries.Single(entry => entry.Name == "資料/こんにちは.txt");
        Assert(firstEntry.ModifiedUnixSeconds.HasValue, "List did not return the file modification time.");
        var firstModifiedAt = firstEntry.ModifiedAt;
        Assert(firstModifiedAt.HasValue, "The managed modification time projection was unavailable.");
        AssertTimestampClose(
            firstModifiedAt.GetValueOrDefault(),
            sourceModifiedAt,
            "List returned a different file modification time.");
        var outOfRangeEntry = new ArchiveEntry("range", "-lh0-", 0, 0, false, 0, 2)
        {
            ModifiedUnixSeconds = long.MaxValue,
        };
        Assert(outOfRangeEntry.ModifiedAt is null,
            "An out-of-range Unix timestamp must not throw or produce a managed date.");

        var listReports = 0;
        var progressEntries = ArchiveClient.List(
            archive,
            CancellationToken.None,
            progress: new InlineProgress(_ => listReports++));
        Assert(progressEntries.Count == entries.Count, "The cancellable List returned a different entry set.");
        Assert(listReports > 0, "The cancellable List did not report progress.");

        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            var reports = 0;
            var cancelled = AssertThrows<OperationCanceledException>(
                () => ArchiveClient.List(
                    archive,
                    cancellation.Token,
                    progress: new InlineProgress(_ => reports++)),
                "An initially cancelled List must fail before scanning.");
            Assert(reports == 0, "An initially cancelled List reported progress.");
            Assert(cancelled.CancellationToken == cancellation.Token,
                "The initial List cancellation token was not preserved.");
        }

        using (var cancellation = new CancellationTokenSource())
        {
            var reports = 0;
            var cancelled = AssertThrows<OperationCanceledException>(
                () => ArchiveClient.List(
                    archive,
                    cancellation.Token,
                    progress: new InlineProgress(_ =>
                    {
                        reports++;
                        cancellation.Cancel();
                    })),
                "A List progress cancellation must become OperationCanceledException.");
            Assert(reports > 0, "List did not reach its cancellation callback.");
            Assert(cancelled.CancellationToken == cancellation.Token,
                "The List cancellation token was not preserved.");
        }

        var listCallbackError = new CallbackFailureException("managed List callback failure");
        var listRethrown = AssertThrows<CallbackFailureException>(
            () => ArchiveClient.List(
                archive,
                CancellationToken.None,
                progress: new InlineProgress(_ => throw listCallbackError)),
            "A managed List callback exception must be rethrown after native return.");
        Assert(ReferenceEquals(listCallbackError, listRethrown),
            "The original List callback exception was not preserved.");

        var callerThread = Environment.CurrentManagedThreadId;
        var observedProgress = new List<ArchiveProgress>();
        ArchiveClient.Verify(
            archive,
            progress: new InlineProgress(value =>
            {
                Assert(Environment.CurrentManagedThreadId == callerThread, "Progress moved to another thread.");
                Assert((uint)value.Phase is >= 1 and <= 4,
                    $"Unexpected progress phase: {value.Phase}.");
                observedProgress.Add(value);
            }));
        Assert(observedProgress.Count > 0, "Verify did not report progress.");

        var extraction = Path.Combine(root, "選択展開");
        ArchiveClient.Extract(archive, extraction, ["資料/こんにちは.txt"]);
        Assert(
            File.ReadAllText(Path.Combine(extraction, "資料", "こんにちは.txt"), Encoding.UTF8) == firstContents,
            "The selected Unicode entry did not round-trip.");
        Assert(!File.Exists(Path.Combine(extraction, "除外.txt")), "Extract ignored selectedNames.");

        var defaultTimestampExtraction = Path.Combine(root, "既定時刻展開");
        ArchiveClient.ExtractWithOptions(
            archive,
            defaultTimestampExtraction,
            new ArchiveExtractOptions(),
            ["資料/こんにちは.txt"]);
        var defaultTimestamp = File.GetLastWriteTimeUtc(
            Path.Combine(defaultTimestampExtraction, "資料", "こんにちは.txt"));
        Assert(
            Math.Abs((defaultTimestamp - sourceModifiedAt.UtcDateTime).TotalDays) > 1,
            "ExtractWithOptions restored timestamps when PreserveTimestamps was false.");

        var preservedTimestampExtraction = Path.Combine(root, "時刻復元展開");
        ArchiveClient.ExtractWithOptions(
            archive,
            preservedTimestampExtraction,
            new ArchiveExtractOptions(PreserveTimestamps: true),
            ["資料/こんにちは.txt"]);
        AssertTimestampClose(
            File.GetLastWriteTimeUtc(Path.Combine(preservedTimestampExtraction, "資料", "こんにちは.txt")),
            sourceModifiedAt,
            "ExtractWithOptions did not restore the archived modification time.");

        var limitError = AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.List(archive, new ArchiveLimits(MaxEntries: 1)),
            "List must enforce MaxEntries.");
        Assert(limitError.Kind == ArchiveErrorKind.Limit, "List did not classify a resource-limit error.");
        AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.Verify(archive, new ArchiveLimits(MaxEntryBytes: 1)),
            "Verify must enforce MaxEntryBytes.");

        using (var cancellation = new CancellationTokenSource())
        {
            var reports = 0;
            var cancelled = AssertThrows<OperationCanceledException>(
                () => ArchiveClient.Verify(
                    archive,
                    progress: new InlineProgress(_ =>
                    {
                        reports++;
                        cancellation.Cancel();
                    }),
                    cancellationToken: cancellation.Token),
                "A callback cancellation must become OperationCanceledException.");
            Assert(reports > 0, "The cancellation callback was not reached.");
            Assert(cancelled.CancellationToken == cancellation.Token, "The cancellation token was not preserved.");
        }

        var finalizeCancelledArchive = Path.Combine(root, "finalize-cancelled.lzh");
        using (var cancellation = new CancellationTokenSource())
        {
            var reachedFinalize = false;
            var cancelled = AssertThrows<OperationCanceledException>(
                () => ArchiveClient.Create(
                    finalizeCancelledArchive,
                    sources,
                    CompressionMethod.Stored,
                    progress: new InlineProgress(value =>
                    {
                        if (value.Phase == ArchiveProgressPhase.Finalize)
                        {
                            reachedFinalize = true;
                            cancellation.Cancel();
                        }
                    }),
                    cancellationToken: cancellation.Token),
                "Cancellation requested by the final Create callback must abort publication.");
            Assert(reachedFinalize, "Create did not reach the finalize callback.");
            Assert(cancelled.CancellationToken == cancellation.Token, "The final cancellation token was not preserved.");
            Assert(!File.Exists(finalizeCancelledArchive),
                "Create published an archive after cancellation in the finalize callback.");
        }

        var callbackError = new CallbackFailureException("managed callback failure");
        var rethrown = AssertThrows<CallbackFailureException>(
            () => ArchiveClient.Verify(
                archive,
                progress: new InlineProgress(_ => throw callbackError)),
            "A managed callback exception must be rethrown after native return.");
        Assert(ReferenceEquals(callbackError, rethrown), "The original callback exception was not preserved.");

        var existingArchive = Path.Combine(root, "既存出力.lzh");
        var archiveSentinel = new byte[] { 0x55, 0x6e, 0x4c, 0x68, 0x61 };
        File.WriteAllBytes(existingArchive, archiveSentinel);
        var existsError = AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.Create(existingArchive, sources, CompressionMethod.Stored),
            "Create must reject an existing output.");
        Assert(existsError.Kind == ArchiveErrorKind.Exists, "Create did not classify an existing output.");
        Assert(File.ReadAllBytes(existingArchive).SequenceEqual(archiveSentinel),
            "Create changed an existing output after failure.");

        var protectedExtraction = Path.Combine(root, "既存展開");
        var protectedFile = Path.Combine(protectedExtraction, "資料", "こんにちは.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(protectedFile)!);
        const string extractionSentinel = "existing destination contents";
        File.WriteAllText(protectedFile, extractionSentinel, new UTF8Encoding(false));
        AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.Extract(archive, protectedExtraction, ["資料/こんにちは.txt"]),
            "Extract must reject an existing output.");
        Assert(File.ReadAllText(protectedFile, Encoding.UTF8) == extractionSentinel,
            "Extract changed an existing destination after failure.");

        VerifyCreateWithResults(root);
    }

    private static void VerifyCreateWithResults(string root)
    {
        var sourceDirectory = Path.Combine(root, "結果付き作成元");
        Directory.CreateDirectory(sourceDirectory);
        var writtenSource = Path.Combine(sourceDirectory, "Windows 名称.txt");
        var skippedSource = Path.Combine(sourceDirectory, "読取失敗.txt");
        File.WriteAllText(writtenSource, "written source", new UTF8Encoding(false));
        File.WriteAllText(skippedSource, "source removed after scanning", new UTF8Encoding(false));
        var sources = new[]
        {
            new ArchiveSourceEntry(writtenSource, "Windows 名称.txt"),
            new ArchiveSourceEntry(skippedSource, "読取失敗.txt"),
        };

        var reportArchive = Path.Combine(root, "結果付き.lzh");
        var removed = false;
        var report = ArchiveClient.CreateWithResults(
            reportArchive,
            sources,
            CompressionMethod.Stored,
            progress: new InlineProgress(value =>
            {
                if (!removed && value.Phase == ArchiveProgressPhase.Compress)
                {
                    removed = true;
                    File.Delete(skippedSource);
                }
            }));
        Assert(removed, "CreateWithResults did not reach the source-read phase.");
        Assert(File.Exists(reportArchive), "CreateWithResults did not publish the successful archive.");
        Assert(report.Entries.Count == 2, "CreateWithResults did not report every requested entry.");
        var written = report.Entries.Single(entry => entry.Name == "Windows 名称.txt");
        Assert(written.Status == ArchiveCreateEntryStatus.Written && written.Error is null,
            "CreateWithResults did not report the Windows source name as written.");
        var skipped = report.Entries.Single(entry => entry.Name == "読取失敗.txt");
        Assert(skipped.Status == ArchiveCreateEntryStatus.Skipped && !string.IsNullOrWhiteSpace(skipped.Error),
            "CreateWithResults did not report the source read failure as skipped.");
        var reportEntries = ArchiveClient.List(reportArchive);
        Assert(reportEntries.Count == 1 && reportEntries[0].Name == "Windows 名称.txt",
            "CreateWithResults wrote an unexpected set of entries.");

        var legacyNullLimitsArchive = Path.Combine(root, "null上限互換.lzh");
        var legacyNullLimitsReport = ArchiveClient.CreateWithResults(
            legacyNullLimitsArchive,
            [new ArchiveSourceEntry(writtenSource, "legacy.txt")],
            CompressionMethod.Stored,
            null);
        Assert(legacyNullLimitsReport.Entries.Single().Status == ArchiveCreateEntryStatus.Written,
            "The legacy positional null limits overload no longer resolves or succeeds.");

        var strictWrittenSource = Path.Combine(sourceDirectory, "通常成功.txt");
        var strictFailedSource = Path.Combine(sourceDirectory, "通常失敗.txt");
        File.WriteAllText(strictWrittenSource, "strict written source", new UTF8Encoding(false));
        File.WriteAllText(strictFailedSource, "strict source removed after scanning", new UTF8Encoding(false));
        var strictArchive = Path.Combine(root, "通常失敗.lzh");
        removed = false;
        AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.Create(
                strictArchive,
                [
                    new ArchiveSourceEntry(strictWrittenSource, "通常成功.txt"),
                    new ArchiveSourceEntry(strictFailedSource, "通常失敗.txt"),
                ],
                CompressionMethod.Stored,
                progress: new InlineProgress(value =>
                {
                    if (!removed && value.Phase == ArchiveProgressPhase.Compress)
                    {
                        removed = true;
                        File.Delete(strictFailedSource);
                    }
                })),
            "Create must fail when a source becomes unreadable.");
        Assert(removed, "Create did not reach the source-read phase.");
        Assert(!File.Exists(strictArchive), "Create published an archive after a source read failure.");

        var limitArchive = Path.Combine(root, "制限違反.lzh");
        AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.CreateWithResults(
                limitArchive,
                [new ArchiveSourceEntry(writtenSource, "limit.txt")],
                CompressionMethod.Stored,
                limits: new ArchiveLimits(MaxEntryBytes: 1)),
            "CreateWithResults must not skip resource-limit violations.");
        Assert(!File.Exists(limitArchive),
            "CreateWithResults published an archive after a resource-limit violation.");

        var allSkippedArchive = Path.Combine(root, "全件スキップ.lzh");
        var allSkippedError = AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.CreateWithResults(
                allSkippedArchive,
                [new ArchiveSourceEntry(Path.Combine(sourceDirectory, "存在しない.txt"), "missing.txt")],
                CompressionMethod.Stored,
                new ArchiveCreateReportOptions(FailIfAllSkipped: true)),
            "CreateWithResults must fail when every input is skipped and the option is enabled.");
        Assert(allSkippedError.Kind == ArchiveErrorKind.InvalidArgument,
            "CreateWithResults did not classify an all-skipped failure.");
        Assert(!File.Exists(allSkippedArchive),
            "CreateWithResults published an empty archive after an all-skipped failure.");
    }

    private static void AssertTimestampClose(
        DateTimeOffset actual,
        DateTimeOffset expected,
        string message)
    {
        Assert(Math.Abs((actual - expected).TotalSeconds) <= 2, message);
    }

    private static TException AssertThrows<TException>(Action action, string message)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException exception)
        {
            return exception;
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                $"{message} Expected {typeof(TException).Name}, received {exception.GetType().Name}.",
                exception);
        }
        throw new InvalidOperationException($"{message} Expected {typeof(TException).Name}, but no exception was thrown.");
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed class InlineProgress(Action<ArchiveProgress> report) : IProgress<ArchiveProgress>
    {
        public void Report(ArchiveProgress value) => report(value);
    }

    private sealed class CallbackFailureException(string message) : Exception(message);
}
