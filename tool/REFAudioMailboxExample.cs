// 独立客户端邮箱示例；实例拥有一个未确认请求，超时后必须 Retry，不能发送新命令。
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Threading;
using System.Linq;
public sealed class REFAudioMailboxExample {
    readonly string dir, boot, session = Guid.NewGuid().ToString("N");
    ulong sequence;
    string pending, identity;
    public REFAudioMailboxExample(string reframeworkData, string clientId = "deepseekcat") {
        if (clientId.Length == 0 || clientId.Length > 64 || clientId.Any(c => !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' && c != '-')) throw new ArgumentException("clientId");
        var root = Path.Combine(reframeworkData, "REFAudio");
        var fields = File.ReadAllText(Path.Combine(root, "audio_backend.txt")).Split('\t');
        if (!fields.Contains("client_mailboxes=1") || !fields.Contains("client_protocol=1")) throw new InvalidOperationException("Upgrade REFAudio");
        boot = fields.First(s => s.StartsWith("boot_id=")).Substring(8);
        dir = Path.Combine(root, "clients", clientId); Directory.CreateDirectory(dir);
    }
    // 原子提交；同目录临时文件避免 DLL 读到半份正文。
    void Submit() {
        var target = Path.Combine(dir, "command.txt");
        var temp = Path.Combine(dir, "command.tmp");
        File.WriteAllText(temp, pending, new UTF8Encoding(false));
        if (File.Exists(target)) File.Replace(temp, target, null); else File.Move(temp, target);
    }
    public string Send(string action, uint channel, params string[] args) {
        if (pending != null) throw new InvalidOperationException("Retry outstanding request first");
        if (args.Any(s => s.IndexOfAny(new[] {'\t','\r','\n','\0'}) >= 0)) throw new ArgumentException("Invalid field");
        identity = boot + "\t" + session + "\t" + (++sequence).ToString(CultureInfo.InvariantCulture) + "\t" + channel.ToString(CultureInfo.InvariantCulture) + "\t";
        pending = boot + "\t" + session + "\t" + sequence.ToString(CultureInfo.InvariantCulture) + "\t" + action + "\t" + channel.ToString(CultureInfo.InvariantCulture) + (args.Length > 0 ? "\t" + string.Join("\t", args) : "");
        return Retry();
    }
    public string Retry() {
        if (pending == null) throw new InvalidOperationException("No pending request");
        Submit();
        for (int i = 0; i < 250; i++) {
            var path = Path.Combine(dir, "response.txt");
            if (File.Exists(path)) {
                var response = File.ReadAllText(path);
                if (response.StartsWith(identity, StringComparison.Ordinal)) { pending = null; return response; }
            }
            Thread.Sleep(20);
        }
        throw new TimeoutException("Request remains pending; Retry with same ID");
    }
    public string State() { var path = Path.Combine(dir, "state.txt"); return File.Exists(path) ? File.ReadAllText(path) : "unknown"; }
    // 使用示例：Send 返回的是匹配请求的实际确认，检查 ok/error 后继续。
    public static void Demo(string data) {
        var mailbox = new REFAudioMailboxExample(data);
        Console.WriteLine(mailbox.Send("load", 0, "DeepSeekCat/tts/reply-session-1.mp3", "1", "1", "0"));
        Console.WriteLine(mailbox.State()); // 自然结束后含 ended；此时 MP3 句柄已释放。
        Console.WriteLine(mailbox.Send("stop", 0));
    }
}