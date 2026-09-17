using System.Text.Json.Serialization;

namespace Kagayoi.UnLhaRe;

/// <summary>Caller-controlled archive resource limits.</summary>
public sealed record ArchiveLimits(
    ulong MaxEntries = 100_000,
    ulong MaxEntryBytes = 256UL * 1024 * 1024,
    ulong MaxTotalBytes = 2UL * 1024 * 1024 * 1024);

/// <summary>A source file and the portable name stored in an archive.</summary>
public sealed record ArchiveSourceEntry(string Path, string Name);

/// <summary>An entry reported by an LHA archive.</summary>
public sealed record ArchiveEntry(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("original_size")] ulong OriginalSize,
    [property: JsonPropertyName("compressed_size")] ulong CompressedSize,
    [property: JsonPropertyName("is_directory")] bool IsDirectory,
    [property: JsonPropertyName("crc16")] ushort Crc16,
    [property: JsonPropertyName("header_level")] byte HeaderLevel);

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

/// <summary>An error returned by the native UnLhaRe library.</summary>
public sealed class ArchiveNativeException : Exception
{
    /// <summary>Creates an exception for a native status code and message.</summary>
    public ArchiveNativeException(int status, string message)
        : base(message)
    {
        Status = status;
    }

    /// <summary>The status returned by the native ABI.</summary>
    public int Status { get; }
}
