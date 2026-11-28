using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AniGamesReady.Agent.Tray;

public sealed class StarDeskWindowEventArgs : EventArgs
{
    public bool MainWindowDestroyed { get; init; }
    public uint ProcessId { get; init; }
    public uint EventId { get; init; }
}

public sealed class StarDeskWindowEventWatcher : IDisposable
{
    private const uint WineventOutOfContext = 0x0000;
    private const uint EventSystemForeground = 0x0003;
    private const uint EventObjectCreate = 0x8000;
    private const uint EventObjectDestroy = 0x8001;
    private const uint EventObjectShow = 0x8002;
    private const uint EventObjectHide = 0x8003;
    private const uint EventObjectNameChange = 0x800C;
    private const uint EventObjectValueChange = 0x800E;
    private const int ObjidWindow = 0;
    private const int ChildidSelf = 0;

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    private delegate void WinEventProc(
        IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild,
        uint eventThread, uint eventTime);

    private readonly WinEventProc callback;
    private readonly List<IntPtr> hooks = new();
    private readonly HashSet<uint> knownStarDeskProcesses = new();
    private bool disposed;

    public event EventHandler<StarDeskWindowEventArgs>? StarDeskChanged;

    public StarDeskWindowEventWatcher()
    {
        callback = OnWinEvent;
        AddHook(EventObjectCreate, EventObjectHide);
        AddHook(EventObjectNameChange, EventObjectValueChange);
        AddHook(EventSystemForeground, EventSystemForeground);
    }

    private void AddHook(uint min, uint max)
    {
        var handle = SetWinEventHook(min, max, IntPtr.Zero, callback, 0, 0, WineventOutOfContext);
        if (handle == IntPtr.Zero)
            throw new InvalidOperationException("STARDESK_EVENT_HOOK_FAILED");
        hooks.Add(handle);
    }

    private void OnWinEvent(
        IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild,
        uint eventThread, uint eventTime)
    {
        if (disposed || hwnd == IntPtr.Zero) return;
        try
        {
            GetWindowThreadProcessId(hwnd, out var processId);
            if (processId == 0) return;

            var isStarDesk = knownStarDeskProcesses.Contains(processId);
            if (!isStarDesk)
            {
                try
                {
                    using var process = Process.GetProcessById((int)processId);
                    isStarDesk = string.Equals(process.ProcessName, "StarDesk", StringComparison.OrdinalIgnoreCase);
                }
                catch { return; }
            }

            if (!isStarDesk) return;
            knownStarDeskProcesses.Add(processId);

            var destroyedTopLevel = eventType == EventObjectDestroy &&
                idObject == ObjidWindow && idChild == ChildidSelf;
            var lastVisibleWindowDestroyed = destroyedTopLevel &&
                CountVisibleTopLevelWindows(processId) == 0;
            if (lastVisibleWindowDestroyed)
                knownStarDeskProcesses.Remove(processId);

            StarDeskChanged?.Invoke(this, new StarDeskWindowEventArgs
            {
                MainWindowDestroyed = lastVisibleWindowDestroyed,
                ProcessId = processId,
                EventId = eventType
            });
        }
        catch
        {
            // A disappearing StarDesk window is an expected WinEvent race.
        }
    }

    private static int CountVisibleTopLevelWindows(uint targetProcessId)
    {
        var count = 0;
        EnumWindows((hwnd, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var processId);
            if (processId == targetProcessId && IsWindowVisible(hwnd))
                count++;
            return true;
        }, IntPtr.Zero);
        return count;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var hook in hooks)
        {
            try { UnhookWinEvent(hook); } catch { }
        }
        hooks.Clear();
        knownStarDeskProcesses.Clear();
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr eventHookModule,
        WinEventProc callback, uint processId, uint threadId, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWinEvent(IntPtr eventHook);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
}
