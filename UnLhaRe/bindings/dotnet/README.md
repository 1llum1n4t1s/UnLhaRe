# Kagayoi.UnLhaRe for .NET

`Kagayoi.UnLhaRe` 1.0.2 is the .NET 10 binding for the 64-bit UnLhaRe native
library. The package contains native assets for Windows x64 and Windows ARM64,
uses UTF-8 throughout the native boundary, and is compatible with trimming and
NativeAOT publishing.

This is a general-purpose library for any Windows .NET 10 application, including
console programs, services, and desktop applications. It has no dependency on
Lhamiel or a UI framework. The native Rust and C APIs also support macOS; this
NuGet package currently bundles Windows native libraries only.

Add the package to your own project and select the architecture you publish for:

```powershell
dotnet add package Kagayoi.UnLhaRe --version 1.0.2
dotnet restore --use-lock-file
dotnet publish -c Release -r win-x64
# Use win-arm64 instead for Windows ARM64.
```

Keep `packages.lock.json` in source control and use `dotnet restore --locked-mode`
when verifying pinned dependencies. No Lhamiel checkout or configuration is needed.

```csharp
using Kagayoi.UnLhaRe;

var sources = new[]
{
    new ArchiveSourceEntry(@"C:\input\hello.txt", "docs/hello.txt"),
};

ArchiveClient.Create("example.lzh", sources, CompressionMethod.Lh5);
var entries = ArchiveClient.List("example.lzh");
ArchiveClient.Verify("example.lzh");
ArchiveClient.Extract("example.lzh", "output", ["docs/hello.txt"]);
```

`ArchiveLimits` controls entry count, per-entry decoded size, and total decoded
size. `Verify`, `Extract`, and `Create` accept synchronous progress and a
`CancellationToken`. A progress callback runs on the thread that called the
operation and must complete quickly. The methods are synchronous so callers that
need asynchronous UI behavior should schedule them away from the UI thread.

The library calls `IProgress<ArchiveProgress>.Report` synchronously. A caller's
`Progress<T>` implementation may dispatch its handler asynchronously, so callers
own UI dispatch and notification throttling. Callers also own settings storage,
overwrite prompts, file associations, and application updates. Supply resource
limits per operation instead of relying on another application's policy.

Extraction never replaces existing files. A failure or cancellation can leave
entries already completed; extraction is not an archive-wide transaction.
Cancellation is checked during input reads and before and after each file's
compression, but cannot interrupt the compression calculation for a single file.

The package validates native ABI version 1 and API level 2 before use. A clear
`NotSupportedException` is raised if an older native DLL is selected by the
process loader. Native failures use `ArchiveNativeException`; cancellation uses
`OperationCanceledException`.

Native and third-party notices are included in the package. The package's
`buildTransitive` target also copies them to `licenses/Kagayoi.UnLhaRe` under a
consumer's publish directory.

## API level 3

These additions are available in package 1.0.2. Build and deploy both the
managed binding and the matching native library when building from source.
Existing methods keep their signatures and require API level 2; the new methods
require API level 3. All APIs remain independent of any consuming application.

```csharp
var entries = ArchiveClient.List("example.lzh", cancellationToken: token);
foreach (var entry in entries)
{
    Console.WriteLine($"{entry.Name}: {entry.ModifiedUnixSeconds}");
}

ArchiveClient.ExtractWithOptions(
    "example.lzh", "output",
    new ArchiveExtractOptions(PreserveTimestamps: true),
    cancellationToken: token);

var result = ArchiveClient.CreateWithResults(
    "partial.lzh", sources, CompressionMethod.Lh5,
    cancellationToken: token);
foreach (var entry in result.Entries)
{
    Console.WriteLine($"{entry.Name}: {entry.Status} {entry.Error}");
}
```

The cancellable `List` scans once and accepts synchronous progress reporting.
`ModifiedUnixSeconds` is null for invalid or ambiguous timestamps. Old DOS dates
have no stored time zone and are interpreted in the host's local time zone.
Timestamp restoration applies only to newly extracted regular files, after CRC
validation and before publication. Directory timestamps are not restored.
The existing `Extract` method keeps timestamp restoration disabled.

`CreateWithResults` skips only source I/O failures and returns one result per
input, in input order. Invalid archive names, unsafe source types, limits, output
errors and cancellation still abort the entire archive. All skipped inputs yield
an empty archive and a report; callers should examine every result. The existing
`Create` method still aborts on any source failure. Both methods accept Windows
relative separators in archive entry names and validate after normalizing to `/`.

The encoder still retains one source entry in memory; per-entry limits continue
to apply. These APIs do not yet provide streaming compression.
