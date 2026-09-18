using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Kagayoi.UnLhaRe;

internal static unsafe partial class NativeMethods
{
    private const string LibraryName = "unlhare";

    [LibraryImport(LibraryName, EntryPoint = "unlhare_abi_version")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial uint AbiVersion();

    [LibraryImport(LibraryName, EntryPoint = "unlhare_api_level")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial uint ApiLevel();

    [LibraryImport(
        LibraryName,
        EntryPoint = "unlhare_run_json",
        StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int RunJson(string request, nint callback, nint user);

    [LibraryImport(
        LibraryName,
        EntryPoint = "unlhare_list_json_ex",
        StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int ListJsonEx(
        string request,
        byte* output,
        ulong capacity,
        out ulong required);

    [LibraryImport(
        LibraryName,
        EntryPoint = "unlhare_list_json_with_progress",
        StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int ListJsonWithProgress(
        string request,
        nint progressCallback,
        nint resultCallback,
        nint user);

    [LibraryImport(
        LibraryName,
        EntryPoint = "unlhare_list_entries_json",
        StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int ListEntriesJson(
        string request,
        nint progressCallback,
        nint entryCallback,
        nint user);

    [LibraryImport(
        LibraryName,
        EntryPoint = "unlhare_create_json_report",
        StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int CreateJsonReport(
        string request,
        nint progressCallback,
        nint resultCallback,
        nint user);

    [LibraryImport(LibraryName, EntryPoint = "unlhare_last_error")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int LastError(byte* output, ulong capacity, out ulong required);

    [LibraryImport(LibraryName, EntryPoint = "unlhare_last_error_kind")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int LastErrorKind();
}
