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

        AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.List(archive, new ArchiveLimits(MaxEntries: 1)),
            "List must enforce MaxEntries.");
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
        AssertThrows<ArchiveNativeException>(
            () => ArchiveClient.Create(existingArchive, sources, CompressionMethod.Stored),
            "Create must reject an existing output.");
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
