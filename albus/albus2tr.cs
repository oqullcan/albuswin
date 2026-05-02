// ─────────────────────────────────────────────────────────────────────────────
//  albus  v2.0
//  precision system latency service
//
//  katmanlar:
//    · timer      — 0.5 ms kernel timer resolution, 10 sn guard döngüsü
//    · cpu        — hybrid P-core affinity, MMCSS Pro Audio, priority boost
//    · power      — Ultimate/High Performance plan, C-state devre dışı
//    · gpu        — D3DKMT realtime scheduling priority
//    · audio      — minimum shared-mode buffer (IAudioClient3)
//    · memory     — standby list purge, working set lock, ghost memory
//    · network    — Nagle kapalı, ACK delay sıfır
//    · watchdog   — priority çalınmasına karşı 10 sn döngü
//    · ini        — hedef process listesi + custom resolution, hot-reload
//
//  derleme:
//    csc.exe -r:System.ServiceProcess.dll
//            -r:System.Configuration.Install.dll
//            -r:System.Management.dll
//            -out:Albus.exe albus.cs
//
//  servis adı : AlbusSvc
//  exe        : Albus.exe
// ─────────────────────────────────────────────────────────────────────────────

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Configuration.Install;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;
using Microsoft.Win32;

[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]
[assembly: AssemblyProduct("albus")]
[assembly: AssemblyTitle("albus")]
[assembly: AssemblyDescription("precision system latency service")]

namespace Albus
{
    sealed class AlbusService : ServiceBase
    {
        // ── sabitler ──────────────────────────────────────────────────────────
        const string SVC_NAME              = "AlbusSvc";
        const uint   RESOLUTION_TARGET     = 5000u;  // 0.5 ms  (100-ns birimi)
        const uint   RESOLUTION_TOLERANCE  = 50u;    // 5 µs    guard toleransı
        const int    GUARD_INTERVAL_SEC    = 10;
        const int    WATCHDOG_INTERVAL_SEC = 10;
        const int    PURGE_INITIAL_MIN     = 2;
        const int    PURGE_INTERVAL_MIN    = 5;
        const int    PURGE_THRESHOLD_MB    = 1024;

        // ── durum alanları ────────────────────────────────────────────────────
        uint   defaultResolution, minResolution, maxResolution;
        uint   targetResolution, customResolution;
        long   processCounter;
        Guid   previousPowerScheme;
        bool   powerSchemeChanged;
        IntPtr hResTimer = IntPtr.Zero;

        Timer                  guardTimer, purgeTimer, watchdogTimer;
        ManagementEventWatcher startWatch;
        FileSystemWatcher      iniWatcher;
        Thread                 audioThread;
        List<string>           processNames;
        int                    wmiRetryCount;
        readonly List<object>  audioClients = new List<object>();
        AudioNotifier          audioNotifier;

        // ── giriş noktası ─────────────────────────────────────────────────────
        static void Main()
        {
            ServiceBase.Run(new AlbusService());
        }

        public AlbusService()
        {
            ServiceName                 = SVC_NAME;
            EventLog.Log                = "Application";
            CanStop                     = true;
            CanHandlePowerEvent         = true;
            CanHandleSessionChangeEvent = false;
            CanPauseAndContinue         = false;
            CanShutdown                 = true;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SERVİS YAŞAM DÖNGÜSÜ
        // ══════════════════════════════════════════════════════════════════════

        protected override void OnStart(string[] args)
        {
            // process & thread kalitesi
            try { Process.GetCurrentProcess().PriorityClass        = ProcessPriorityClass.High; }  catch {}
            try { Process.GetCurrentProcess().PriorityBoostEnabled = false; }                       catch {}
            try { Thread.CurrentThread.Priority                    = ThreadPriority.Highest; }      catch {}
            try { GCSettings.LatencyMode                           = GCLatencyMode.SustainedLowLatency; } catch {}

            // ThreadPool min thread sayısını artır — timer'lar anında tetiklensin
            try
            {
                int w, io;
                ThreadPool.GetMinThreads(out w, out io);
                ThreadPool.SetMinThreads(Math.Max(w, 8), io);
            } catch {}

            // MMCSS — bu thread'i Pro Audio olarak işaretle
            try { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); } catch {}

            // Windows güç kısıtlamasını devre dışı bırak
            try
            {
                PROCESS_POWER_THROTTLING_STATE s;
                s.Version     = 1;
                s.ControlMask = 0x4;
                s.StateMask   = 0;
                SetProcessInformation(Process.GetCurrentProcess().Handle, 4,
                    ref s, Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE)));
            } catch {}

            // ekran/sistem uykusunu engelle
            try { SetThreadExecutionState(0x80000003u); } catch {}

            // yüksek çözünürlüklü waitable timer — Win11'de resolution aktif tutar
            try { hResTimer = CreateWaitableTimerExW(IntPtr.Zero, null, 0x00000002u, 0x1F0003u); } catch {}

            // servis sayfalarını RAM'de kilitle
            try
            {
                SetProcessWorkingSetSizeEx(
                    Process.GetCurrentProcess().Handle,
                    (UIntPtr)(4  * 1024 * 1024),   // 4 MB min
                    (UIntPtr)(64 * 1024 * 1024),   // 64 MB max
                    1u);                            // QUOTA_LIMITS_HARDWS_MIN_ENABLE
            } catch {}

            // ── config ────────────────────────────────────────────────────────
            ReadProcessList();

            // ── güç planı ────────────────────────────────────────────────────
            SetHighPerformancePower();

            // ── CPU affinity (P-core tespiti) ─────────────────────────────────
            SetPCoreMask();

            // ── işlemci C-state devre dışı ────────────────────────────────────
            DisableProcessorIdle();

            // ── GPU scheduler priority ────────────────────────────────────────
            BoostGpuPriority();

            // ── timer resolution ──────────────────────────────────────────────
            NtQueryTimerResolution(out minResolution, out maxResolution, out defaultResolution);

            if (customResolution > 0)
                targetResolution = customResolution;
            else
                targetResolution = Math.Min(RESOLUTION_TARGET, maxResolution);

            Log(string.Format(
                "[albus init] min={0} max={1} default={2} target={3} ({4:F3}ms) mod={5}",
                minResolution, maxResolution, defaultResolution,
                targetResolution, targetResolution / 10000.0,
                (processNames != null && processNames.Count > 0)
                    ? string.Join(",", processNames) : "global"));

            // ── network ───────────────────────────────────────────────────────
            TuneNetworkLatency();

            // ── global veya hedef process modu ───────────────────────────────
            if (processNames == null || processNames.Count == 0)
            {
                SetMaximumResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
                InvokePriorityBoost(true);
            }
            else
            {
                StartWatcher();
            }

            // ── arka plan işçileri ────────────────────────────────────────────
            StartResolutionGuard();
            StartPeriodicPurge();
            StartWatchdog();
            StartIniWatcher();
            StartLowAudioLatency();

            GhostMemory();
            base.OnStart(args);
        }

        protected override void OnStop()
        {
            try { SetThreadExecutionState(0x80000000u); } catch {}

            DropTimer(ref purgeTimer);
            DropTimer(ref guardTimer);
            DropTimer(ref watchdogTimer);

            try
            {
                if (startWatch != null)
                {
                    startWatch.Stop();
                    startWatch.Dispose();
                    startWatch = null;
                }
            } catch {}

            try
            {
                if (iniWatcher != null)
                {
                    iniWatcher.EnableRaisingEvents = false;
                    iniWatcher.Dispose();
                }
            } catch {}

            try
            {
                if (hResTimer != IntPtr.Zero)
                {
                    CloseHandle(hResTimer);
                    hResTimer = IntPtr.Zero;
                }
            } catch {}

            RestoreProcessorIdle();
            RestorePowerPlan();
            InvokePriorityBoost(false);

            try
            {
                uint actual = 0;
                NtSetTimerResolution(defaultResolution, true, out actual);
                Log(string.Format("[albus stop] resolution geri alindi: {0} ({1:F3}ms)",
                    actual, actual / 10000.0));
            } catch {}

            base.OnStop();
        }

        protected override void OnShutdown()
        {
            try { OnStop(); } catch {}
        }

        protected override bool OnPowerEvent(PowerBroadcastStatus s)
        {
            if (s == PowerBroadcastStatus.ResumeSuspend ||
                s == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(2000);
                SetHighPerformancePower();
                SetPCoreMask();
                DisableProcessorIdle();
                SetMaximumResolutionVerified();
                PurgeStandbyList();
                Log("[albus resume] uyku sonrasi yeniden silahlanma tamamlandi.");
            }
            return true;
        }

        static void DropTimer(ref Timer t)
        {
            if (t == null) return;
            try { t.Dispose(); } catch {}
            t = null;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  TIMER RESOLUTION
        // ══════════════════════════════════════════════════════════════════════

        void SetMaximumResolutionVerified()
        {
            long c = Interlocked.Increment(ref processCounter);
            if (c > 1) return;

            uint actual = 0;
            NtSetTimerResolution(targetResolution, true, out actual);

            // doğrulama döngüsü — 50 deneme, spin-wait ile
            for (int i = 0; i < 50; i++)
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetResolution + RESOLUTION_TOLERANCE) break;
                Thread.SpinWait(10000);
                NtSetTimerResolution(targetResolution, true, out actual);
            }

            Log(string.Format("[albus armed] dogrulandi: {0} ({1:F3}ms)", actual, actual / 10000.0));
        }

        void SetDefaultResolution()
        {
            long c = Interlocked.Decrement(ref processCounter);
            if (c >= 1) return;
            uint actual = 0;
            NtSetTimerResolution(defaultResolution, true, out actual);
        }

        void StartResolutionGuard()
        {
            guardTimer = new Timer(GuardCallback, null,
                TimeSpan.FromSeconds(GUARD_INTERVAL_SEC),
                TimeSpan.FromSeconds(GUARD_INTERVAL_SEC));
        }

        void GuardCallback(object state)
        {
            try
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetResolution + RESOLUTION_TOLERANCE) return;

                // 3 kez dene, spin-wait ile doğrula
                uint actual = 0;
                for (int i = 0; i < 3; i++)
                {
                    NtSetTimerResolution(targetResolution, true, out actual);
                    Thread.SpinWait(5000);
                    NtQueryTimerResolution(out qMin, out qMax, out qCur);
                    if (qCur <= targetResolution + RESOLUTION_TOLERANCE) break;
                }
                Log(string.Format("[albus guard] drift duzeltildi: {0} -> {1} ({2:F3}ms)",
                    qCur, actual, actual / 10000.0));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  CPU / PRİORİTY
        // ══════════════════════════════════════════════════════════════════════

        void SetPCoreMask()
        {
            // Intel 12. nesil+ hybrid mimaride servisi sadece P-core'larda çalıştır.
            // EfficiencyClass: yüksek değer = P-core (daha yüksek performans sınıfı)
            try
            {
                uint needed = 0;
                GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, IntPtr.Zero, 0);
                if (needed == 0) return;

                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint returned;
                    if (!GetSystemCpuSetInformation(buf, needed, out returned, IntPtr.Zero, 0))
                        return;

                    // 1. geçiş: maksimum efficiency sınıfını bul
                    byte maxClass = 0;
                    for (int off = 0; off < (int)returned; )
                    {
                        int sz = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff = Marshal.ReadByte(buf, off + 18);  // EfficiencyClass
                        if (eff > maxClass) maxClass = eff;
                        off += sz;
                    }

                    // tekdüze topoloji — affinity değiştirme
                    if (maxClass == 0)
                    {
                        Log("[albus cpu] tekdüze topoloji, affinity degismedi.");
                        return;
                    }

                    // 2. geçiş: P-core affinity maskesi oluştur
                    long mask = 0;
                    for (int off = 0; off < (int)returned; )
                    {
                        int  sz     = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff    = Marshal.ReadByte(buf, off + 18); // EfficiencyClass
                        byte logCpu = Marshal.ReadByte(buf, off + 14); // LogicalProcessorIndex
                        if (eff == maxClass) mask |= (1L << logCpu);
                        off += sz;
                    }

                    if (mask != 0)
                    {
                        Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)mask;
                        Log(string.Format("[albus cpu] hybrid: P-core mask 0x{0:X} ({1} mantiksal cekirdek)",
                            mask, CountBits(mask)));
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            } catch {}
        }

        static int CountBits(long v)
        {
            int c = 0;
            while (v != 0) { c += (int)(v & 1L); v >>= 1; }
            return c;
        }

        void InvokePriorityBoost(bool active)
        {
            try
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try { p.PriorityClass = ProcessPriorityClass.High; } catch {}

                ProcessPriorityClass expPrio = active
                    ? ProcessPriorityClass.BelowNormal
                    : ProcessPriorityClass.Normal;

                foreach (Process p in Process.GetProcessesByName("explorer"))
                    try { p.PriorityClass = expPrio; } catch {}

                if (active)
                    Log("[albus prio] dwm=high, explorer=belownormal.");
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GÜÇ YÖNETİMİ
        // ══════════════════════════════════════════════════════════════════════

        void SetHighPerformancePower()
        {
            try
            {
                // mevcut planı kaydet
                IntPtr pGuid;
                if (PowerGetActiveScheme(IntPtr.Zero, out pGuid) == 0)
                {
                    previousPowerScheme = (Guid)Marshal.PtrToStructure(pGuid, typeof(Guid));
                    LocalFree(pGuid);
                }

                // Ultimate Performance önce dene, başarısız olursa High Performance
                Guid ultimate = new Guid("e9a42b02-d5df-448d-aa00-03f14749eb61");
                Guid highPerf = new Guid("8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c");

                bool ok = (PowerSetActiveScheme(IntPtr.Zero, ref ultimate) == 0);
                if (!ok) ok = (PowerSetActiveScheme(IntPtr.Zero, ref highPerf) == 0);

                if (ok)
                {
                    powerSchemeChanged = true;
                    Log("[albus power] yuksek performans plani aktif.");
                }
            } catch {}
        }

        void RestorePowerPlan()
        {
            if (!powerSchemeChanged) return;
            try
            {
                PowerSetActiveScheme(IntPtr.Zero, ref previousPowerScheme);
                powerSchemeChanged = false;
                Log("[albus power] onceki güç plani geri yuklendi.");
            } catch {}
        }

        void DisableProcessorIdle()
        {
            // ProcessorIdleDisable (InfoLevel=14) ile C-state geçişlerini engelle.
            // C-state geçişleri timer wakeup latency'sini ciddi artırır.
            try
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 1);
                CallNtPowerInformation(14, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log("[albus power] islemci C-state'leri devre disi.");
            } catch {}
        }

        void RestoreProcessorIdle()
        {
            try
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 0);
                CallNtPowerInformation(14, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU
        // ══════════════════════════════════════════════════════════════════════

        void BoostGpuPriority()
        {
            // D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME = 5
            // GPU scheduling sırasında bu process en yüksek önceliği alır.
            try
            {
                int hr = D3DKMTSetProcessSchedulingPriorityClass(
                    Process.GetCurrentProcess().Handle, 5);
                Log(string.Format("[albus gpu] GPU scheduling realtime (hr=0x{0:X}).", hr));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  BELLEK
        // ══════════════════════════════════════════════════════════════════════

        void PurgeStandbyList()
        {
            // dosya önbelleği temizle
            try { SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0); } catch {}
            // MemoryPurgeStandbyList (class=80) — ISLC benzeri standby temizleme
            try
            {
                int cmd = 4;
                NtSetSystemInformation(80, ref cmd, sizeof(int));
            } catch {}
        }

        void GhostMemory()
        {
            // servis'in kendi working set'ini boşalt
            try { EmptyWorkingSet(Process.GetCurrentProcess().Handle); } catch {}
        }

        void StartPeriodicPurge()
        {
            purgeTimer = new Timer(PurgeCallback, null,
                TimeSpan.FromMinutes(PURGE_INITIAL_MIN),
                TimeSpan.FromMinutes(PURGE_INTERVAL_MIN));
        }

        void PurgeCallback(object state)
        {
            try
            {
                PerformanceCounter pc = new PerformanceCounter("Memory", "Available MBytes");
                float mb = pc.NextValue();
                pc.Dispose();
                if (mb < PURGE_THRESHOLD_MB)
                {
                    PurgeStandbyList();
                    Log(string.Format("[albus islc] purge tetiklendi, musait={0:F0}MB.", mb));
                }
            } catch {}
            GhostMemory();
        }

        // ══════════════════════════════════════════════════════════════════════
        //  NETWORK
        // ══════════════════════════════════════════════════════════════════════

        void TuneNetworkLatency()
        {
            // Nagle algoritmasını kapat, ACK gecikmesini sıfırla.
            // Düşük ping gerektiren uygulamalarda (FPS, RTS) gecikmeyi azaltır.
            try
            {
                RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters", true);
                if (key != null)
                {
                    key.SetValue("TcpAckFrequency", 1, RegistryValueKind.DWord);
                    key.SetValue("TCPNoDelay",      1, RegistryValueKind.DWord);
                    key.SetValue("TcpDelAckTicks",  0, RegistryValueKind.DWord);
                    key.Close();
                }
                Log("[albus net] TCP dusuk gecikme ayarlari uygulandi.");
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  PROCESS İZLEYİCİ  (hedef mod)
        // ══════════════════════════════════════════════════════════════════════

        void StartWatcher()
        {
            try
            {
                string query = string.Format(
                    "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 " +
                    "WHERE (TargetInstance isa \"Win32_Process\") AND " +
                    "(TargetInstance.Name=\"{0}\")",
                    string.Join("\" OR TargetInstance.Name=\"", processNames));

                startWatch               = new ManagementEventWatcher(query);
                startWatch.EventArrived += OnProcessArrived;
                startWatch.Stopped      += OnWatcherStopped;
                startWatch.Start();
                wmiRetryCount = 0;
                Log("[albus watcher] izleniyor: " + string.Join(", ", processNames));
            }
            catch (Exception ex)
            {
                Log("[albus watcher] hata: " + ex.Message, EventLogEntryType.Warning);
            }
        }

        void OnWatcherStopped(object sender, StoppedEventArgs e)
        {
            if (wmiRetryCount >= 5) return;
            wmiRetryCount++;
            Thread.Sleep(3000);
            try
            {
                if (startWatch != null)
                {
                    try { startWatch.Dispose(); } catch {}
                    startWatch = null;
                }
                StartWatcher();
                Log("[albus watcher] WMI yeniden baglandi.");
            } catch {}
        }

        void OnProcessArrived(object sender, EventArrivedEventArgs e)
        {
            try
            {
                ManagementBaseObject proc =
                    (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                uint pid = (uint)proc.Properties["ProcessId"].Value;
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid); });
            } catch {}
        }

        void ProcessStarted(uint pid)
        {
            try { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); } catch {}
            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch {}

            SetMaximumResolutionVerified();
            PurgeStandbyList();
            GhostMemory();
            InvokePriorityBoost(true);

            // process kapanana kadar bekle
            IntPtr hProc = IntPtr.Zero;
            try
            {
                hProc = OpenProcess(SYNCHRONIZE, 0, pid);
                if (hProc != IntPtr.Zero)
                    WaitForSingleObject(hProc, -1);
            } catch {}
            finally { if (hProc != IntPtr.Zero) try { CloseHandle(hProc); } catch {} }

            // process kapandıktan sonra temizle
            InvokePriorityBoost(false);
            SetDefaultResolution();
            PurgeStandbyList();
            GhostMemory();
            Log("[albus rested] process kapandi. onarim tamamlandi.");
        }

        // ══════════════════════════════════════════════════════════════════════
        //  YAPILANDIRMA / INI
        // ══════════════════════════════════════════════════════════════════════

        void ReadProcessList()
        {
            processNames     = null;
            customResolution = 0;

            string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
            if (!File.Exists(iniPath)) return;

            List<string> names = new List<string>();

            foreach (string raw in File.ReadAllLines(iniPath))
            {
                string line = raw.Trim();

                // boş satır veya yorum
                if (line.Length == 0 ||
                    line.StartsWith("#") ||
                    line.StartsWith("//")) continue;

                // resolution= satırı
                if (line.ToLowerInvariant().StartsWith("resolution="))
                {
                    uint val;
                    if (uint.TryParse(line.Substring(11).Trim(), out val))
                        customResolution = val;
                    continue;
                }

                // process adları
                foreach (string token in line.Split(
                    new char[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string name = token.ToLowerInvariant().Trim();
                    if (name.Length == 0) continue;
                    if (!name.EndsWith(".exe")) name += ".exe";
                    if (!names.Contains(name)) names.Add(name);
                }
            }

            // INI var ama process ismi yok → global mod
            processNames = (names.Count > 0) ? names : null;
        }

        void StartIniWatcher()
        {
            try
            {
                string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
                string dir     = Path.GetDirectoryName(iniPath);
                string file    = Path.GetFileName(iniPath);

                iniWatcher                      = new FileSystemWatcher(dir, file);
                iniWatcher.NotifyFilter         = NotifyFilters.LastWrite;
                iniWatcher.Changed             += OnIniChanged;
                iniWatcher.EnableRaisingEvents  = true;
            } catch {}
        }

        void OnIniChanged(object sender, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            try
            {
                ReadProcessList();

                targetResolution = customResolution > 0
                    ? customResolution
                    : Math.Min(RESOLUTION_TARGET, maxResolution);

                if (startWatch != null)
                {
                    try { startWatch.Stop(); startWatch.Dispose(); } catch {}
                    startWatch = null;
                }

                if (processNames != null && processNames.Count > 0)
                    StartWatcher();
                else
                {
                    SetMaximumResolutionVerified();
                    InvokePriorityBoost(true);
                }

                Log("[albus reload] yapilandirma guncellendi.");
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WATCHDOG
        // ══════════════════════════════════════════════════════════════════════

        void StartWatchdog()
        {
            watchdogTimer = new Timer(WatchdogCallback, null,
                TimeSpan.FromSeconds(WATCHDOG_INTERVAL_SEC),
                TimeSpan.FromSeconds(WATCHDOG_INTERVAL_SEC));
        }

        void WatchdogCallback(object state)
        {
            // servis priority korunuyor mu?
            try
            {
                Process self = Process.GetCurrentProcess();
                if (self.PriorityClass != ProcessPriorityClass.High)
                {
                    Log(string.Format("[albus watchdog] priority calinmis ({0}), geri aliniyor.",
                        self.PriorityClass));
                    self.PriorityClass = ProcessPriorityClass.High;
                }
            } catch {}

            // DWM korunuyor mu?
            try
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try
                    {
                        if (p.PriorityClass != ProcessPriorityClass.High)
                            p.PriorityClass = ProcessPriorityClass.High;
                    } catch {}
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SES GECİKMESİ
        // ══════════════════════════════════════════════════════════════════════

        void StartLowAudioLatency()
        {
            audioThread = new Thread(AudioWorker);
            audioThread.IsBackground = true;
            audioThread.Priority     = ThreadPriority.Highest;
            audioThread.Name         = "albus-audio";
            audioThread.Start();
        }

        void AudioWorker()
        {
            try { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); } catch {}
            try { CoInitializeEx(IntPtr.Zero, 0); } catch {}

            try
            {
                Type mmdeType = Type.GetTypeFromCLSID(
                    new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                IMMDeviceEnumerator enumerator =
                    (IMMDeviceEnumerator)Activator.CreateInstance(mmdeType);

                audioNotifier = new AudioNotifier();
                audioNotifier.Service    = this;
                audioNotifier.Enumerator = enumerator;
                enumerator.RegisterEndpointNotificationCallback(audioNotifier);

                OptimizeAllEndpoints(enumerator);
            } catch {}

            Thread.Sleep(Timeout.Infinite);
        }

        void OptimizeAllEndpoints(IMMDeviceEnumerator enumerator)
        {
            try
            {
                Guid IID_IAudioClient3 = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");

                IMMDeviceCollection col;
                if (enumerator.EnumAudioEndpoints(2, 1, out col) != 0) return;

                uint count;
                col.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    IMMDevice dev;
                    if (col.Item(i, out dev) != 0) continue;

                    object clientObj;
                    if (dev.Activate(ref IID_IAudioClient3, 0x17, IntPtr.Zero, out clientObj) != 0)
                        continue;

                    IAudioClient3 client = (IAudioClient3)clientObj;

                    IntPtr pFmt;
                    if (client.GetMixFormat(out pFmt) != 0) continue;

                    uint defFrames, fundFrames, minFrames, maxFrames;
                    bool periodOk = client.GetSharedModeEnginePeriod(
                        pFmt, out defFrames, out fundFrames, out minFrames, out maxFrames) == 0;

                    if (periodOk && minFrames < defFrames && minFrames > 0)
                    {
                        bool initOk = client.InitializeSharedAudioStream(
                            0, minFrames, pFmt, IntPtr.Zero) == 0;

                        if (initOk && client.Start() == 0)
                        {
                            lock (audioClients) audioClients.Add(clientObj);

                            WAVEFORMATEX fmt =
                                (WAVEFORMATEX)Marshal.PtrToStructure(pFmt, typeof(WAVEFORMATEX));
                            double minMs = (minFrames / (double)fmt.nSamplesPerSec) * 1000.0;
                            double defMs = (defFrames / (double)fmt.nSamplesPerSec) * 1000.0;

                            string devId;
                            dev.GetId(out devId);
                            string shortId = (devId != null && devId.Length > 8)
                                ? devId.Substring(devId.Length - 8) : (devId ?? "");

                            Log(string.Format(
                                "[albus audio] {0}: {1:F2}ms -> {2:F2}ms (kare {3}->{4})",
                                shortId, defMs, minMs, defFrames, minFrames));
                        }
                    }

                    Marshal.FreeCoTaskMem(pFmt);
                }
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  KAYIT
        // ══════════════════════════════════════════════════════════════════════

        static string Ts()
        {
            return DateTime.Now.ToString("HH:mm:ss");
        }

        void Log(string msg)
        {
            if (EventLog == null) return;
            try { EventLog.WriteEntry(string.Format("[{0}] {1}", Ts(), msg)); } catch {}
        }

        void Log(string msg, EventLogEntryType type)
        {
            if (EventLog == null) return;
            try { EventLog.WriteEntry(string.Format("[{0}] {1}", Ts(), msg), type); } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  P/INVOKE
        // ══════════════════════════════════════════════════════════════════════

        [DllImport("ntdll.dll")]
        static extern int NtSetTimerResolution(
            uint DesiredResolution, bool Set, out uint CurrentResolution);

        [DllImport("ntdll.dll")]
        static extern int NtQueryTimerResolution(
            out uint Min, out uint Max, out uint Current);

        [DllImport("ntdll.dll")]
        static extern int NtSetSystemInformation(
            int InfoClass, ref int Info, int InfoLength);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll")]
        static extern IntPtr OpenProcess(uint access, int inherit, uint pid);

        [DllImport("kernel32.dll")]
        static extern int WaitForSingleObject(IntPtr h, int ms);

        [DllImport("kernel32.dll")]
        static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(
            IntPtr attr, string name, uint flags, uint access);

        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(
            IntPtr hProcess, int InfoClass,
            ref PROCESS_POWER_THROTTLING_STATE Info, int InfoSize);

        [DllImport("kernel32.dll")]
        static extern uint SetThreadExecutionState(uint flags);

        [DllImport("kernel32.dll")]
        static extern bool SetProcessWorkingSetSizeEx(
            IntPtr hProc, UIntPtr minSize, UIntPtr maxSize, uint flags);

        [DllImport("kernel32.dll")]
        static extern bool GetSystemCpuSetInformation(
            IntPtr info, uint bufLen, out uint returned, IntPtr proc, uint flags);

        [DllImport("kernel32.dll")]
        static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("psapi.dll")]
        static extern int EmptyWorkingSet(IntPtr hProc);

        [DllImport("avrt.dll")]
        static extern IntPtr AvSetMmThreadCharacteristics(string task, ref uint index);

        [DllImport("ole32.dll")]
        static extern int CoInitializeEx(IntPtr pv, uint dwCoInit);

        [DllImport("powrprof.dll")]
        static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr pGuid);

        [DllImport("powrprof.dll")]
        static extern uint PowerSetActiveScheme(IntPtr root, ref Guid schemeGuid);

        [DllImport("powrprof.dll")]
        static extern uint CallNtPowerInformation(
            int InfoLevel, IntPtr inBuf, uint inLen, IntPtr outBuf, uint outLen);

        [DllImport("gdi32.dll")]
        static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr hProc, int priority);

        const uint SYNCHRONIZE = 0x00100000u;

        // ── yapılar ───────────────────────────────────────────────────────────

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_POWER_THROTTLING_STATE
        {
            public uint Version;
            public uint ControlMask;
            public uint StateMask;
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

        // ── COM arayüzleri ────────────────────────────────────────────────────

        [ComImport]
        [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint n);
            [PreserveSig] int Item(uint i, out IMMDevice dev);
        }

        [ComImport]
        [Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IMMNotificationClient
        {
            [PreserveSig] int OnDeviceStateChanged(
                [MarshalAs(UnmanagedType.LPWStr)] string id, int state);
            [PreserveSig] int OnDeviceAdded(
                [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDeviceRemoved(
                [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDefaultDeviceChanged(
                int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnPropertyValueChanged(
                [MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
        }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(
                int flow, int state, out IMMDeviceCollection col);
            [PreserveSig] int GetDefaultAudioEndpoint(
                int flow, int role, out IMMDevice dev);
            [PreserveSig] int GetDevice(
                [MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
            [PreserveSig] int RegisterEndpointNotificationCallback(
                IMMNotificationClient cb);
            [PreserveSig] int UnregisterEndpointNotificationCallback(
                IMMNotificationClient cb);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr pParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
            [PreserveSig] int OpenPropertyStore(int access, out IntPtr props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        [ComImport]
        [Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient3
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr sessionGuid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint padding);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long defPeriod, out long minPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr h);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
            [PreserveSig] int IsOffloadCapable(int cat, out int capable);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetSharedModeEnginePeriod(IntPtr fmt,
                out uint def, out uint fund, out uint min, out uint max);
            [PreserveSig] int GetCurrentSharedModeEnginePeriod(
                out IntPtr fmt, out uint period);
            [PreserveSig] int InitializeSharedAudioStream(uint flags,
                uint periodFrames, IntPtr fmt, IntPtr sessionGuid);
        }

        // ── iç sınıflar ───────────────────────────────────────────────────────

        class AudioNotifier : IMMNotificationClient
        {
            public AlbusService      Service;
            public IMMDeviceEnumerator Enumerator;

            public int OnDeviceStateChanged(string id, int state) { return 0; }
            public int OnDeviceAdded(string id)                   { return 0; }
            public int OnDeviceRemoved(string id)                 { return 0; }
            public int OnPropertyValueChanged(string id, IntPtr key) { return 0; }

            public int OnDefaultDeviceChanged(int flow, int role, string id)
            {
                try
                {
                    if (Service != null)
                    {
                        Service.Log("[albus audio] cihaz degisimi — tamponlar yeniden optimize ediliyor.");
                        lock (Service.audioClients) Service.audioClients.Clear();
                        if (Enumerator != null)
                            Service.OptimizeAllEndpoints(Enumerator);
                    }
                } catch {}
                return 0;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  KURULUM
    // ══════════════════════════════════════════════════════════════════════════

    [RunInstaller(true)]
    public class AlbusInstaller : Installer
    {
        public AlbusInstaller()
        {
            ServiceProcessInstaller spi = new ServiceProcessInstaller();
            spi.Account  = ServiceAccount.LocalSystem;
            spi.Username = null;
            spi.Password = null;

            ServiceInstaller si = new ServiceInstaller();
            si.DisplayName  = "albus";
            si.ServiceName  = "AlbusSvc";
            si.StartType    = ServiceStartMode.Automatic;
            si.Description  =
                "albus v2.0 — hassas gecikme servisi: " +
                "timer çözünürlüğü, CPU affinity, ses gecikmesi, bellek, güç.";

            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
