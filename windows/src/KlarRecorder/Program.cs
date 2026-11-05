using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using ScreenRecorderLib;

namespace KlarRecorder
{
    /// <summary>
    /// Nimmt den Hauptbildschirm mit Systemton (optional Mikrofon) als MP4 auf (H.264 / AAC).
    /// Aufruf: KlarRecorder.exe &lt;Zieldatei&gt; [--mic]
    /// Ausgabe auf stdout: „started“, „complete“ oder „failed: …“. Eine Zeile „stop“ auf stdin
    /// (oder das Schließen von stdin, wenn Klar beendet wird) schließt die Aufnahme sauber ab.
    /// </summary>
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
            if (args.Length < 1)
            {
                Console.WriteLine("failed: Kein Zielpfad angegeben.");
                return 2;
            }
            var path = args[0];
            var withMicrophone = Array.IndexOf(args, "--mic") >= 0;
            var done = new ManualResetEventSlim(false);
            var exitCode = 0;
            var announced = 0;
            Recorder recorder;
            try
            {
                var audioSources = new List<AudioSourceBase> { LoopbackAudioSource.Default };
                if (withMicrophone) audioSources.Add(CaptureAudioSource.Default);
                var options = new RecorderOptions
                {
                    SourceOptions = SourceOptions.MainMonitor,
                    OutputOptions = new OutputOptions { RecorderMode = RecorderMode.Video },
                    AudioOptions = new AudioOptions
                    {
                        IsAudioEnabled = true,
                        Bitrate = AudioBitrate.bitrate_160kbps,
                        Channels = AudioChannels.Stereo,
                        AudioSources = audioSources,
                    },
                    VideoEncoderOptions = new VideoEncoderOptions
                    {
                        Bitrate = 12000000,
                        Framerate = 30,
                        IsFixedFramerate = false,
                        IsHardwareEncodingEnabled = true,
                        Encoder = new H264VideoEncoder
                        {
                            BitrateMode = H264BitrateControlMode.UnconstrainedVBR,
                            EncoderProfile = H264Profile.High,
                        },
                    },
                    MouseOptions = new MouseOptions { IsMousePointerEnabled = true },
                };
                recorder = Recorder.CreateRecorder(options);
            }
            catch (Exception e)
            {
                Console.WriteLine("failed: " + e.Message);
                return 1;
            }

            recorder.OnStatusChanged += (s, e) =>
            {
                if (e.Status == RecorderStatus.Recording && Interlocked.Exchange(ref announced, 1) == 0)
                    Console.WriteLine("started");
            };
            recorder.OnRecordingFailed += (s, e) =>
            {
                Console.WriteLine("failed: " + (e.Error ?? "unbekannter Fehler").Replace('\n', ' ').Replace('\r', ' '));
                exitCode = 1;
                done.Set();
            };
            recorder.OnRecordingComplete += (s, e) =>
            {
                Console.WriteLine("complete");
                done.Set();
            };

            try { recorder.Record(path); }
            catch (Exception e)
            {
                Console.WriteLine("failed: " + e.Message);
                return 1;
            }

            var input = new Thread(() =>
            {
                try
                {
                    string line;
                    while ((line = Console.ReadLine()) != null)
                        if (line.Trim() == "stop") break;
                }
                catch { }
                // Kommt der Stopp, bevor die Aufnahme läuft, ginge er ins Leere und die Aufnahme liefe
                // danach ohne Aufsicht weiter. Deshalb erst den Start abwarten.
                for (var i = 0; i < 200 && Volatile.Read(ref announced) == 0 && !done.IsSet; i++) Thread.Sleep(100);
                try { recorder.Stop(); } catch { }
                // Schließt die Bibliothek die Datei nicht ab, trotzdem enden – nie als verwaister Prozess weiterlaufen.
                if (!done.Wait(30000))
                {
                    Console.WriteLine("failed: Aufnahme ließ sich nicht abschließen.");
                    exitCode = 1;
                    done.Set();
                }
            })
            { IsBackground = true };
            input.Start();

            done.Wait();
            try { recorder.Dispose(); } catch { }
            return exitCode;
        }
    }
}
