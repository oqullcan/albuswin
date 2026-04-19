using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Configuration.Install;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;

[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
[assembly: AssemblyProduct("AlbusX")]
[assembly: AssemblyDescription("albus core engine — timer resolution, audio latency, memory management")]
[assembly: AssemblyCopyright("oqullcan")]

namespace AlbusCore
{
    // ─────────────────────────────────────────────────────────────────────────
    // service entry
    // ─────────────────────────────────────────────────────────────────────────

    class AlbusService : ServiceBase
    {
        TimerEngine   _timer;
        AudioEngine   _audio;
        MemoryEngine  _memory;

        public AlbusService()
        {
            ServiceName              = "AlbusXSvc";
            EventLog.Log             = "Application";
            CanStop                  = true;
            CanHandlePowerEvent      = true;
            CanHandleSessionChangeEvent = false;
            CanPauseAndContinue      = false;
            CanShutdown              = true;
        }

        static void Main() => ServiceBase.Run(new AlbusService());

        protected override void OnStart(string[] args)
        {
            // elevate service process priority
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High; } catch { }
            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch { }
            try { GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency; } catch { }

            // register as pro audio mmcss task
            try { uint i = 0; NativeMethods.AvSetMmThreadCharacteristics("Pro Audio", ref i); } catch { }

            // disable power throttling for this process
            try
            {
                var s = new NativeMethods.PROCESS_POWER_THROTTLING_STATE { Version = 1, ControlMask = 0x4, StateMask = 0 };
                NativeMethods.SetProcessInformation(Process.GetCurrentProcess().Handle, 4, ref s, Marshal.SizeOf(s));
            } catch { }

            // prevent system sleep
            try { NativeMethods.SetThreadExecutionState(0x80000003); } catch { }

            // start engines
            _timer  = new TimerEngine(EventLog);
            _audio  = new AudioEngine(EventLog);
            _memory = new MemoryEngine(EventLog);

            _timer.Start();
            _audio.Start();
            _memory.Start();

            Log("albusx 1.0.0 started.");
        }

        protected override void OnStop()
        {
            try { NativeMethods.SetThreadExecutionState(0x80000000); } catch { }

            _memory?.Stop();
            _audio?.Stop();
            _timer?.Stop();

            Log("albusx stopped.");
        }

        protected override void OnShutdown() => OnStop();

        protected override bool OnPowerEvent(PowerBroadcastStatus status)
        {
            if (status == PowerBroadcastStatus.ResumeSuspend ||
                status == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(2000);
                _timer?.ForceReapply();
                _memory?.Purge();
                Log("albusx: resumed from sleep — reapplied.");
            }
            return true;
        }

        void Log(string msg)
        {
            try { EventLog?.WriteEntry(msg); } catch { }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // timer engine
    // handles: resolution set, drift guard, external override detection
    // ─────────────────────────────────────────────────────────────────────────

    class TimerEngine
    {
        readonly System.Diagnostics.EventLog _log;

        uint _min, _max, _default, _target, _current;
        long _driftCount;
        long _overrideCount;

        Timer _guardTimer;
        IntPtr _hKeepAliveTimer = IntPtr.Zero;

        // drift guard checks every 5 seconds (aggressive — catches spikes fast)
        const int GUARD_INTERVAL_MS    = 5000;
        // tolerance in 100ns units — anything 50µs above target is a drift
        const uint DRIFT_TOLERANCE     = 500;

        public TimerEngine(System.Diagnostics.EventLog log)
        {
            _log = log;
        }

        public void Start()
        {
            // query system capabilities
            NativeMethods.NtQueryTimerResolution(out _min, out _max, out _current);
            _default = _current;
            _target  = _max; // maximum resolution = lowest value (100ns units)

            // create high-resolution waitable timer to anchor the resolution
            // this prevents some drivers from drifting the clock upward
            try
            {
                _hKeepAliveTimer = NativeMethods.CreateWaitableTimerExW(
                    IntPtr.Zero, null,
                    0x00000002, // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
                    0x1F0003
                );
            } catch { }

            Apply();
            StartGuard();

            Log($"[timer] min={_min} max={_max} default={_default} target={_target}");
        }

        public void Stop()
        {
            _guardTimer?.Dispose();

            if (_hKeepAliveTimer != IntPtr.Zero)
            {
                try { NativeMethods.CloseHandle(_hKeepAliveTimer); } catch { }
                _hKeepAliveTimer = IntPtr.Zero;
            }

            // restore system default
            try
            {
                uint actual = 0;
                NativeMethods.NtSetTimerResolution(_default, true, out actual);
                Log($"[timer] restored to default={actual}");
            } catch { }
        }

        public void ForceReapply()
        {
            Apply();
            Log("[timer] force reapplied after resume.");
        }

        // ── drift guard ───────────────────────────────────────────────────────
        // the core of 1.0.0 — detects and corrects two types of drift:
        //
        //   type 1 — passive drift
        //     the kernel quietly raises the resolution (lower precision)
        //     because no other process is holding a request at our level.
        //     fix: re-request our target.
        //
        //   type 2 — external override
        //     another process requests a lower precision (higher value)
        //     and the kernel honors it, overriding our request.
        //     this is the hard case. we cannot block other processes but
        //     we can detect and immediately re-fight for our target.
        //
        //   type 3 — hardware event drift
        //     power events, driver reloads, USB connect/disconnect can
        //     momentarily reset the timer subsystem.
        //     fix: same re-request, guard catches it within 5 seconds.

        void StartGuard()
        {
            _guardTimer = new Timer(GuardTick, null,
                TimeSpan.FromMilliseconds(GUARD_INTERVAL_MS),
                TimeSpan.FromMilliseconds(GUARD_INTERVAL_MS));
        }

        void GuardTick(object _)
        {
            try
            {
                NativeMethods.NtQueryTimerResolution(out _, out _, out uint actual);

                if (actual > _target + DRIFT_TOLERANCE)
                {
                    // classify drift type for logging
                    bool isExternal = actual > _default;
                    string type = isExternal ? "external-override" : "passive-drift";

                    Apply(out uint corrected);

                    if (isExternal)
                        Interlocked.Increment(ref _overrideCount);
                    else
                        Interlocked.Increment(ref _driftCount);

                    Log($"[timer] drift detected ({type}) actual={actual} corrected={corrected} " +
                        $"[passive={_driftCount} override={_overrideCount}]");
                }
            }
            catch { }
        }

        void Apply() { Apply(out _); }

        void Apply(out uint actual)
        {
            actual = 0;
            try
            {
                // retry loop — some kernel states reject the first call
                for (int i = 0; i < 10; i++)
                {
                    NativeMethods.NtSetTimerResolution(_target, true, out actual);

                    NativeMethods.NtQueryTimerResolution(out _, out _, out uint q);
                    if (q <= _target + DRIFT_TOLERANCE) break;

                    Thread.SpinWait(5000);
                }
            }
            catch { }
        }

        void Log(string msg) { try { _log?.WriteEntry(msg); } catch { } }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // audio engine
    // handles: wasapi shared mode minimum buffer, device hot-swap
    // ─────────────────────────────────────────────────────────────────────────

    class AudioEngine
    {
        readonly System.Diagnostics.EventLog _log;
        readonly List<object> _activeClients = new List<object>();
        readonly object _lock = new object();

        IMMDeviceEnumerator _enumerator;
        AudioNotifier _notifier;
        Thread _thread;

        public AudioEngine(System.Diagnostics.EventLog log) { _log = log; }

        public void Start()
        {
            _thread = new Thread(Worker) { IsBackground = true, Priority = ThreadPriority.Highest };
            _thread.Start();
        }

        public void Stop()
        {
            lock (_lock) { ReleaseClients(); }
        }

        void Worker()
        {
            try { uint i = 0; NativeMethods.AvSetMmThreadCharacteristics("Pro Audio", ref i); } catch { }
            try { NativeMethods.CoInitializeEx(IntPtr.Zero, 0); } catch { }

            try
            {
                var clsid = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
                _enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));

                _notifier = new AudioNotifier();
                _notifier.OnChange = () =>
                {
                    Thread.Sleep(800); // let device settle
                    lock (_lock)
                    {
                        ReleaseClients();
                        OptimizeAll();
                    }
                    Log("[audio] hot-swap detected. re-optimized all endpoints.");
                };

                _enumerator.RegisterEndpointNotificationCallback(_notifier);
                lock (_lock) { OptimizeAll(); }
            }
            catch (Exception ex) { Log($"[audio] init failed: {ex.Message}"); }

            Thread.Sleep(Timeout.Infinite);
        }

        void OptimizeAll()
        {
            try
            {
                var iid = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                _enumerator.EnumAudioEndpoints(2, 1, out IMMDeviceCollection col);
                col.GetCount(out uint count);

                for (uint i = 0; i < count; i++)
                {
                    try
                    {
                        col.Item(i, out IMMDevice dev);
                        dev.Activate(ref iid, 0x17, IntPtr.Zero, out object obj);
                        var client = (IAudioClient3)obj;

                        client.GetMixFormat(out IntPtr pFmt);
                        var fmt = Marshal.PtrToStructure<WAVEFORMATEX>(pFmt);
                        client.GetSharedModeEnginePeriod(pFmt, out uint def, out _, out uint min, out _);

                        if (min < def && min > 0 &&
                            client.InitializeSharedAudioStream(0, min, pFmt, IntPtr.Zero) == 0 &&
                            client.Start() == 0)
                        {
                            _activeClients.Add(obj);
                            double minMs = (min / (double)fmt.nSamplesPerSec) * 1000.0;
                            double defMs = (def / (double)fmt.nSamplesPerSec) * 1000.0;
                            Log($"[audio] {defMs:F2}ms → {minMs:F2}ms (frames {def}→{min})");
                        }

                        Marshal.FreeCoTaskMem(pFmt);
                    }
                    catch { }
                }
            }
            catch { }
        }

        void ReleaseClients()
        {
            foreach (var c in _activeClients)
            {
                try { ((IAudioClient3)c).Stop(); } catch { }
                try { ((IAudioClient3)c).Reset(); } catch { }
                try { Marshal.ReleaseComObject(c); } catch { }
            }
            _activeClients.Clear();
        }

        void Log(string msg) { try { _log?.WriteEntry(msg); } catch { } }

        class AudioNotifier : IMMNotificationClient
        {
            public Action OnChange;
            public int OnDeviceStateChanged(string id, int s) { try { OnChange?.Invoke(); } catch { } return 0; }
            public int OnDeviceAdded(string id)               { try { OnChange?.Invoke(); } catch { } return 0; }
            public int OnDeviceRemoved(string id)             { try { OnChange?.Invoke(); } catch { } return 0; }
            public int OnDefaultDeviceChanged(int f, int r, string id) { try { OnChange?.Invoke(); } catch { } return 0; }
            public int OnPropertyValueChanged(string id, IntPtr k) { return 0; }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // memory engine
    // handles: standby list purge, working set trim, dynamic threshold
    // ─────────────────────────────────────────────────────────────────────────

    class MemoryEngine
    {
        readonly System.Diagnostics.EventLog _log;
        Timer _timer;

        const int  CHECK_INTERVAL_MIN  = 5;
        const long THRESHOLD_MB        = 1024;

        public MemoryEngine(System.Diagnostics.EventLog log) { _log = log; }

        public void Start()
        {
            Trim();
            _timer = new Timer(Tick, null,
                TimeSpan.FromMinutes(2),
                TimeSpan.FromMinutes(CHECK_INTERVAL_MIN));
        }

        public void Stop() => _timer?.Dispose();

        public void Purge() => DoPurge("manual");

        void Tick(object _)
        {
            try
            {
                var pc = new PerformanceCounter("Memory", "Available MBytes");
                float available = pc.NextValue();
                pc.Dispose();

                if (available < THRESHOLD_MB)
                    DoPurge($"threshold ({available:F0}mb available)");
                else
                    Trim();
            }
            catch { }
        }

        void DoPurge(string reason)
        {
            // purge standby list
            try { NativeMethods.SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0); } catch { }
            try { int cmd = 4; NativeMethods.NtSetSystemInformation(80, ref cmd, sizeof(int)); } catch { }
            Trim();
            Log($"[memory] purged. reason={reason}");
        }

        void Trim()
        {
            try { NativeMethods.EmptyWorkingSet(Process.GetCurrentProcess().Handle); } catch { }
        }

        void Log(string msg) { try { _log?.WriteEntry(msg); } catch { } }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // native methods
    // ─────────────────────────────────────────────────────────────────────────

    static class NativeMethods
    {
        [DllImport("ntdll.dll")] public static extern int NtSetTimerResolution(uint desired, bool set, out uint current);
        [DllImport("ntdll.dll")] public static extern int NtQueryTimerResolution(out uint min, out uint max, out uint actual);
        [DllImport("ntdll.dll")] public static extern int NtSetSystemInformation(int cls, ref int info, int len);
        [DllImport("kernel32.dll")] public static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);
        [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
        [DllImport("kernel32.dll")] public static extern bool SetProcessInformation(IntPtr h, int cls, ref PROCESS_POWER_THROTTLING_STATE info, int size);
        [DllImport("kernel32.dll")] public static extern IntPtr CreateWaitableTimerExW(IntPtr attr, string name, uint flags, uint access);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
        [DllImport("psapi.dll")]    public static extern int EmptyWorkingSet(IntPtr h);
        [DllImport("avrt.dll")]     public static extern IntPtr AvSetMmThreadCharacteristics(string task, ref uint index);
        [DllImport("ole32.dll")]    public static extern int CoInitializeEx(IntPtr reserved, uint mode);

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_POWER_THROTTLING_STATE
        {
            public uint Version;
            public uint ControlMask;
            public uint StateMask;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // com interfaces
    // ─────────────────────────────────────────────────────────────────────────

    [ComImport][Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint n);
        [PreserveSig] int Item(uint i, out IMMDevice dev);
    }

    [ComImport][Guid("D666063F-1587-4E43-81F1-B948E807363F")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object obj);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport][Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection col);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
        [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient cb);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient cb);
    }

    [ComImport][Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMNotificationClient
    {
        [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
        [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnDefaultDeviceChanged(int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
    }

    [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient3
    {
        [PreserveSig] int Initialize(int mode, uint flags, long dur, long period, IntPtr fmt, IntPtr session);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr fmt);
        [PreserveSig] int GetDevicePeriod(out long def, out long min);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr h);
        [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
        [PreserveSig] int IsOffloadCapable(int cat, out int capable);
        [PreserveSig] int SetClientProperties(IntPtr props);
        [PreserveSig] int GetSharedModeEnginePeriod(IntPtr fmt, out uint def, out uint fund, out uint min, out uint max);
        [PreserveSig] int GetCurrentSharedModeEnginePeriod(out IntPtr fmt, out uint period);
        [PreserveSig] int InitializeSharedAudioStream(uint flags, uint period, IntPtr fmt, IntPtr session);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint   nSamplesPerSec;
        public uint   nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // installer
    // ─────────────────────────────────────────────────────────────────────────

    [RunInstaller(true)]
    public class AlbusInstaller : Installer
    {
        public AlbusInstaller()
        {
            var spi = new ServiceProcessInstaller { Account = ServiceAccount.LocalSystem };
            var si  = new ServiceInstaller
            {
                ServiceName = "AlbusXSvc",
                DisplayName = "AlbusX",
                Description = "albus core engine — timer resolution, audio latency, memory management",
                StartType   = ServiceStartMode.Automatic
            };
            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
