using System.Text.Json.Serialization;

namespace Kagayoi.UnLhaRe;

/// <summary>Caller-controlled archive resource limits.</summary>
public sealed record ArchiveLimits(
    ulong MaxEntries = 100_000,
    ulong MaxEntryBytes = 256UL * 1024 * 1024,
    ulong MaxTotalBytes = 2UL * 1024 * 1024 * 1024);

/// <summary>A source file and the portable name stored in an archive.</summary>
public sealed record ArchiveSourceEntry(string Path, string Name);

/// <summary>Optional extraction behavior.</summary>
public sealed record ArchiveExtractOptions(bool PreserveTimestamps = false);

/// <summary>An entry reported by an LHA archive.</summary>
public sealed record ArchiveEntry(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("original_size")] ulong OriginalSize,
    [property: JsonPropertyName("compressed_size")] ulong CompressedSize,
    [property: JsonPropertyName("is_directory")] bool IsDirectory,
    [property: JsonPropertyName("crc16")] ushort Crc16,
    [property: JsonPropertyName("header_level")] byte HeaderLevel)
{
    /// <summary>The entry modification time as Unix seconds, when the archive timestamp is valid.</summary>
    [JsonPropertyName("modified_unix_seconds")]
    public long? ModifiedUnixSeconds { get; init; }

    /// <summary>The entry modification time, or null when it is absent or outside the .NET range.</summary>
    [JsonIgnore]
    public DateTimeOffset? ModifiedAt
    {
        get
        {
            if (ModifiedUnixSeconds is not long seconds)
            {
                return null;
            }

            try
            {
                return DateTimeOffset.FromUnixTimeSeconds(seconds);
            }
            catch (ArgumentOutOfRangeException)
            {
                return null;
            }
        }
    }
}

/// <summary>The result of an archive creation request that may skip unreadable sources.</summary>
public sealed record ArchiveCreateReport(
    [property: JsonPropertyName("entries")] IReadOnlyList<ArchiveCreateEntryResult> Entries);

/// <summary>Optional policy for creation which reports skipped source entries.</summary>
public readonly record struct ArchiveCreateReportOptions(bool FailIfAllSkipped = false);

/// <summary>The outcome for one requested source entry.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ArchiveCreateEntryStatus>))]
public enum ArchiveCreateEntryStatus
{
    /// <summary>The source entry was written to the archive.</summary>
    Written,

    /// <summary>The source entry was skipped because its contents could not be read.</summary>
    Skipped,
}

/// <summary>The result of processing one source entry during archive creation.</summary>
public sealed record ArchiveCreateEntryResult(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("status")] ArchiveCreateEntryStatus Status,
    [property: JsonPropertyName("error")] string? Error);

/// <summary>Compression methods supported when creating an archive.</summary>
public enum CompressionMethod
{
    /// <summary>Store without compression.</summary>
    Stored = 0,

    /// <summary>Use LH5 compression.</summary>
    Lh5 = 5,

    /// <summary>Use LH6 compression.</summary>
    Lh6 = 6,

    /// <summary>Use LH7 compression.</summary>
    Lh7 = 7,
}

/// <summary>The current stage of an archive operation.</summary>
public enum ArchiveProgressPhase : uint
{
    /// <summary>Inputs are being prepared.</summary>
    Prepare = 1,

    /// <summary>Input data is being compressed.</summary>
    Compress = 2,

    /// <summary>Archive data is being extracted or verified.</summary>
    ExtractOrVerify = 3,

    /// <summary>The operation is being finalized.</summary>
    Finalize = 4,
}

/// <summary>Progress reported synchronously by a native archive operation.</summary>
/// <param name="Phase">The current operation phase.</param>
/// <param name="Completed">Work completed in the phase.</param>
/// <param name="Total">Total work, or zero when it is indeterminate.</param>
public readonly record struct ArchiveProgress(
    ArchiveProgressPhase Phase,
    ulong Completed,
    ulong Total);

/// <summary>A stable classification for an error returned by the native library.</summary>
public enum ArchiveErrorKind
{
    /// <summary>The native library did not provide a more specific classification.</summary>
    Unknown = 0,

    /// <summary>A filesystem or stream I/O operation failed.</summary>
    Io = 1,

    /// <summary>The archive structure or payload was invalid.</summary>
    Format = 2,

    /// <summary>The requested feature or source type is unsupported.</summary>
    Unsupported = 3,

    /// <summary>A caller-controlled resource limit was exceeded.</summary>
    Limit = 4,

    /// <summary>An archive entry name was unsafe or invalid.</summary>
    InvalidPath = 5,

    /// <summary>A destination already existed.</summary>
    Exists = 6,

    /// <summary>An ABI or operation argument was invalid.</summary>
    InvalidArgument = 7,

    /// <summary>The operation was cancelled.</summary>
    Cancelled = 8,

    /// <summary>A caller-provided native output buffer was too small.</summary>
    BufferTooSmall = 9,

    /// <summary>An internal boundary operation failed.</summary>
    Internal = 10,
}

/// <summary>An error returned by the native UnLhaRe library.</summary>
public sealed class ArchiveNativeException : Exception
{
    /// <summary>Creates an exception for a native status code and message.</summary>
    public ArchiveNativeException(int status, string message)
        : this(status, ArchiveErrorKind.Unknown, message)
    {
    }

    /// <summary>Creates an exception for a native status, error kind, and message.</summary>
    public ArchiveNativeException(int status, ArchiveErrorKind kind, string message)
        : base(message)
    {
        Status = status;
        Kind = kind;
    }

    /// <summary>The status returned by the native ABI.</summary>
    public int Status { get; }

    /// <summary>The stable native error classification, or <see cref="ArchiveErrorKind.Unknown"/>.</summary>
    public ArchiveErrorKind Kind { get; }
}
