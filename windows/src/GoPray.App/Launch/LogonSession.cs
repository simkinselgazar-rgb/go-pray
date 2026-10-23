// LogonSession.cs — this logon session's id (the token's AuthenticationId LUID), used by LaunchDecision to tell
// "quit on purpose in THIS session" from "a new sign-in". null if Windows will not say (then the app runs).

using System;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace GoPray.App.Launch;

internal static class LogonSession
{
    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_STATISTICS
    {
        public long TokenId, AuthenticationId, ExpirationTime;
        public int TokenType, ImpersonationLevel, DynamicCharged, DynamicAvailable, GroupCount, PrivilegeCount;
        public long ModifiedId;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int cls, out TOKEN_STATISTICS info, int len, out int ret);

    public static string? CurrentId()
    {
        try
        {
            using var id = WindowsIdentity.GetCurrent();
            if (!GetTokenInformation(id.Token, 10 /* TokenStatistics */, out var s, Marshal.SizeOf<TOKEN_STATISTICS>(), out _)) return null;
            return "0x" + s.AuthenticationId.ToString("x");
        }
        catch (Exception) { return null; }
    }
}
