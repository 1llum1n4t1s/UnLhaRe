# Kagayoi.UnLhaRe for .NET

`Kagayoi.UnLhaRe` 1.0.1 is the .NET 10 binding for the 64-bit UnLhaRe native
library. The package contains native assets for Windows x64 and Windows ARM64,
uses UTF-8 throughout the native boundary, and is compatible with trimming and
NativeAOT publishing.

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

The package validates native ABI version 1 and API level 2 before use. A clear
`NotSupportedException` is raised if an older native DLL is selected by the
process loader. Native failures use `ArchiveNativeException`; cancellation uses
`OperationCanceledException`.

Native and third-party notices are included in the package. The package's
`buildTransitive` target also copies them to `licenses/Kagayoi.UnLhaRe` under a
consumer's publish directory.
