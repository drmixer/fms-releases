#requires -Version 7.2
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:FMS_PUBLIC_RUNNER_TEST -ne '1') {
    throw 'This probe runs only in the approved disposable GitHub-hosted Windows job.'
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Cryptography;

public static class FmsCredentialProbe {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Write(ref Credential value, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Read(string target, uint type, uint flags, out IntPtr value);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Delete(string target, uint type, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredFree")]
    private static extern void Free(IntPtr value);

    public static void Run() {
        string target = "FMS.PublicRunnerProbe." + Guid.NewGuid().ToString();
        byte[] expected = RandomNumberGenerator.GetBytes(32);
        byte[] actual = new byte[32];
        GCHandle pinned = GCHandle.Alloc(expected, GCHandleType.Pinned);
        IntPtr stored = IntPtr.Zero;
        bool created = false;
        try {
            Credential credential = new Credential {
                Type = 1, TargetName = target, CredentialBlobSize = 32,
                CredentialBlob = pinned.AddrOfPinnedObject(), Persist = 2,
                UserName = "FMS synthetic runner probe"
            };
            if (!Write(ref credential, 0)) throw new Exception("Credential Manager probe write failed.");
            created = true;
            if (!Read(target, 1, 0, out stored)) throw new Exception("Credential Manager probe read failed.");
            Credential recovered = Marshal.PtrToStructure<Credential>(stored);
            if (recovered.CredentialBlobSize != 32) throw new Exception("Credential Manager probe length mismatch.");
            Marshal.Copy(recovered.CredentialBlob, actual, 0, actual.Length);
            if (!CryptographicOperations.FixedTimeEquals(expected, actual)) throw new Exception("Credential Manager probe mismatch.");
        } finally {
            if (stored != IntPtr.Zero) Free(stored);
            pinned.Free();
            CryptographicOperations.ZeroMemory(expected);
            CryptographicOperations.ZeroMemory(actual);
            if (created && !Delete(target, 1, 0)) throw new Exception("Credential Manager probe cleanup failed.");
        }
    }
}
"@
[FmsCredentialProbe]::Run()
Write-Host 'OS Credential Manager write/read/delete probe passed; FMS save/decrypt is a separate check.'
