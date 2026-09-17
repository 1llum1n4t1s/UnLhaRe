using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Kagayoi.UnLhaRe;

/// <summary>Provides synchronous UTF-8 access to the native UnLhaRe library.</summary>
public static unsafe class ArchiveClient
{
    private const uint RequiredAbiVersion = 1;
    private const uint RequiredApiLevel = 2;
    private const uint RequiredResultCallbackApiLevel = 3;
    private const int StatusOk = 0;
    private const int StatusBufferTooSmall = 2;
    private const int StatusCancelled = 5;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly Lazy<uint> NativeApiLevel = new(LoadNativeApiLevel);

    /// <summary>Lists all entries in an archive.</summary>
    public static IReadOnlyList<ArchiveEntry> List(
        string archive,
        ArchiveLimits? limits = null)
    {
        ValidateText(archive, nameof(archive));
        EnsureNativeCompatibility();

        var request = new ListRequest(archive, LimitsRequest.From(limits));
        var jsonRequest = JsonSerializer.Serialize(request, ArchiveJsonContext.Default.ListRequest);
        var json = ReadListJson(jsonRequest);
        return JsonSerializer.Deserialize(json, ArchiveJsonContext.Default.ArchiveEntryArray)
            ?? throw new InvalidDataException("The native entry list was JSON null.");
    }

    /// <summary>Lists all entries in one scan with synchronous progress and cancellation.</summary>
    public static IReadOnlyList<ArchiveEntry> List(
        string archive,
        CancellationToken cancellationToken,
        ArchiveLimits? limits = null,
        IProgress<ArchiveProgress>? progress = null)
    {
        ValidateText(archive, nameof(archive));
        var request = new ListRequest(archive, LimitsRequest.From(limits));
        return RunWithResult(
            request,
            ArchiveJsonContext.Default.ListRequest,
            ArchiveJsonContext.Default.ArchiveEntryArray,
            NativeResultOperation.List,
            progress,
            cancellationToken);
    }

    /// <summary>Verifies every selected archive payload and reports progress synchronously.</summary>
    public static void Verify(
        string archive,
        ArchiveLimits? limits = null,
        IProgress<ArchiveProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ValidateText(archive, nameof(archive));
        var request = new VerifyRequest("verify", archive, LimitsRequest.From(limits));
        Run(request, ArchiveJsonContext.Default.VerifyRequest, progress, cancellationToken);
    }

    /// <summary>Extracts all entries, or only the names supplied in <paramref name="selectedNames"/>.</summary>
    public static void Extract(
        string archive,
        string destination,
        IReadOnlyList<string>? selectedNames = null,
        ArchiveLimits? limits = null,
        IProgress<ArchiveProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ValidateText(archive, nameof(archive));
        ValidateText(destination, nameof(destination));
        var entries = CopyStrings(selectedNames, nameof(selectedNames));
        var request = new ExtractRequest(
            "extract",
            archive,
            destination,
            entries,
            LimitsRequest.From(limits));
        Run(request, ArchiveJsonContext.Default.ExtractRequest, progress, cancellationToken);
    }

    /// <summary>Extracts entries using explicitly selected extraction behavior.</summary>
    public static void ExtractWithOptions(
        string archive,
        string destination,
        ArchiveExtractOptions options,
        IReadOnlyList<string>? selectedNames = null,
        ArchiveLimits? limits = null,
        IProgress<ArchiveProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ValidateText(archive, nameof(archive));
        ValidateText(destination, nameof(destination));
        ArgumentNullException.ThrowIfNull(options);
        var entries = CopyStrings(selectedNames, nameof(selectedNames));
        var request = new ExtractWithOptionsRequest(
            "extract",
            archive,
            destination,
            entries,
            LimitsRequest.From(limits),
            options.PreserveTimestamps);
        Run(
            request,
            ArchiveJsonContext.Default.ExtractWithOptionsRequest,
            progress,
            cancellationToken,
            RequiredResultCallbackApiLevel);
    }

    /// <summary>Creates a new archive from explicitly named source entries.</summary>
    public static void Create(
        string output,
        IReadOnlyList<ArchiveSourceEntry> entries,
        CompressionMethod method,
        ArchiveLimits? limits = null,
        IProgress<ArchiveProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var request = BuildCreateRequest(output, entries, method, limits);
        Run(request, ArchiveJsonContext.Default.CreateRequest, progress, cancellationToken);
    }

    /// <summary>Creates an archive while reporting unreadable source entries that were skipped.</summary>
    public static ArchiveCreateReport CreateWithResults(
        string output,
        IReadOnlyList<ArchiveSourceEntry> entries,
        CompressionMethod method,
        ArchiveLimits? limits = null,
        IProgress<ArchiveProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var request = BuildCreateRequest(output, entries, method, limits);
        return RunWithResult(
            request,
            ArchiveJsonContext.Default.CreateRequest,
            ArchiveJsonContext.Default.ArchiveCreateReport,
            NativeResultOperation.Create,
            progress,
            cancellationToken);
    }

    private static void Run<TRequest>(
        TRequest request,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TRequest> jsonType,
        IProgress<ArchiveProgress>? progress,
        CancellationToken cancellationToken,
        uint requiredApiLevel = RequiredApiLevel)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureNativeCompatibility(requiredApiLevel);

        var json = JsonSerializer.Serialize(request, jsonType);
        CallbackState? state = null;
        GCHandle stateHandle = default;
        nint callback = 0;
        nint user = 0;
        if (progress is not null || cancellationToken.CanBeCanceled)
        {
            state = new CallbackState(progress, cancellationToken);
            stateHandle = GCHandle.Alloc(state);
            user = GCHandle.ToIntPtr(stateHandle);
            callback = (nint)(delegate* unmanaged[Cdecl]<nint, uint, ulong, ulong, int>)&ReportProgress;
        }

        int status;
        try
        {
            status = NativeMethods.RunJson(json, callback, user);
        }
        catch (EntryPointNotFoundException exception)
        {
            throw ApiLevelException(requiredApiLevel, exception);
        }
        finally
        {
            if (stateHandle.IsAllocated)
            {
                stateHandle.Free();
            }
        }

        state?.CallbackException?.Throw();
        if (status == StatusCancelled)
        {
            throw new OperationCanceledException(ReadLastError(), cancellationToken);
        }
        ThrowForStatus(status);
    }

    private static TResult RunWithResult<TRequest, TResult>(
        TRequest request,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TRequest> requestJsonType,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TResult> resultJsonType,
        NativeResultOperation operation,
        IProgress<ArchiveProgress>? progress,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureNativeCompatibility(RequiredResultCallbackApiLevel);

        var json = JsonSerializer.Serialize(request, requestJsonType);
        var state = new CallbackState(progress, cancellationToken);
        var stateHandle = GCHandle.Alloc(state);
        var user = GCHandle.ToIntPtr(stateHandle);
        var progressCallback = progress is not null || cancellationToken.CanBeCanceled
            ? (nint)(delegate* unmanaged[Cdecl]<nint, uint, ulong, ulong, int>)&ReportProgress
            : 0;
        var resultCallback = (nint)(delegate* unmanaged[Cdecl]<nint, byte*, ulong, void>)&CaptureJson;

        int status;
        try
        {
            status = operation switch
            {
                NativeResultOperation.List =>
                    NativeMethods.ListJsonWithProgress(json, progressCallback, resultCallback, user),
                NativeResultOperation.Create =>
                    NativeMethods.CreateJsonReport(json, progressCallback, resultCallback, user),
                _ => throw new ArgumentOutOfRangeException(nameof(operation)),
            };
        }
        catch (EntryPointNotFoundException exception)
        {
            throw ApiLevelException(RequiredResultCallbackApiLevel, exception);
        }
        finally
        {
            stateHandle.Free();
        }

        state.CallbackException?.Throw();
        if (status == StatusCancelled)
        {
            throw new OperationCanceledException(ReadLastError(), cancellationToken);
        }
        ThrowForStatus(status);

        var resultJson = state.ResultJson
            ?? throw new InvalidDataException("The native operation succeeded without returning JSON.");
        return JsonSerializer.Deserialize(resultJson, resultJsonType)
            ?? throw new InvalidDataException("The native operation returned JSON null.");
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int ReportProgress(nint user, uint phase, ulong completed, ulong total)
    {
        try
        {
            var state = (CallbackState?)GCHandle.FromIntPtr(user).Target;
            if (state is null)
            {
                return 1;
            }
            if (state.CancellationToken.IsCancellationRequested)
            {
                return 1;
            }

            state.Progress?.Report(new ArchiveProgress((ArchiveProgressPhase)phase, completed, total));
            return state.CancellationToken.IsCancellationRequested ? 1 : 0;
        }
        catch (Exception exception)
        {
            try
            {
                var state = (CallbackState?)GCHandle.FromIntPtr(user).Target;
                state?.SaveException(exception);
            }
            catch
            {
                // No managed exception may escape through the native callback boundary.
            }
            return 1;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void CaptureJson(nint user, byte* json, ulong length)
    {
        CallbackState? state = null;
        try
        {
            state = (CallbackState?)GCHandle.FromIntPtr(user).Target
                ?? throw new InvalidDataException("The native JSON callback received no managed state.");
            if (json is null && length != 0)
            {
                throw new InvalidDataException("The native JSON callback returned a null buffer.");
            }
            if (length > (ulong)Array.MaxLength)
            {
                throw new InvalidDataException(
                    $"The native JSON callback length {length} is outside the supported managed buffer range.");
            }

            state.SaveResultJson(new ReadOnlySpan<byte>(json, checked((int)length)).ToArray());
        }
        catch (Exception exception)
        {
            try
            {
                state ??= (CallbackState?)GCHandle.FromIntPtr(user).Target;
                state?.SaveException(exception);
            }
            catch
            {
                // No managed exception may escape through the native callback boundary.
            }
        }
    }

    private static CreateRequest BuildCreateRequest(
        string output,
        IReadOnlyList<ArchiveSourceEntry> entries,
        CompressionMethod method,
        ArchiveLimits? limits)
    {
        ValidateText(output, nameof(output));
        ArgumentNullException.ThrowIfNull(entries);
        if (!Enum.IsDefined(method))
        {
            throw new ArgumentOutOfRangeException(nameof(method), method, "Unsupported compression method.");
        }

        var requestEntries = new SourceRequest[entries.Count];
        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index]
                ?? throw new ArgumentException("Source entries must not contain null.", nameof(entries));
            ValidateText(entry.Path, $"{nameof(entries)}[{index}].{nameof(entry.Path)}");
            ValidateText(entry.Name, $"{nameof(entries)}[{index}].{nameof(entry.Name)}");
            requestEntries[index] = new SourceRequest(entry.Path, entry.Name);
        }

        return new CreateRequest(
            "create",
            output,
            requestEntries,
            (int)method,
            LimitsRequest.From(limits));
    }

    private static byte[] ReadListJson(string request)
    {
        ulong required;
        int status;
        try
        {
            status = NativeMethods.ListJsonEx(request, null, 0, out required);
        }
        catch (EntryPointNotFoundException exception)
        {
            throw ApiLevelException(RequiredApiLevel, exception);
        }
        if (status != StatusBufferTooSmall && status != StatusOk)
        {
            ThrowForStatus(status);
        }

        var length = CheckedBufferLength(required, "entry list");
        var buffer = new byte[length];
        fixed (byte* output = buffer)
        {
            status = NativeMethods.ListJsonEx(request, output, (ulong)buffer.Length, out required);
        }
        ThrowForStatus(status);

        length = CheckedBufferLength(required, "entry list");
        if (length > buffer.Length)
        {
            throw new InvalidDataException("The native entry list grew beyond the queried buffer size.");
        }
        if (buffer[length - 1] != 0)
        {
            throw new InvalidDataException("The native entry list was not NUL-terminated.");
        }

        var json = StrictUtf8.GetString(buffer.AsSpan(0, length - 1));
        return StrictUtf8.GetBytes(json);
    }

    private static void ThrowForStatus(int status)
    {
        if (status != StatusOk)
        {
            throw new ArchiveNativeException(status, ReadLastError());
        }
    }

    private static string ReadLastError()
    {
        try
        {
            var status = NativeMethods.LastError(null, 0, out var required);
            if (status != StatusBufferTooSmall && status != StatusOk)
            {
                return $"The native operation failed, and its error text could not be read (status {status}).";
            }

            var length = CheckedBufferLength(required, "native error");
            var buffer = new byte[length];
            fixed (byte* output = buffer)
            {
                status = NativeMethods.LastError(output, (ulong)buffer.Length, out required);
            }
            if (status != StatusOk)
            {
                return $"The native operation failed, and its error text could not be copied (status {status}).";
            }

            length = CheckedBufferLength(required, "native error");
            if (length > buffer.Length || buffer[length - 1] != 0)
            {
                return "The native operation failed and returned malformed error text.";
            }
            return StrictUtf8.GetString(buffer.AsSpan(0, length - 1));
        }
        catch (Exception exception) when (exception is not ArchiveNativeException)
        {
            return $"The native operation failed, and its error text could not be read: {exception.Message}";
        }
    }

    private static int CheckedBufferLength(ulong required, string description)
    {
        if (required == 0 || required > (ulong)Array.MaxLength)
        {
            throw new InvalidDataException(
                $"The native {description} length {required} is outside the supported managed buffer range.");
        }
        return checked((int)required);
    }

    private static void EnsureNativeCompatibility(uint requiredApiLevel = RequiredApiLevel)
    {
        var apiLevel = NativeApiLevel.Value;
        if (apiLevel < requiredApiLevel)
        {
            throw new NotSupportedException(
                $"The loaded UnLhaRe native library reports API level {apiLevel}; this operation requires API level {requiredApiLevel} or newer.");
        }
    }

    private static uint LoadNativeApiLevel()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Kagayoi.UnLhaRe currently packages native libraries only for 64-bit Windows.");
        }
        if (RuntimeInformation.ProcessArchitecture is not Architecture.X64 and not Architecture.Arm64)
        {
            throw new PlatformNotSupportedException(
                $"Kagayoi.UnLhaRe does not support {RuntimeInformation.ProcessArchitecture} processes.");
        }

        uint abiVersion;
        uint apiLevel;
        try
        {
            abiVersion = NativeMethods.AbiVersion();
            if (abiVersion != RequiredAbiVersion)
            {
                throw new NotSupportedException(
                    $"The loaded UnLhaRe native library reports ABI version {abiVersion}; Kagayoi.UnLhaRe requires ABI version {RequiredAbiVersion}.");
            }
            apiLevel = NativeMethods.ApiLevel();
        }
        catch (EntryPointNotFoundException exception)
        {
            throw ApiLevelException(RequiredApiLevel, exception);
        }
        catch (DllNotFoundException exception)
        {
            throw new PlatformNotSupportedException(
                "The UnLhaRe native library could not be loaded. Install the Kagayoi.UnLhaRe runtime asset matching the process architecture.",
                exception);
        }
        catch (BadImageFormatException exception)
        {
            throw new PlatformNotSupportedException(
                "The loaded UnLhaRe native library does not match the process architecture.",
                exception);
        }

        if (apiLevel < RequiredApiLevel)
        {
            throw new NotSupportedException(
                $"The loaded UnLhaRe native library reports API level {apiLevel}; Kagayoi.UnLhaRe requires API level {RequiredApiLevel} or newer.");
        }
        return apiLevel;
    }

    private static NotSupportedException ApiLevelException(uint requiredApiLevel, Exception innerException) => new(
        $"The loaded UnLhaRe native library does not export API level {requiredApiLevel} functions. Deploy the native DLL from this NuGet package.",
        innerException);

    private static string[]? CopyStrings(IReadOnlyList<string>? values, string parameterName)
    {
        if (values is null)
        {
            return null;
        }

        var copy = new string[values.Count];
        for (var index = 0; index < values.Count; index++)
        {
            var value = values[index];
            ValidateText(value, $"{parameterName}[{index}]");
            copy[index] = value;
        }
        return copy;
    }

    private static void ValidateText(string value, string parameterName)
    {
        ArgumentException.ThrowIfNullOrEmpty(value, parameterName);
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("Embedded NUL characters are not supported.", parameterName);
        }
    }

    private sealed class CallbackState(
        IProgress<ArchiveProgress>? progress,
        CancellationToken cancellationToken)
    {
        internal IProgress<ArchiveProgress>? Progress { get; } = progress;

        internal CancellationToken CancellationToken { get; } = cancellationToken;

        internal ExceptionDispatchInfo? CallbackException { get; private set; }

        internal byte[]? ResultJson { get; private set; }

        internal void SaveException(Exception exception) =>
            CallbackException ??= ExceptionDispatchInfo.Capture(exception);

        internal void SaveResultJson(byte[] json)
        {
            if (ResultJson is not null)
            {
                throw new InvalidDataException("The native operation returned JSON more than once.");
            }
            ResultJson = json;
        }
    }

    private enum NativeResultOperation
    {
        List,
        Create,
    }
}
