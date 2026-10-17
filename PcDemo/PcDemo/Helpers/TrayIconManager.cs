// 托盘图标管理：Win32 Shell_NotifyIcon + message-only 窗口（无第三方依赖）。
// 用途：窗口关闭后最小化到托盘后台常驻（继续接收文件），托盘可打开主窗口或退出。
// 事件在 message-only 窗口线程（= 创建线程 = UI 线程）触发，可直接操作 UI。
using System.Runtime.InteropServices;

namespace PcDemo.Helpers;

public sealed class TrayIconManager : IDisposable
{
    private const uint WM_APP_TRAY = 0x8000 + 0x100;   // 自定义回调消息
    private const uint NIM_ADD = 0, NIM_DELETE = 2;
    private const uint NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4;
    private const int WM_LBUTTONUP = 0x0202, WM_LBUTTONDBLCLK = 0x0203, WM_RBUTTONUP = 0x0205;
    private const int WM_DESTROY = 0x0002;
    private const int IDM_OPEN = 1, IDM_EXIT = 2;
    private const int TPM_RIGHTBUTTON = 0x0002, TPM_NONOTIFY = 0x0080, TPM_RETURNCMD = 0x0100;
    private const uint MF_SEPARATOR = 0x800;
    private const int IDI_APPLICATION = 32512;
    private const string ClassName = "PcDemo_TrayMsgWnd";

    // WndProc 委托必须静态持有防止 GC 回收后回调崩溃
    private static readonly NativeMethods.WndProcDelegate WndProcStatic = WndProc;
    private static bool _classRegistered;
    private static TrayIconManager? _instance;

    private IntPtr _hwnd;
    private IntPtr _hicon;
    private bool _iconShared;   // LoadIcon 共享图标不可 DestroyIcon
    private readonly string _tip;

    /// <summary>左键单击/双击托盘或菜单「打开」。</summary>
    public event Action? OpenRequested;
    /// <summary>托盘菜单「退出」。</summary>
    public event Action? ExitRequested;

    public TrayIconManager(string tip)
    {
        _tip = tip;
        _instance = this;
    }

    /// <summary>创建托盘图标（在 UI 线程调用）。</summary>
    public void Create()
    {
        var hInstance = NativeMethods.GetModuleHandleW(null);
        if (!_classRegistered)
        {
            var wc = new NativeMethods.WNDCLASSW
            {
                lpfnWndProc = Marshal.GetFunctionPointerForDelegate(WndProcStatic),
                hInstance = hInstance,
                lpszClassName = ClassName,
            };
            if (NativeMethods.RegisterClassW(ref wc) == 0)
                throw new InvalidOperationException("RegisterClassW failed for tray window");
            _classRegistered = true;
        }

        // HWND_MESSAGE：message-only 窗口，不显示、不占任务栏，只收消息
        _hwnd = NativeMethods.CreateWindowExW(0, ClassName, null, 0,
            0, 0, 0, 0, NativeMethods.HWND_MESSAGE, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero)
            throw new InvalidOperationException("CreateWindowExW failed for tray window");

        // 取托盘图标。这里不能用固定资源 ID 去 LoadIcon：
        //   <ApplicationIcon> 生成的图标组 ID 由链接器决定（.NET 常见是 32512），
        //   LoadIcon(hInstance, 1) 会失败，而失败分支会静默退回 IDI_APPLICATION，
        //   表现出来就是"托盘图标是系统默认图标/像没有图标"。
        // 改为直接从 exe 文件抽取第 0 个图标组，与资源 ID 无关。
        _hicon = LoadAppIcon(out var iconSource, out _iconShared);
        App.LogDiag($"[Tray] icon source = {iconSource}");

        var nid = new NativeMethods.NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_APP_TRAY,
            hIcon = _hicon,
            szTip = _tip,
        };
        if (!NativeMethods.Shell_NotifyIconW(NIM_ADD, ref nid))
            throw new InvalidOperationException("Shell_NotifyIconW(NIM_ADD) failed");
    }

    /// <summary>
    /// 取托盘图标：优先从 exe 文件抽取第 0 个图标组（不依赖资源 ID），
    /// 失败再退回进程内资源 ID 1，最后退回系统默认图标。
    /// iconShared=true 表示图标句柄属于系统/模块、不可 DestroyIcon。
    /// </summary>
    private static IntPtr LoadAppIcon(out string source, out bool iconShared)
    {
        iconShared = true;
        try
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe))
            {
                var large = new IntPtr[1];
                var small = new IntPtr[1];
                if (NativeMethods.ExtractIconExW(exe, 0, large, small, 1) > 0 && small[0] != IntPtr.Zero)
                {
                    if (large[0] != IntPtr.Zero) NativeMethods.DestroyIcon(large[0]);
                    iconShared = false;            // 抽取出来的图标由我们负责释放
                    source = "exe (ExtractIconEx)";
                    return small[0];
                }
            }
        }
        catch { /* 抽取失败继续走退路 */ }

        var hInstance = NativeMethods.GetModuleHandleW(null);
        var icon = NativeMethods.LoadIconW(hInstance, new IntPtr(1));
        if (icon != IntPtr.Zero) { source = "module resource #1"; return icon; }

        source = "system default (IDI_APPLICATION)";
        return NativeMethods.LoadIconW(IntPtr.Zero, new IntPtr(IDI_APPLICATION));
    }

    private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == (int)WM_APP_TRAY && _instance is not null)
        {
            switch (lParam.ToInt32())
            {
                case WM_LBUTTONUP:
                case WM_LBUTTONDBLCLK:
                    _instance.OpenRequested?.Invoke();
                    break;
                case WM_RBUTTONUP:
                    _instance.ShowContextMenu(hwnd);
                    break;
            }
        }
        return NativeMethods.DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    private void ShowContextMenu(IntPtr hwnd)
    {
        var menu = NativeMethods.CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        NativeMethods.AppendMenuW(menu, 0, new IntPtr(IDM_OPEN), "打开快传");
        NativeMethods.AppendMenuW(menu, MF_SEPARATOR, IntPtr.Zero, null);
        NativeMethods.AppendMenuW(menu, 0, new IntPtr(IDM_EXIT), "退出");
        NativeMethods.SetForegroundWindow(hwnd); // 让菜单点击外部时正确消失
        NativeMethods.GetCursorPos(out var pt);
        // TPM_RETURNCMD：直接返回所选 id（不走 WM_COMMAND）
        var cmd = NativeMethods.TrackPopupMenu(menu,
            TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD, pt.X, pt.Y, 0, hwnd, IntPtr.Zero);
        NativeMethods.DestroyMenu(menu);

        if (cmd == IDM_OPEN) OpenRequested?.Invoke();
        else if (cmd == IDM_EXIT) ExitRequested?.Invoke();
    }

    public void Dispose()
    {
        // NIM_DELETE 只需要 hWnd/uID，用最小结构即可（ref 参数需要可赋值变量）
        var nid = default(NativeMethods.NOTIFYICONDATAW);
        nid.cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONDATAW>();
        nid.uID = 1;
        if (_hwnd != IntPtr.Zero) nid.hWnd = _hwnd;
        NativeMethods.Shell_NotifyIconW(NIM_DELETE, ref nid);
        if (_hwnd != IntPtr.Zero)
        {
            NativeMethods.DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
        if (_hicon != IntPtr.Zero && !_iconShared)
        {
            NativeMethods.DestroyIcon(_hicon);
        }
        _hicon = IntPtr.Zero;
        if (_instance == this) _instance = null;
    }

    private static class NativeMethods
    {
        public static readonly IntPtr HWND_MESSAGE = new(-3);

        public delegate IntPtr WndProcDelegate(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct NOTIFYICONDATAW
        {
            public uint cbSize;
            public IntPtr hWnd;
            public uint uID;
            public uint uFlags;
            public uint uCallbackMessage;
            public IntPtr hIcon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string szTip;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WNDCLASSW
        {
            public uint style;
            public IntPtr lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string? lpszMenuName;
            [MarshalAs(UnmanagedType.LPWStr)]
            public string lpszClassName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern ushort RegisterClassW(ref WNDCLASSW lpWndClass);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateWindowExW(uint exStyle, string className, string? windowName,
            uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

        [DllImport("user32.dll")]
        public static extern bool DestroyWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern IntPtr DefWindowProcW(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr LoadIconW(IntPtr hInstance, IntPtr iconName);

        /// <summary>从可执行文件抽取图标组（不依赖资源 ID）。返回抽到的图标数量。</summary>
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern uint ExtractIconExW(string lpszFile, int nIconIndex,
            IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hwnd);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetModuleHandleW(string? name);

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll")]
        public static extern IntPtr CreatePopupMenu();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool AppendMenuW(IntPtr hMenu, uint flags, IntPtr idNewItem, string? newItem);

        [DllImport("user32.dll")]
        public static extern int TrackPopupMenu(IntPtr hMenu, uint flags, int x, int y,
            int reserved, IntPtr hwnd, IntPtr prcRect);

        [DllImport("user32.dll")]
        public static extern bool DestroyMenu(IntPtr hMenu);
    }
}
