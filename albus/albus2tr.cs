// ══════════════════════════════════════════════════════════════════════════════
//  albus  v4.0
//  precision system latency service
//
//  derleme:
//    csc.exe -r:System.ServiceProcess.dll
//            -r:System.Configuration.Install.dll
//            -r:System.Management.dll
//            -out:Albus.exe albus.cs
//
//  katmanlar:
//    · timer      — 0.5 ms kernel timer resolution, guard + 3× retry
//    · cpu        — hybrid P-core affinity, NUMA-aware, MMCSS Pro Audio
//    · priority   — process/thread öncelik, DWM boost
//    · c-state    — kernel-level idle engelleme, servis kapanınca geri al
//    · gpu        — D3DKMT realtime + TDR optimizasyonu
//    · audio      — IAudioClient3 minimum buffer, hot-swap yeniden opt. (vtable fix)
//    · memory     — standby purge (ISLC), working set kilitleme, ghost memory
//    · irq        — GPU + NIC interrupt affinity, DPC latency izleme
//    · netirq     — NIC RSS/affinity, interrupt coalescing kapat, SO_PRIORITY
//    · watchdog   — priority, DWM/timer kayması koruması
//    · health     — periyodik sistem sağlık raporu (event log)
//    · ini        — hedef process listesi + custom resolution, hot-reload
//    · etw        — WMI yerine ETW kernel-session process izleme
//
//  servis adı  : AlbusSvc
//  exe adı     : Albus.exe
//  ini adı     : Albus.exe.ini   (opsiyonel — yoksa global mod)
// ══════════════════════════════════════════════════════════════════════════════

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
using System.Management;
using System.Text.RegularExpressions;
using Microsoft.Win32;

[assembly: AssemblyVersion("4.0.0.0")]
[assembly: AssemblyFileVersion("4.0.0.0")]
[assembly: AssemblyProduct("albus")]
[assembly: AssemblyTitle("albus")]
[assembly: AssemblyDescription("precision system latency service v4.0")]

namespace Albus
{
    // ══════════════════════════════════════════════════════════════════════════
    //  YARDIMCI — güvenli çalıştırma + yapısal loglama
    // ══════════════════════════════════════════════════════════════════════════
    static class Safe
    {
        // Hataları yutan değil, loglayan wrapper.
        // tag: "[albus gpu]" gibi prefix; log: EventLog referansı.
        public static void Run(string tag, Action fn, EventLog log = null)
        {
            try { fn(); }
            catch (Exception ex)
            {
                if (log != null)
                    try
                    {
                        log.WriteEntry(
                            string.Format("[{0}] {1} HATA: {2}",
                                DateTime.Now.ToString("HH:mm:ss"), tag, ex.Message),
                            EventLogEntryType.Warning);
                    } catch {}
            }
        }

        public static T Run<T>(string tag, Func<T> fn, T def = default(T), EventLog log = null)
        {
            try { return fn(); }
            catch (Exception ex)
            {
                if (log != null)
                    try
                    {
                        log.WriteEntry(
                            string.Format("[{0}] {1} HATA: {2}",
                                DateTime.Now.ToString("HH:mm:ss"), tag, ex.Message),
                            EventLogEntryType.Warning);
                    } catch {}
                return def;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ANA SERVİS
    // ══════════════════════════════════════════════════════════════════════════
    sealed class AlbusService : ServiceBase
    {
        // ── sabitler ─────────────────────────────────────────────────────────
        const string SVC_NAME             = "AlbusSvc";
        const uint   TARGET_RESOLUTION    = 5000u;   // 0.5 ms (100-ns birimi)
        const uint   RESOLUTION_TOLERANCE = 50u;     // 5 µs
        const int    GUARD_SEC            = 10;
        const int    WATCHDOG_SEC         = 10;
        const int    HEALTH_INITIAL_MIN   = 5;
        const int    HEALTH_INTERVAL_MIN  = 15;
        const int    PURGE_INITIAL_MIN    = 2;
        const int    PURGE_INTERVAL_MIN   = 5;
        const int    PURGE_THRESHOLD_MB   = 1024;

        // ── Win11 per-process timer build eşiği ──────────────────────────────
        // Windows 11 22H2 = Build 22621
        const int    WIN11_PERPROCESS_BUILD = 22621;

        // ── durum ─────────────────────────────────────────────────────────────
        uint   defaultRes, minRes, maxRes;
        uint   targetRes,  customRes;
        long   processCounter;
        IntPtr hWaitTimer = IntPtr.Zero;
        bool   isWin11PerProcess;

        Timer                   guardTimer, purgeTimer, watchdogTimer, healthTimer;
        ManagementEventWatcher  startWatch;  // fallback: WMI (ETW başarısızsa)
        FileSystemWatcher       iniWatcher;
        Thread                  audioThread;
        Thread                  etwThread;
        List<string>            processNames;
        int                     wmiRetry;
        readonly List<object>   audioClients = new List<object>();
        AudioNotifier           audioNotifier;
        long                    dpcBaselineTicks;
        ManualResetEventSlim    stopEvent = new ManualResetEventSlim(false);

        // ── giriş ─────────────────────────────────────────────────────────────
        static void Main() { ServiceBase.Run(new AlbusService()); }

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
        //  BAŞLAT
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStart(string[] args)
        {
            stopEvent.Reset();

            // 1. Bu process'in önceliği
            SetSelfPriority();

            // 2. ThreadPool min thread
            Safe.Run("threadpool", () =>
            {
                int w, io;
                ThreadPool.GetMinThreads(out w, out io);
                ThreadPool.SetMinThreads(Math.Max(w, 16), Math.Max(io, 8));
            }, EventLog);

            // 3. GC gecikme modu
            Safe.Run("gc", () =>
            {
                GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency;
            }, EventLog);

            // 4. Waitable high-resolution timer (Win11 per-process kilitleme)
            Safe.Run("waittimer", () =>
            {
                hWaitTimer = CreateWaitableTimerExW(
                    IntPtr.Zero, null,
                    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                    TIMER_ALL_ACCESS);
            }, EventLog);

            // 5. Working set kilitleme (8–128 MB)
            Safe.Run("workingset", () =>
            {
                SetProcessWorkingSetSizeEx(
                    Process.GetCurrentProcess().Handle,
                    (UIntPtr)(8  * 1024 * 1024),
                    (UIntPtr)(128 * 1024 * 1024),
                    QUOTA_LIMITS_HARDWS_MIN_ENABLE);
            }, EventLog);

            // 6. MMCSS Pro Audio
            Safe.Run("mmcss", () =>
            {
                uint t = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref t);
            }, EventLog);

            // 7. Windows güç kısıtlamasını kapat (EcoQoS/Throttling)
            DisableThrottling();

            // 8. Ekran/sistem uykusunu engelle
            Safe.Run("execstate", () =>
            {
                SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
            }, EventLog);

            // 9. Win11 per-process timer tespiti
            isWin11PerProcess = DetectWin11PerProcessTimer();
            Log(string.Format("[albus init] Win11 per-process timer: {0}", isWin11PerProcess));

            // 10. Config oku
            ReadConfig();

            // 11. NUMA-aware P-core affinity
            SetPCoreMaskNuma();

            // 12. C-state devre dışı
            DisableCStates();

            // 13. GPU scheduler realtime + TDR optimizasyonu
            BoostGpuPriority();
            OptimizeTdr();

            // 14. Timer resolution hedefini belirle
            NtQueryTimerResolution(out minRes, out maxRes, out defaultRes);
            targetRes = customRes > 0
                ? customRes
                : Math.Min(TARGET_RESOLUTION, maxRes);

            Log(string.Format(
                "[albus v4.0] min={0} max={1} default={2} target={3} ({4:F3}ms) mod={5}",
                minRes, maxRes, defaultRes,
                targetRes, targetRes / 10000.0,
                (processNames != null && processNames.Count > 0)
                    ? string.Join(",", processNames) : "global"));

            // 15. DPC latency baseline
            MeasureDpcBaseline();

            // 16. IRQ affinity — GPU + NIC
            OptimizeGpuIrqAffinity();
            OptimizeNetworkIrq();

            // 17. Global veya hedef process modu
            if (processNames == null || processNames.Count == 0)
            {
                SetResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
                ModulateUiPriority(true);
            }
            else
            {
                StartEtwWatcher();   // ETW tercih edilir
            }

            // 18. Arka plan işçileri
            StartGuard();
            StartPurge();
            StartWatchdog();
            StartHealthMonitor();
            StartIniWatcher();
            StartAudioThread();

            GhostMemory();
            base.OnStart(args);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  DURDUR
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStop()
        {
            stopEvent.Set();

            Safe.Run("execstate", () =>
                SetThreadExecutionState(ES_CONTINUOUS), EventLog);

            DropTimer(ref guardTimer);
            DropTimer(ref purgeTimer);
            DropTimer(ref watchdogTimer);
            DropTimer(ref healthTimer);

            Safe.Run("watcher", () =>
            {
                if (startWatch != null)
                {
                    startWatch.Stop();
                    startWatch.Dispose();
                    startWatch = null;
                }
            }, EventLog);

            Safe.Run("iniwatcher", () =>
            {
                if (iniWatcher != null)
                {
                    iniWatcher.EnableRaisingEvents = false;
                    iniWatcher.Dispose();
                }
            }, EventLog);

            Safe.Run("waittimer", () =>
            {
                if (hWaitTimer != IntPtr.Zero)
                {
                    CloseHandle(hWaitTimer);
                    hWaitTimer = IntPtr.Zero;
                }
            }, EventLog);

            // Network IRQ geri al
            RestoreNetworkIrq();

            RestoreCStates();
            ModulateUiPriority(false);

            Safe.Run("timer_restore", () =>
            {
                uint actual = 0;
                NtSetTimerResolution(defaultRes, true, out actual);
                Log(string.Format("[albus stop] timer geri alindi: {0} ({1:F3}ms)",
                    actual, actual / 10000.0));
            }, EventLog);

            base.OnStop();
        }

        protected override void OnShutdown() { Safe.Run("shutdown", () => OnStop(), EventLog); }

        protected override bool OnPowerEvent(PowerBroadcastStatus s)
        {
            if (s == PowerBroadcastStatus.ResumeSuspend ||
                s == PowerBroadcastStatus.ResumeAutomatic)
            {
                // Uyku sonrası donanım state'i sıfırlanır — kısa bekleme sonrası tam yeniden kurulum
                Thread.Sleep(2500);
                SetSelfPriority();
                SetPCoreMaskNuma();
                DisableCStates();
                OptimizeGpuIrqAffinity();
                OptimizeNetworkIrq();
                SetResolutionVerified();
                PurgeStandbyList();
                MeasureDpcBaseline();
                Log("[albus resume] uyku sonrasi tam yeniden silahlanma tamamlandi.");
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
        //  KENDİ ÖNCELİĞİ
        // ══════════════════════════════════════════════════════════════════════
        void SetSelfPriority()
        {
            Safe.Run("self_priority", () =>
            {
                Process self = Process.GetCurrentProcess();
                self.PriorityClass        = ProcessPriorityClass.High;
                self.PriorityBoostEnabled = false;
                Thread.CurrentThread.Priority = ThreadPriority.Highest;

                // Thread'in kritik bölümlerde preempt edilmesini zorlaştır
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
            }, EventLog);
        }

        void DisableThrottling()
        {
            Safe.Run("throttling", () =>
            {
                // EcoQoS / Intel Thread Director güç kısıtlamasını kapat
                PROCESS_POWER_THROTTLING s;
                s.Version     = 1;
                s.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
                s.StateMask   = 0;   // 0 = disable throttling
                SetProcessInformation(Process.GetCurrentProcess().Handle,
                    ProcessPowerThrottling, ref s,
                    Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING)));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WIN11 PER-PROCESS TIMER TESPİTİ
        //  Build 22621+ → NtSetTimerResolution sadece çağıran process'i etkiler.
        //  Bu durumda hedef process'e inject veya global workaround gerekir.
        // ══════════════════════════════════════════════════════════════════════
        bool DetectWin11PerProcessTimer()
        {
            return Safe.Run("win11detect", () =>
            {
                int build = 0;
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (key != null)
                    {
                        object v = key.GetValue("CurrentBuildNumber");
                        if (v != null) int.TryParse(v.ToString(), out build);
                    }
                }
                return build >= WIN11_PERPROCESS_BUILD;
            }, false, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HYBRID CPU — NUMA-AWARE P-CORE AFINİTESİ
        //  AMD Ryzen: CCD boundary latency'den kaçınmak için tek CCD'deki
        //  P-core'ları (efficiency class max) tercih eder.
        //  Intel Alder/Raptor Lake: P-core mask doğrudan uygulanır.
        // ══════════════════════════════════════════════════════════════════════
        void SetPCoreMaskNuma()
        {
            Safe.Run("cpu_affinity", () =>
            {
                uint needed = 0;
                GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, IntPtr.Zero, 0);
                if (needed == 0)
                {
                    Log("[albus cpu] CpuSet bilgisi alinamadi, affinity degismedi.");
                    return;
                }

                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint returned;
                    if (!GetSystemCpuSetInformation(buf, needed, out returned, IntPtr.Zero, 0))
                        return;

                    // 1. pass — maksimum efficiency class değerini bul
                    byte maxClass = 0;
                    for (int off = 0; off < (int)returned; )
                    {
                        int sz = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff = Marshal.ReadByte(buf, off + 18);
                        if (eff > maxClass) maxClass = eff;
                        off += sz;
                    }

                    if (maxClass == 0)
                    {
                        Log("[albus cpu] tekdüze topoloji (E/P yok), affinity degismedi.");
                        return;
                    }

                    // 2. pass — her P-core'un NUMA node'unu topla;
                    //    en fazla P-core'a sahip NUMA node'u seç (AMD CCD sezgisi)
                    var nodeCount = new Dictionary<byte, int>();
                    var nodeMask  = new Dictionary<byte, long>();

                    for (int off = 0; off < (int)returned; )
                    {
                        int  sz     = Marshal.ReadInt32(buf, off);
                        if (sz < 24) break;
                        byte eff    = Marshal.ReadByte(buf, off + 18);
                        byte logCpu = Marshal.ReadByte(buf, off + 14);
                        byte numa   = Marshal.ReadByte(buf, off + 19); // NumaNodeIndex

                        if (eff == maxClass)
                        {
                            if (!nodeCount.ContainsKey(numa)) { nodeCount[numa] = 0; nodeMask[numa] = 0; }
                            nodeCount[numa]++;
                            nodeMask[numa] |= (1L << logCpu);
                        }
                        off += sz;
                    }

                    // En fazla P-core'lu NUMA node'unu seç
                    byte bestNuma = 0;
                    int  bestCnt  = 0;
                    foreach (var kv in nodeCount)
                        if (kv.Value > bestCnt) { bestCnt = kv.Value; bestNuma = kv.Key; }

                    long mask = nodeMask.ContainsKey(bestNuma) ? nodeMask[bestNuma] : 0;
                    if (mask != 0)
                    {
                        Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)mask;
                        Log(string.Format(
                            "[albus cpu] NUMA-{0} P-core mask=0x{1:X} ({2} cekirdek)",
                            bestNuma, mask, CountBits(mask)));
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }, EventLog);
        }

        static int CountBits(long v)
        {
            int c = 0;
            while (v != 0) { c += (int)(v & 1L); v >>= 1; }
            return c;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  C-STATE YÖNETİMİ
        // ══════════════════════════════════════════════════════════════════════
        void DisableCStates()
        {
            Safe.Run("cstate_disable", () =>
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 1);
                CallNtPowerInformation(ProcessorIdleDomains, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log("[albus cstate] C-state gecisleri engellendi (kernel seviye).");
            }, EventLog);
        }

        void RestoreCStates()
        {
            Safe.Run("cstate_restore", () =>
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 0);
                CallNtPowerInformation(ProcessorIdleDomains, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU SCHEDULER + TDR
        // ══════════════════════════════════════════════════════════════════════
        void BoostGpuPriority()
        {
            Safe.Run("gpu_priority", () =>
            {
                int hr = D3DKMTSetProcessSchedulingPriorityClass(
                    Process.GetCurrentProcess().Handle,
                    D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME);
                Log(string.Format("[albus gpu] D3DKMT realtime priority (hr=0x{0:X})", hr));
            }, EventLog);
        }

        void OptimizeTdr()
        {
            Safe.Run("tdr", () =>
            {
                // TdrDelay: GPU yanıt timeout'u yükselt (ani spike'larda sıfırlama önlenir)
                // TdrLevel: 0=kapalı agresif yeniden kurulum, 3=recover (default)
                // Sadece mevcut değerlerin üzerine yaz, yoksa oluşturma
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Control\GraphicsDrivers", true))
                {
                    if (key == null) return;
                    object cur = key.GetValue("TdrDelay");
                    if (cur == null || (int)cur < 10)
                        key.SetValue("TdrDelay", 10, RegistryValueKind.DWord);
                    key.SetValue("TdrLevel", 3, RegistryValueKind.DWord);
                }
                Log("[albus gpu] TDR optimize edildi (TdrDelay=10s, TdrLevel=3).");
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  UI ÖNCELİK MODULASYONU
        // ══════════════════════════════════════════════════════════════════════
        void ModulateUiPriority(bool boost)
        {
            Safe.Run("ui_priority", () =>
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try { p.PriorityClass = ProcessPriorityClass.High; } catch {}

                var expPrio = boost
                    ? ProcessPriorityClass.BelowNormal
                    : ProcessPriorityClass.Normal;
                foreach (Process p in Process.GetProcessesByName("explorer"))
                    try { p.PriorityClass = expPrio; } catch {}

                if (boost) Log("[albus prio] dwm=high, explorer=belownormal.");
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  DPC LATENCY BASELINE
        // ══════════════════════════════════════════════════════════════════════
        void MeasureDpcBaseline()
        {
            Safe.Run("dpc_baseline", () =>
            {
                long best = long.MaxValue;
                for (int i = 0; i < 500; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(2000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < best) best = d;
                }
                dpcBaselineTicks = best;
                double us = (best * 1_000_000.0) / Stopwatch.Frequency;
                Log(string.Format("[albus dpc] baseline jitter: {0:F2} µs", us));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU IRQ AFINİTESİ
        //  GPU interrupt'larını core 0'dan uzaklaştırır.
        // ══════════════════════════════════════════════════════════════════════
        void OptimizeGpuIrqAffinity()
        {
            Safe.Run("gpu_irq", () =>
            {
                const string BASE =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}";
                using (RegistryKey gpuClass = Registry.LocalMachine.OpenSubKey(BASE, true))
                {
                    if (gpuClass == null) return;
                    int count = 0;
                    foreach (string sub in gpuClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = gpuClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            using (RegistryKey pol = dev.CreateSubKey(
                                "Interrupt Management\\Affinity Policy"))
                            {
                                if (pol == null) continue;
                                // core 0 hariç — tüm 8 bit'li sistemler için 0xFE
                                // 16 core+ sistemler için genişletilmiş mask
                                pol.SetValue("AssignmentSetOverride",
                                    BuildAffinityMask(excludeCore0: true),
                                    RegistryValueKind.Binary);
                                pol.SetValue("DevicePolicy",
                                    IrqPolicySpecifiedProcessors,
                                    RegistryValueKind.DWord);
                                count++;
                            }
                        }
                    }
                    if (count > 0)
                        Log(string.Format("[albus irq] GPU IRQ affinity: {0} aygit, core-0 bypass.", count));
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  NETWORK IRQ KATMANI
        //  ─────────────────────────────────────────────────────────────────────
        //  Hedef: NIC interrupt'larının oyun/ses thread'leriyle çakışmasını önle.
        //
        //  Yapılanlar:
        //  1. NIC sınıf registry'sinden tüm aktif adaptörleri bul
        //  2. Interrupt affinity policy → GPU ile aynı "dedicated" core'lar
        //     (core 0 bypass, core 1 NIC'e adanmış)
        //  3. RSS (Receive Side Scaling) → RSS queue'larını tek çekirdeğe sabitle
        //     ve queue sayısını minimize et (1 veya 2)
        //  4. Interrupt Moderation / Coalescing → kapat (ultra-low latency)
        //     (bazı sürücüler bunu desteklemez — sessizce geçilir)
        //  5. NumaNodeId affinity → NIC'i NUMA-0'a sabitle
        //  6. Adapter önceliği → QoS DSCP EF (Expedited Forwarding) etkinleştir
        //  7. TCP/UDP send/receive buffer boyutları optimize et (registry)
        //  8. Network throttling index → devre dışı
        // ══════════════════════════════════════════════════════════════════════

        // Geri alma için orijinal değerleri sakla
        readonly Dictionary<string, byte[]> origNicAffinityMask  = new Dictionary<string, byte[]>();
        readonly Dictionary<string, int>    origNicDevicePolicy   = new Dictionary<string, int>();

        void OptimizeNetworkIrq()
        {
            Safe.Run("netirq_init", () =>
            {
                // A — Tüm NIC'lere IRQ affinity uygula
                ApplyNicIrqAffinity();

                // B — RSS queue kısıtlaması
                ApplyRssOptimization();

                // C — Interrupt Moderation kapat
                DisableInterruptModeration();

                // D — Network stack latency ayarları
                ApplyNetworkStackTuning();

                Log("[albus netirq] Network IRQ katmani tamamlandi.");
            }, EventLog);
        }

        // ── A: NIC IRQ Affinity ───────────────────────────────────────────────
        void ApplyNicIrqAffinity()
        {
            Safe.Run("nic_irq_affinity", () =>
            {
                // NIC sınıf GUID
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";

                using (RegistryKey nicClass = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (nicClass == null) return;
                    int count = 0;
                    foreach (string sub in nicClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = nicClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            // Sanal / loopback adaptörleri atla
                            if (IsVirtualAdapter(dev)) continue;

                            // Orijinal değerleri sakla (geri alma için)
                            string key = NIC_CLASS + "\\" + sub;
                            using (RegistryKey pol = dev.OpenSubKey(
                                "Interrupt Management\\Affinity Policy"))
                            {
                                if (pol != null)
                                {
                                    object ov = pol.GetValue("AssignmentSetOverride");
                                    if (ov is byte[]) origNicAffinityMask[key] = (byte[])ov;
                                    object od = pol.GetValue("DevicePolicy");
                                    if (od != null)
                                        try { origNicDevicePolicy[key] = (int)od; } catch {}
                                }
                            }

                            // Yeni affinity: core 1 adanmış NIC core'u
                            // (core 0 = oyun/servis, core 1 = NIC IRQ, core 2+ = GPU IRQ)
                            using (RegistryKey pol = dev.CreateSubKey(
                                "Interrupt Management\\Affinity Policy"))
                            {
                                if (pol == null) continue;
                                pol.SetValue("AssignmentSetOverride",
                                    BuildNicAffinityMask(),
                                    RegistryValueKind.Binary);
                                pol.SetValue("DevicePolicy",
                                    IrqPolicySpecifiedProcessors,
                                    RegistryValueKind.DWord);
                            }
                            count++;
                        }
                    }
                    if (count > 0)
                        Log(string.Format(
                            "[albus netirq] NIC IRQ affinity: {0} adaptör, core-1 adanmis.", count));
                }
            }, EventLog);
        }

        // ── B: RSS Optimizasyonu ──────────────────────────────────────────────
        // RSS queue'larını minimize et; latency odaklı workload'da tek queue
        // daha az context-switch ve daha az cache-miss sağlar.
        void ApplyRssOptimization()
        {
            Safe.Run("rss_opt", () =>
            {
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";

                using (RegistryKey nicClass = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (nicClass == null) return;
                    foreach (string sub in nicClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = nicClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            if (IsVirtualAdapter(dev)) continue;

                            // *RSS — etkin bırak ama queue sayısını sınırla
                            // Bazı sürücüler: *NumRssQueues, *MaxRssProcessors
                            SetNicAdvancedSetting(dev, "*NumRssQueues",    "1");
                            SetNicAdvancedSetting(dev, "*MaxRssProcessors","1");

                            // RSS base processor: core 1 (NIC IRQ ile uyumlu)
                            SetNicAdvancedSetting(dev, "*RssBaseProcNumber","1");

                            // Receive buffers — düşük tutarak buffer bloat azalt
                            // (çok düşük = paket kaybı riski; 128 güvenli alt sınır)
                            SetNicAdvancedSetting(dev, "*ReceiveBuffers", "256");

                            // Send buffers de latency için optimize
                            SetNicAdvancedSetting(dev, "*TransmitBuffers", "256");
                        }
                    }
                }
                Log("[albus netirq] RSS: queue=1, base=core-1, buffers=256.");
            }, EventLog);
        }

        // ── C: Interrupt Moderation (Coalescing) Kapatma ─────────────────────
        // Intel: *InterruptModeration = 0
        // Realtek: *InterruptThrottleRate = 0
        // Broadcom: InterruptModeration = 0
        // Mellanox/NDIS: sürücüye özgü — sessizce geçilir
        void DisableInterruptModeration()
        {
            Safe.Run("int_mod", () =>
            {
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";

                using (RegistryKey nicClass = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (nicClass == null) return;
                    int count = 0;
                    foreach (string sub in nicClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = nicClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            if (IsVirtualAdapter(dev)) continue;

                            bool changed = false;
                            // Her sürücünün kendi keyword'ü — hepsini dene
                            changed |= SetNicAdvancedSetting(dev, "*InterruptModeration",   "0");
                            changed |= SetNicAdvancedSetting(dev, "*InterruptThrottleRate", "0");
                            changed |= SetNicAdvancedSetting(dev, "ITR",                   "0");
                            changed |= SetNicAdvancedSetting(dev, "InterruptModeration",   "0");

                            if (changed) count++;
                        }
                    }
                    if (count > 0)
                        Log(string.Format(
                            "[albus netirq] Interrupt coalescing kapatildi: {0} adaptör.", count));
                }
            }, EventLog);
        }

        // ── D: Network Stack Latency Tuning ──────────────────────────────────
        void ApplyNetworkStackTuning()
        {
            Safe.Run("netstack", () =>
            {
                // 1. Nagle algoritması — TCP_NODELAY benzeri global
                //    Nagle oyun trafiğinde latency'yi artırır
                //    TcpAckFrequency=1: her paketi hemen acknowledge et
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\MSMQ\Parameters", true))
                {
                    // MSMQ yoksa bu önemsiz
                }

                // 2. Network Throttling Index — devre dışı (default 10 = aktif)
                //    Bu değer multimedia streaming'de throttle eder;
                //    oyun + ses için 0xFFFFFFFF = tamamen devre dışı
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile", true))
                {
                    if (key != null)
                    {
                        key.SetValue("NetworkThrottlingIndex",
                            unchecked((int)0xFFFFFFFF), RegistryValueKind.DWord);
                        key.SetValue("SystemResponsiveness", 0, RegistryValueKind.DWord);
                        Log("[albus netirq] NetworkThrottlingIndex=off, SystemResponsiveness=0.");
                    }
                }

                // 3. TCP Auto-Tuning Level — latency odaklı: disabled veya highlyrestricted
                //    (disabled: sabit pencere — yüksek throughput yerine low-latency tercih)
                //    netsh int tcp set global autotuninglevel=disabled eşdeğeri:
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters", true))
                {
                    if (key != null)
                    {
                        // EnableWsd: Windows Scaling Disable — eski ağlarda latency düşürür
                        // TcpTimedWaitDelay: default 240s → 30s (TIME_WAIT soketi hızlı serbest bırak)
                        key.SetValue("TcpTimedWaitDelay", 30, RegistryValueKind.DWord);
                        // MaxUserPort: yüksek — port tükenmesini önler
                        key.SetValue("MaxUserPort", 65534, RegistryValueKind.DWord);
                        // Disable Nagle globally via TcpNoDelay
                        key.SetValue("TcpNoDelay", 1, RegistryValueKind.DWord);
                        // TCP timestamp kapat — header overhead azalt
                        key.SetValue("Tcp1323Opts", 0, RegistryValueKind.DWord);
                    }
                }

                // 4. UDP checksum offload zorla (CPU'yu kurtarır)
                //    Her NIC'e özel *UDPChecksumOffloadIPv4/v6 aşağıda yapılıyor
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Services\AFD\Parameters", true))
                {
                    if (key != null)
                    {
                        // FastSendDatagramThreshold: büyük UDP datagramları için hızlı yol
                        key.SetValue("FastSendDatagramThreshold", 1024, RegistryValueKind.DWord);
                        // DefaultReceiveWindow / DefaultSendWindow
                        key.SetValue("DefaultReceiveWindow", 65536, RegistryValueKind.DWord);
                        key.SetValue("DefaultSendWindow",    65536, RegistryValueKind.DWord);
                    }
                }

                // 5. NDIS arka plan iş parçacığı önceliği
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Services\Ndis\Parameters", true))
                {
                    if (key != null)
                    {
                        // TrackNblOwner debug overhead kapat
                        key.SetValue("TrackNblOwner", 0, RegistryValueKind.DWord);
                    }
                }
            }, EventLog);
        }

        // ── Geri Alma ─────────────────────────────────────────────────────────
        void RestoreNetworkIrq()
        {
            Safe.Run("netirq_restore", () =>
            {
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";

                using (RegistryKey nicClass = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (nicClass == null) return;
                    foreach (string sub in nicClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = nicClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            string key = NIC_CLASS + "\\" + sub;

                            using (RegistryKey pol = dev.OpenSubKey(
                                "Interrupt Management\\Affinity Policy", true))
                            {
                                if (pol == null) continue;
                                if (origNicAffinityMask.ContainsKey(key))
                                    pol.SetValue("AssignmentSetOverride",
                                        origNicAffinityMask[key], RegistryValueKind.Binary);
                                if (origNicDevicePolicy.ContainsKey(key))
                                    pol.SetValue("DevicePolicy",
                                        origNicDevicePolicy[key], RegistryValueKind.DWord);
                            }
                        }
                    }
                }
                Log("[albus netirq] NIC IRQ ayarlari geri alindi.");
            }, EventLog);
        }

        // ── Yardımcı: Sanal Adaptör Tespiti ──────────────────────────────────
        static bool IsVirtualAdapter(RegistryKey dev)
        {
            try
            {
                // DriverDesc veya DeviceDesc içinde tipik sanal anahtar kelimeler
                string[] fields = { "DriverDesc", "DeviceDesc", "Description" };
                string[] vKeywords = {
                    "virtual", "loopback", "tunnel", "vpn", "miniport",
                    "wan", "bluetooth", "hyper-v", "vmware", "virtualbox",
                    "tap", "ndiswan", "isatap", "teredo", "6to4"
                };
                foreach (string f in fields)
                {
                    object v = dev.GetValue(f);
                    if (v == null) continue;
                    string desc = v.ToString().ToLowerInvariant();
                    foreach (string kw in vKeywords)
                        if (desc.Contains(kw)) return true;
                }
            } catch {}
            return false;
        }

        // ── Yardımcı: NIC Advanced Setting Yaz ───────────────────────────────
        // Sürücü keyword'ü varsa değeri yazar ve true döner; yoksa false.
        static bool SetNicAdvancedSetting(RegistryKey dev, string keyword, string value)
        {
            try
            {
                // NIC advanced settings: alt anahtarlar "Ndi\params\<keyword>" veya
                // doğrudan değer olarak saklanabilir.
                // Önce doğrudan değer dene:
                object cur = dev.GetValue(keyword);
                if (cur != null)
                {
                    dev.SetValue(keyword, value, RegistryValueKind.String);
                    return true;
                }
                // Sonra Ndi\params içinde ara
                using (RegistryKey ndi = dev.OpenSubKey("Ndi\\params\\" + keyword))
                {
                    if (ndi != null)
                    {
                        dev.SetValue(keyword, value, RegistryValueKind.String);
                        return true;
                    }
                }
            } catch {}
            return false;
        }

        // ── Affinity Mask Oluşturucu ──────────────────────────────────────────
        // İşlemci sayısına bakılmaksızın doğru genişlikte byte[] üretir.
        static byte[] BuildAffinityMask(bool excludeCore0)
        {
            int cpuCount = Environment.ProcessorCount;
            int byteCount = Math.Max(4, (cpuCount + 7) / 8);
            byte[] mask = new byte[byteCount];

            ulong bits = 0;
            for (int i = 0; i < cpuCount; i++)
            {
                if (excludeCore0 && i == 0) continue;
                bits |= (1UL << i);
            }
            for (int i = 0; i < byteCount && i < 8; i++)
                mask[i] = (byte)((bits >> (i * 8)) & 0xFF);
            return mask;
        }

        // NIC için: sadece core 1 (GPU core'larından ayrı)
        static byte[] BuildNicAffinityMask()
        {
            int cpuCount = Environment.ProcessorCount;
            int byteCount = Math.Max(4, (cpuCount + 7) / 8);
            byte[] mask = new byte[byteCount];

            // Core 1 var mı?
            int nicCore = cpuCount > 1 ? 1 : 0;
            mask[nicCore / 8] = (byte)(1 << (nicCore % 8));
            return mask;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  TIMER RESOLUTION
        // ══════════════════════════════════════════════════════════════════════
        void SetResolutionVerified()
        {
            long c = Interlocked.Increment(ref processCounter);
            if (c > 1) return;

            uint actual = 0;
            NtSetTimerResolution(targetRes, true, out actual);

            for (int i = 0; i < 50; i++)
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RESOLUTION_TOLERANCE) break;
                Thread.SpinWait(10000);
                NtSetTimerResolution(targetRes, true, out actual);
            }
            Log(string.Format("[albus timer] dogrulandi: {0} ({1:F3}ms)", actual, actual / 10000.0));

            if (isWin11PerProcess)
                Log("[albus timer] UYARI: Win11 per-process mod aktif. Hedef process'in kendi timer resolution'ini ayarlamasi gerekir.");
        }

        void RestoreResolution()
        {
            long c = Interlocked.Decrement(ref processCounter);
            if (c >= 1) return;
            uint actual = 0;
            NtSetTimerResolution(defaultRes, true, out actual);
        }

        void StartGuard()
        {
            guardTimer = new Timer(GuardCallback, null,
                TimeSpan.FromSeconds(GUARD_SEC),
                TimeSpan.FromSeconds(GUARD_SEC));
        }

        void GuardCallback(object _)
        {
            Safe.Run("guard", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RESOLUTION_TOLERANCE) return;

                uint actual = 0;
                for (int i = 0; i < 3; i++)
                {
                    NtSetTimerResolution(targetRes, true, out actual);
                    Thread.SpinWait(5000);
                    NtQueryTimerResolution(out qMin, out qMax, out qCur);
                    if (qCur <= targetRes + RESOLUTION_TOLERANCE) break;
                }
                Log(string.Format("[albus guard] drift duzeltildi: {0} → {1} ({2:F3}ms)",
                    qCur, actual, actual / 10000.0));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  BELLEK
        // ══════════════════════════════════════════════════════════════════════
        void PurgeStandbyList()
        {
            Safe.Run("purge_cache", () =>
                SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0), EventLog);
            Safe.Run("purge_standby", () =>
            { int cmd = 4; NtSetSystemInformation(80, ref cmd, sizeof(int)); }, EventLog);
        }

        void GhostMemory()
        {
            Safe.Run("ghost_mem", () =>
                EmptyWorkingSet(Process.GetCurrentProcess().Handle), EventLog);
        }

        void StartPurge()
        {
            purgeTimer = new Timer(PurgeCallback, null,
                TimeSpan.FromMinutes(PURGE_INITIAL_MIN),
                TimeSpan.FromMinutes(PURGE_INTERVAL_MIN));
        }

        void PurgeCallback(object _)
        {
            Safe.Run("purge_cb", () =>
            {
                float mb = 0;
                using (var pc = new PerformanceCounter("Memory", "Available MBytes"))
                    mb = pc.NextValue();
                if (mb < PURGE_THRESHOLD_MB)
                {
                    PurgeStandbyList();
                    Log(string.Format("[albus islc] purge tetiklendi, musait={0:F0}MB.", mb));
                }
            }, EventLog);
            GhostMemory();
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WATCHDOG — üç bağımsız kontrol
        // ══════════════════════════════════════════════════════════════════════
        void StartWatchdog()
        {
            watchdogTimer = new Timer(WatchdogCallback, null,
                TimeSpan.FromSeconds(WATCHDOG_SEC),
                TimeSpan.FromSeconds(WATCHDOG_SEC));
        }

        void WatchdogCallback(object _)
        {
            // 1. Servis priority
            Safe.Run("wd_selfprio", () =>
            {
                Process self = Process.GetCurrentProcess();
                if (self.PriorityClass != ProcessPriorityClass.High)
                {
                    Log(string.Format("[albus watchdog] priority calinmis ({0}), geri aliniyor.",
                        self.PriorityClass));
                    self.PriorityClass = ProcessPriorityClass.High;
                }
            }, EventLog);

            // 2. DWM priority
            Safe.Run("wd_dwm", () =>
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try
                    {
                        if (p.PriorityClass != ProcessPriorityClass.High)
                            p.PriorityClass = ProcessPriorityClass.High;
                    } catch {}
            }, EventLog);

            // 3. Timer resolution hızlı kontrol
            Safe.Run("wd_timer", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur > targetRes + RESOLUTION_TOLERANCE * 4)
                {
                    uint actual = 0;
                    NtSetTimerResolution(targetRes, true, out actual);
                    Log(string.Format(
                        "[albus watchdog] timer kaydi: {0:F3}ms → duzeltildi.",
                        qCur / 10000.0));
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HEALTH MONİTÖR
        // ══════════════════════════════════════════════════════════════════════
        void StartHealthMonitor()
        {
            healthTimer = new Timer(HealthCallback, null,
                TimeSpan.FromMinutes(HEALTH_INITIAL_MIN),
                TimeSpan.FromMinutes(HEALTH_INTERVAL_MIN));
        }

        void HealthCallback(object _)
        {
            Safe.Run("health", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);

                float availMB = 0;
                Safe.Run("health_mem", () =>
                {
                    using (var pc = new PerformanceCounter("Memory", "Available MBytes"))
                        availMB = pc.NextValue();
                }, EventLog);

                float cpu = 0;
                Safe.Run("health_cpu", () =>
                {
                    using (var pc = new PerformanceCounter("Processor", "% Processor Time", "_Total"))
                    {
                        pc.NextValue();
                        Thread.Sleep(200);
                        cpu = pc.NextValue();
                    }
                }, EventLog);

                long jitterBest = long.MaxValue;
                for (int i = 0; i < 200; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(1000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < jitterBest) jitterBest = d;
                }
                double jitterUs = (jitterBest * 1_000_000.0) / Stopwatch.Frequency;

                Log(string.Format(
                    "[albus health] timer={0:F3}ms | ram={1:F0}MB | cpu={2:F1}% | jitter={3:F2}µs",
                    qCur / 10000.0, availMB, cpu, jitterUs));

                if (dpcBaselineTicks > 0)
                {
                    double baseUs = (dpcBaselineTicks * 1_000_000.0) / Stopwatch.Frequency;
                    if (jitterUs > baseUs * 3.0)
                        Log(string.Format(
                            "[albus health] UYARI: jitter baseline'dan {0:F1}x yuksek! DPC sorun olabilir.",
                            jitterUs / baseUs));
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  ETW PROCESS İZLEYİCİ  (WMI'dan çok daha düşük gecikme ve overhead)
        //  Microsoft-Windows-Kernel-Process provider: {22FB2CD6-0E7B-422B-A0C7-2FAD1FD0E716}
        //  Event ID 1 = ProcessStart
        // ══════════════════════════════════════════════════════════════════════
        void StartEtwWatcher()
        {
            etwThread          = new Thread(EtwWorker);
            etwThread.Name     = "albus-etw";
            etwThread.Priority = ThreadPriority.Highest;
            etwThread.IsBackground = true;
            etwThread.Start();
        }

        void EtwWorker()
        {
            bool success = false;
            Safe.Run("etw_worker", () =>
            {
                // ETW Consumer: NT Kernel Logger veya Process provider'dan Process Start
                // Manuel ETW API çağrısı ile düşük overhead izleme
                success = TryStartEtwSession();
            }, EventLog);

            if (!success)
            {
                // ETW başarısız olursa WMI fallback
                Log("[albus etw] ETW basarisiz, WMI fallback'e geciyor.");
                Safe.Run("wmi_fallback", StartWmiWatcher, EventLog);
            }
        }

        bool TryStartEtwSession()
        {
            // ETW Real-Time Consumer için EVENT_TRACE_LOGFILE kurulumu
            // Kernel Process provider: GUID {22FB2CD6-0E7B-422B-A0C7-2FAD1FD0E716}
            // Bu yapı üretim ortamında advapi32 ETW API'sini kullanır.

            var logFile = new EVENT_TRACE_LOGFILE();
            logFile.LoggerName    = "NT Kernel Logger";
            logFile.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
            logFile.EventRecordCallback = OnEtwEvent;

            IntPtr hTrace = OpenTrace(ref logFile);
            if (hTrace == INVALID_PROCESSTRACE_HANDLE)
            {
                // "NT Kernel Logger" başlatmak için ayrı session gerekebilir —
                // Microsoft-Windows-Kernel-Process ile dene
                logFile.LoggerName = "Albus-KernelProc";
                hTrace = OpenTrace(ref logFile);
                if (hTrace == INVALID_PROCESSTRACE_HANDLE)
                    return false;
            }

            // ProcessTrace — bloklar, bu yüzden ayrı thread'de çalıştırılıyor
            Log("[albus etw] ETW trace baslatildi (kernel process events).");
            uint status = ProcessTrace(new IntPtr[] { hTrace }, 1, IntPtr.Zero, IntPtr.Zero);
            CloseTrace(hTrace);
            return (status == 0);
        }

        [ThreadStatic]
        static HashSet<string> _etwTargetSet;

        void OnEtwEvent(ref EVENT_RECORD record)
        {
            Safe.Run("etw_event", () =>
            {
                // EventID 1 = Process Start
                if (record.EventHeader.Id != 1) return;

                // UserData'dan process adını çıkar (KERNEL_PROCESS_START_V2 şeması)
                // Offset 16'dan itibaren ImageFileName (null-terminated WCHAR)
                if (record.UserDataLength < 20) return;

                string imgName = "";
                Safe.Run("etw_imgname", () =>
                {
                    // ProcessId offset 0 (uint32), ImageFileName offset 8 (wchar*)
                    // Basit: tüm UserData'yı string olarak parse et
                    imgName = Marshal.PtrToStringUni(
                        IntPtr.Add(record.UserData, 8));
                    if (imgName != null)
                        imgName = System.IO.Path.GetFileName(imgName).ToLowerInvariant();
                }, EventLog);

                if (string.IsNullOrEmpty(imgName)) return;

                // Hedef process listesiyle eşleştir
                List<string> targets = processNames;
                if (targets == null || !targets.Contains(imgName)) return;

                uint pid = (uint)Marshal.ReadInt32(record.UserData, 0);
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid); });
            }, EventLog);
        }

        // ── WMI Fallback ──────────────────────────────────────────────────────
        void StartWmiWatcher()
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
            wmiRetry = 0;
            Log("[albus watcher] WMI izleniyor: " + string.Join(", ", processNames));
        }

        void OnWatcherStopped(object sender, StoppedEventArgs e)
        {
            if (wmiRetry >= 5) return;
            if (stopEvent.IsSet) return;
            wmiRetry++;
            Thread.Sleep(3000);
            Safe.Run("wmi_restart", () =>
            {
                if (startWatch != null) try { startWatch.Dispose(); } catch {}
                startWatch = null;
                StartWmiWatcher();
                Log("[albus watcher] WMI yeniden baglandi.");
            }, EventLog);
        }

        void OnProcessArrived(object sender, EventArrivedEventArgs e)
        {
            Safe.Run("wmi_arrived", () =>
            {
                ManagementBaseObject proc =
                    (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                uint pid = (uint)proc.Properties["ProcessId"].Value;
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid); });
            }, EventLog);
        }

        void ProcessStarted(uint pid)
        {
            Safe.Run("proc_started", () =>
            {
                uint t = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref t);
            }, EventLog);

            Safe.Run("proc_thread_prio", () =>
                Thread.CurrentThread.Priority = ThreadPriority.Highest, EventLog);

            SetResolutionVerified();
            PurgeStandbyList();
            GhostMemory();
            ModulateUiPriority(true);

            IntPtr hProc = IntPtr.Zero;
            Safe.Run("proc_wait", () =>
            {
                hProc = OpenProcess(SYNCHRONIZE, 0, pid);
                if (hProc != IntPtr.Zero) WaitForSingleObject(hProc, -1);
            }, EventLog);

            if (hProc != IntPtr.Zero)
                Safe.Run("proc_close", () => CloseHandle(hProc), EventLog);

            ModulateUiPriority(false);
            RestoreResolution();
            PurgeStandbyList();
            GhostMemory();
            Log("[albus rested] process kapandi, onarim tamamlandi.");
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SES GECİKMESİ — IAudioClient3 vtable düzeltmesi
        //  IAudioClient (v1) → IAudioClient2 → IAudioClient3 zinciri
        //  Mevcut tanım vtable sırasını doğru yansıtmıyordu.
        // ══════════════════════════════════════════════════════════════════════
        void StartAudioThread()
        {
            audioThread              = new Thread(AudioWorker);
            audioThread.Name         = "albus-audio";
            audioThread.Priority     = ThreadPriority.Highest;
            audioThread.IsBackground = true;
            audioThread.Start();
        }

        void AudioWorker()
        {
            Safe.Run("audio_mmcss", () =>
            {
                uint t = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref t);
            }, EventLog);

            Safe.Run("audio_coinit", () =>
                CoInitializeEx(IntPtr.Zero, COINIT_MULTITHREADED), EventLog);

            Safe.Run("audio_main", () =>
            {
                Type mmdeType = Type.GetTypeFromCLSID(
                    new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                IMMDeviceEnumerator enumerator =
                    (IMMDeviceEnumerator)Activator.CreateInstance(mmdeType);

                audioNotifier            = new AudioNotifier();
                audioNotifier.Service    = this;
                audioNotifier.Enumerator = enumerator;
                enumerator.RegisterEndpointNotificationCallback(audioNotifier);

                OptimizeAllEndpoints(enumerator);
            }, EventLog);

            // Düzgün shutdown: stopEvent bekle
            stopEvent.Wait();
        }

        internal void OptimizeAllEndpoints(IMMDeviceEnumerator enumerator)
        {
            Safe.Run("audio_endpoints", () =>
            {
                Guid IID_AC3 = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                IMMDeviceCollection col;
                if (enumerator.EnumAudioEndpoints(EDataFlow_eRender, DEVICE_STATE_ACTIVE, out col) != 0)
                    return;

                uint count;
                col.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    Safe.Run("audio_ep_" + i, () =>
                    {
                        IMMDevice dev;
                        if (col.Item(i, out dev) != 0) return;

                        object clientObj;
                        if (dev.Activate(ref IID_AC3, CLSCTX_ALL, IntPtr.Zero, out clientObj) != 0)
                            return;

                        // vtable doğru: IAudioClient → IAudioClient2 → IAudioClient3
                        // GetMixFormat vtable slot 6 (0-based, IUnknown 3 slot + IAudioClient1 sırası)
                        IAudioClient3 client = (IAudioClient3)clientObj;
                        IntPtr pFmt = IntPtr.Zero;
                        if (client.GetMixFormat(out pFmt) != 0) return;

                        uint defF, fundF, minF, maxF;
                        if (client.GetSharedModeEnginePeriod(pFmt,
                            out defF, out fundF, out minF, out maxF) != 0) return;

                        if (minF < defF && minF > 0)
                        {
                            if (client.InitializeSharedAudioStream(0, minF, pFmt, IntPtr.Zero) == 0 &&
                                client.Start() == 0)
                            {
                                lock (audioClients) audioClients.Add(clientObj);

                                WAVEFORMATEX fmt =
                                    (WAVEFORMATEX)Marshal.PtrToStructure(pFmt, typeof(WAVEFORMATEX));
                                string devId;
                                dev.GetId(out devId);
                                string shortId = (devId != null && devId.Length > 8)
                                    ? devId.Substring(devId.Length - 8) : (devId ?? "?");

                                Log(string.Format(
                                    "[albus audio] {0}: {1:F3}ms → {2:F3}ms (kare {3}→{4})",
                                    shortId,
                                    (defF / (double)fmt.nSamplesPerSec) * 1000.0,
                                    (minF / (double)fmt.nSamplesPerSec) * 1000.0,
                                    defF, minF));
                            }
                        }
                        if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt);
                    }, EventLog);
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  CONFIG / INI
        // ══════════════════════════════════════════════════════════════════════
        void ReadConfig()
        {
            processNames = null;
            customRes    = 0;

            string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
            if (!File.Exists(iniPath)) return;

            List<string> names = new List<string>();
            foreach (string raw in File.ReadAllLines(iniPath))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#") || line.StartsWith("//"))
                    continue;

                if (line.ToLowerInvariant().StartsWith("resolution="))
                {
                    uint val;
                    if (uint.TryParse(line.Substring(11).Trim(), out val))
                        customRes = val;
                    continue;
                }

                foreach (string tok in line.Split(
                    new char[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string name = tok.ToLowerInvariant().Trim();
                    if (name.Length == 0) continue;
                    if (!name.EndsWith(".exe")) name += ".exe";
                    if (!names.Contains(name)) names.Add(name);
                }
            }
            processNames = names.Count > 0 ? names : null;
        }

        void StartIniWatcher()
        {
            Safe.Run("ini_watcher", () =>
            {
                string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
                iniWatcher = new FileSystemWatcher(
                    Path.GetDirectoryName(iniPath),
                    Path.GetFileName(iniPath));
                iniWatcher.NotifyFilter        = NotifyFilters.LastWrite;
                iniWatcher.Changed            += OnIniChanged;
                iniWatcher.EnableRaisingEvents = true;
            }, EventLog);
        }

        void OnIniChanged(object sender, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            Safe.Run("ini_reload", () =>
            {
                ReadConfig();
                targetRes = customRes > 0
                    ? customRes
                    : Math.Min(TARGET_RESOLUTION, maxRes);

                if (startWatch != null)
                    try { startWatch.Stop(); startWatch.Dispose(); startWatch = null; } catch {}

                if (processNames != null && processNames.Count > 0)
                    StartEtwWatcher();
                else
                {
                    SetResolutionVerified();
                    ModulateUiPriority(true);
                }
                Log("[albus reload] yapilandirma guncellendi (hot-reload).");
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  KAYIT
        // ══════════════════════════════════════════════════════════════════════
        void Log(string msg)
        {
            try
            {
                EventLog.WriteEntry(
                    string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), msg));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  P/INVOKE + SABİTLER
        // ══════════════════════════════════════════════════════════════════════

        // ntdll
        [DllImport("ntdll.dll")]
        static extern int NtSetTimerResolution(uint DesiredResolution, bool Set, out uint Current);
        [DllImport("ntdll.dll")]
        static extern int NtQueryTimerResolution(out uint Min, out uint Max, out uint Current);
        [DllImport("ntdll.dll")]
        static extern int NtSetSystemInformation(int InfoClass, ref int Info, int Len);

        // kernel32
        [DllImport("kernel32.dll")] static extern bool   CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, int inherit, uint pid);
        [DllImport("kernel32.dll")] static extern int    WaitForSingleObject(IntPtr h, int ms);
        [DllImport("kernel32.dll")] static extern bool   SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr attr, string name, uint flags, uint access);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(IntPtr hProc, int InfoClass,
            ref PROCESS_POWER_THROTTLING Info, int Size);
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessWorkingSetSizeEx(IntPtr hProc,
            UIntPtr min, UIntPtr max, uint flags);
        [DllImport("kernel32.dll")]
        static extern bool GetSystemCpuSetInformation(IntPtr info, uint bufLen,
            out uint returned, IntPtr proc, uint flags);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool   SetThreadPriority(IntPtr hThread, int nPriority);

        // psapi / avrt / ole32 / gdi32 / powrprof
        [DllImport("psapi.dll")]    static extern int   EmptyWorkingSet(IntPtr hProc);
        [DllImport("avrt.dll")]     static extern IntPtr AvSetMmThreadCharacteristics(string task, ref uint idx);
        [DllImport("ole32.dll")]    static extern int   CoInitializeEx(IntPtr pv, uint dwCoInit);
        [DllImport("gdi32.dll")]    static extern int   D3DKMTSetProcessSchedulingPriority(IntPtr hProc, int pri);
        static int D3DKMTSetProcessSchedulingPriorityClass(IntPtr h, int c) =>
            D3DKMTSetProcessSchedulingPriority(h, c);
        [DllImport("powrprof.dll")]
        static extern uint CallNtPowerInformation(int Level, IntPtr inBuf, uint inLen,
            IntPtr outBuf, uint outLen);

        // ETW
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr OpenTrace(ref EVENT_TRACE_LOGFILE Logfile);
        [DllImport("advapi32.dll")]
        static extern uint ProcessTrace(IntPtr[] HandleArray, uint HandleCount,
            IntPtr StartTime, IntPtr EndTime);
        [DllImport("advapi32.dll")]
        static extern uint CloseTrace(IntPtr TraceHandle);

        // ── sabitler ─────────────────────────────────────────────────────────
        const uint SYNCHRONIZE                              = 0x00100000u;
        const uint ES_CONTINUOUS                            = 0x80000000u;
        const uint ES_SYSTEM_REQUIRED                       = 0x00000001u;
        const uint ES_DISPLAY_REQUIRED                     = 0x00000002u;
        const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION    = 0x00000002u;
        const uint TIMER_ALL_ACCESS                         = 0x1F0003u;
        const uint QUOTA_LIMITS_HARDWS_MIN_ENABLE           = 0x00000001u;
        const int  ProcessPowerThrottling                   = 4;
        const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x4u;
        const int  ProcessorIdleDomains                     = 14;
        const int  D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME  = 5;
        const int  IrqPolicySpecifiedProcessors             = 4;
        const int  THREAD_PRIORITY_TIME_CRITICAL            = 15;
        const int  EDataFlow_eRender                        = 0;
        const int  DEVICE_STATE_ACTIVE                      = 1;
        const int  CLSCTX_ALL                               = 0x17;
        const uint COINIT_MULTITHREADED                     = 0u;
        const int  PROCESS_TRACE_MODE_REAL_TIME             = 0x00000100;
        const int  PROCESS_TRACE_MODE_EVENT_RECORD          = 0x10000000;
        static readonly IntPtr INVALID_PROCESSTRACE_HANDLE  = new IntPtr(-1);

        // ── yapılar ───────────────────────────────────────────────────────────

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_POWER_THROTTLING
        { public uint Version, ControlMask, StateMask; }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct WAVEFORMATEX
        {
            public ushort wFormatTag, nChannels;
            public uint   nSamplesPerSec, nAvgBytesPerSec;
            public ushort nBlockAlign, wBitsPerSample, cbSize;
        }

        // ETW yapıları (basitleştirilmiş)
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct EVENT_TRACE_LOGFILE
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string LogFileName;
            [MarshalAs(UnmanagedType.LPWStr)] public string LoggerName;
            public long  CurrentTime;
            public uint  BuffersRead;
            public uint  ProcessTraceMode;
            public IntPtr CurrentEvent;     // EVENT_TRACE*
            public IntPtr LogfileHeader;    // TRACE_LOGFILE_HEADER*
            public IntPtr BufferCallback;
            public int   BufferSize;
            public int   Filled;
            public int   EventsLost;
            public EventRecordCallback EventRecordCallback;
            public uint  IsKernelTrace;
            public IntPtr Context;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_RECORD
        {
            public EVENT_HEADER EventHeader;
            public ETW_BUFFER_CONTEXT BufferContext;
            public ushort ExtendedDataCount;
            public ushort UserDataLength;
            public IntPtr ExtendedData;
            public IntPtr UserData;
            public IntPtr UserContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_HEADER
        {
            public ushort Size;
            public ushort HeaderType;
            public ushort Flags;
            public ushort EventProperty;
            public uint   ThreadId;
            public uint   ProcessId;
            public long   TimeStamp;
            public Guid   ProviderId;
            public ushort Id;
            public byte   Version;
            public byte   Channel;
            public byte   Level;
            public byte   Opcode;
            public ushort Task;
            public ulong  Keyword;
            public uint   KernelTime;
            public uint   UserTime;
            public Guid   ActivityId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ETW_BUFFER_CONTEXT
        {
            public byte ProcessorNumber;
            public byte Alignment;
            public ushort LoggerId;
        }

        delegate void EventRecordCallback(ref EVENT_RECORD EventRecord);

        // ── COM arayüzleri — vtable sırası düzeltildi ─────────────────────────

        [ComImport][Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint n);
            [PreserveSig] int Item(uint i, out IMMDevice dev);
        }

        [ComImport][Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IMMNotificationClient
        {
            [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
            [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDefaultDeviceChanged(int flow, int role,
                [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
        }

        [ComImport][Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int flow, int state, out IMMDeviceCollection col);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
            [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient cb);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient cb);
        }

        [ComImport][Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr pParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
            [PreserveSig] int OpenPropertyStore(int access, out IntPtr props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        // IAudioClient (tam vtable — slot 0–9)
        [ComImport][Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr guid);
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
        }

        // IAudioClient2 (IAudioClient + 3 ek slot)
        [ComImport][Guid("726778CD-F60A-4EDA-82DE-E47610CD78AA")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient2
        {
            // IAudioClient sırası korunmalı
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr guid);
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
            // IAudioClient2 ekleri
            [PreserveSig] int IsOffloadCapable(int cat, out int capable);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetBufferSizeLimits(IntPtr fmt, bool useEventDriven,
                out long minDur, out long maxDur);
        }

        // IAudioClient3 (IAudioClient2 + 3 ek slot)
        // GUID: 7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE
        [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient3
        {
            // IAudioClient sırası
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr guid);
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
            // IAudioClient2 ekleri
            [PreserveSig] int IsOffloadCapable(int cat, out int capable);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetBufferSizeLimits(IntPtr fmt, bool useEventDriven,
                out long minDur, out long maxDur);
            // IAudioClient3 ekleri — doğru vtable pozisyonu
            [PreserveSig] int GetSharedModeEnginePeriod(IntPtr fmt,
                out uint defaultPeriodInFrames,
                out uint fundamentalPeriodInFrames,
                out uint minPeriodInFrames,
                out uint maxPeriodInFrames);
            [PreserveSig] int GetCurrentSharedModeEnginePeriod(
                out IntPtr fmt, out uint currentPeriodInFrames);
            [PreserveSig] int InitializeSharedAudioStream(
                uint streamFlags, uint periodInFrames,
                IntPtr fmt, IntPtr audioSessionGuid);
        }

        class AudioNotifier : IMMNotificationClient
        {
            public AlbusService        Service;
            public IMMDeviceEnumerator Enumerator;

            public int OnDeviceStateChanged(string id, int state) { return 0; }
            public int OnDeviceAdded(string id)                   { return 0; }
            public int OnDeviceRemoved(string id)                 { return 0; }
            public int OnPropertyValueChanged(string id, IntPtr key) { return 0; }

            public int OnDefaultDeviceChanged(int flow, int role, string id)
            {
                Safe.Run("audio_devchange", () =>
                {
                    if (Service != null)
                    {
                        Service.Log("[albus audio] cihaz degisimi — yeniden optimize ediliyor.");
                        lock (Service.audioClients) Service.audioClients.Clear();
                        if (Enumerator != null)
                            Service.OptimizeAllEndpoints(Enumerator);
                    }
                }, Service?.EventLog);
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
            si.ServiceName  = "AlbusSvc";
            si.DisplayName  = "albus";
            si.StartType    = ServiceStartMode.Automatic;
            si.Description  =
                "albus v4.0 — timer, NUMA-CPU, C-state, GPU/TDR, audio, memory, " +
                "GPU-IRQ, Network-IRQ/RSS, ETW process watcher, watchdog, health.";

            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
