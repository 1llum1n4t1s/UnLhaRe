# Read-only metadata enumeration: exclusive/deletion-pending compiler files need no leaf open.
if(-not ('Kagayoi.KhcWorkMeter' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Kagayoi {
public static class KhcWorkMeter {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Data {
  public uint Attributes,C0,C1,A0,A1,W0,W1,SizeHigh,SizeLow,R0,R1;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Name;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=14)] public string Alternate;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr FindFirstFileW(string path,out Data data);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool FindNextFileW(IntPtr handle,out Data data);
 [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr handle);
 public static long Sum(string path) {
  var queue=new Queue<string>();queue.Enqueue(Path.GetFullPath(path));long bytes=0;
  while(queue.Count!=0) {
   string directory=queue.Dequeue();Data data;IntPtr handle=FindFirstFileW(Path.Combine(directory,"*"),out data);
   if(handle==new IntPtr(-1)) {int error=Marshal.GetLastWin32Error();if(error==2 && Directory.Exists(directory))continue;throw new Win32Exception(error);}
   try {while(true) {
    if(data.Name!="." && data.Name!="..") {
     if((data.Attributes&0x400)!=0)throw new IOException("work reparse");
     if((data.Attributes&0x10)!=0)queue.Enqueue(Path.Combine(directory,data.Name));
     else {ulong size=((ulong)data.SizeHigh<<32)|data.SizeLow;if(size>long.MaxValue)throw new IOException("work size overflow");bytes=checked(bytes+(long)size);}
    }
    if(!FindNextFileW(handle,out data)) {int error=Marshal.GetLastWin32Error();if(error!=18)throw new Win32Exception(error);break;}
   }}finally{FindClose(handle);}
  } return bytes;
 }
}}
'@
}
function Get-KhcWorkUsage([string]$LiteralPath){[Kagayoi.KhcWorkMeter]::Sum($LiteralPath)}
