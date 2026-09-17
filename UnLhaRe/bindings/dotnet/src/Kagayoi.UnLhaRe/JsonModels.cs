using System.Text.Json.Serialization;

namespace Kagayoi.UnLhaRe;

internal sealed record LimitsRequest(
    ulong MaxEntries,
    ulong MaxEntryBytes,
    ulong MaxTotalBytes)
{
    internal static LimitsRequest? From(ArchiveLimits? limits) => limits is null
        ? null
        : new(limits.MaxEntries, limits.MaxEntryBytes, limits.MaxTotalBytes);
}

internal sealed record SourceRequest(string Path, string Name);

internal sealed record CreateRequest(
    string Operation,
    string Output,
    SourceRequest[] Entries,
    int Method,
    LimitsRequest? Limits);

internal sealed record ExtractRequest(
    string Operation,
    string Archive,
    string Destination,
    string[]? Entries,
    LimitsRequest? Limits);

internal sealed record VerifyRequest(
    string Operation,
    string Archive,
    LimitsRequest? Limits);

internal sealed record ListRequest(
    string Archive,
    LimitsRequest? Limits);

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    GenerationMode = JsonSourceGenerationMode.Default)]
[JsonSerializable(typeof(CreateRequest))]
[JsonSerializable(typeof(ExtractRequest))]
[JsonSerializable(typeof(VerifyRequest))]
[JsonSerializable(typeof(ListRequest))]
[JsonSerializable(typeof(ArchiveEntry[]))]
internal sealed partial class ArchiveJsonContext : JsonSerializerContext;
