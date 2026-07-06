using System.Buffers.Binary;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace VinylSync.Agent;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var app = new TrayApp();
        Application.Run();
    }
}

internal sealed class TrayApp : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
    private readonly ToolStripMenuItem _deviceMenu = new("Select input device");
    private readonly ToolStripMenuItem _startMenu = new("Start streaming");
    private readonly ToolStripMenuItem _stopMenu = new("Stop streaming");
    private readonly ToolStripMenuItem _statusMenu = new("Waiting");
    private readonly AppConfig _config;
    private readonly ConfigStore _configStore = new();
    private AudioStreamer? _streamer;
    private IReadOnlyList<MMDevice> _devices = [];

    public TrayApp()
    {
        _config = _configStore.Load();
        _statusMenu.Enabled = false;
        _stopMenu.Enabled = false;
        _startMenu.Click += async (_, _) => await StartStreaming();
        _stopMenu.Click += async (_, _) => await StopStreaming();

        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusMenu);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_deviceMenu);
        menu.Items.Add(_startMenu);
        menu.Items.Add(_stopMenu);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, async (_, _) =>
        {
            await StopStreaming();
            Application.Exit();
        });

        _notifyIcon = new NotifyIcon
        {
            Text = "Vinyl Sync",
            Icon = SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true
        };

        RefreshDevices();
    }

    private void RefreshDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        _devices = enumerator
            .EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .ToArray();

        _deviceMenu.DropDownItems.Clear();
        foreach (var device in _devices)
        {
            var item = new ToolStripMenuItem(device.FriendlyName)
            {
                Checked = device.ID == _config.DeviceId
            };
            item.Click += (_, _) =>
            {
                _config.DeviceId = device.ID;
                _config.DeviceName = device.FriendlyName;
                _configStore.Save(_config);
                RefreshDevices();
                SetStatus($"Selected {device.FriendlyName}");
            };
            _deviceMenu.DropDownItems.Add(item);
        }

        if (_deviceMenu.DropDownItems.Count == 0)
        {
            _deviceMenu.DropDownItems.Add(new ToolStripMenuItem("No capture devices") { Enabled = false });
        }
    }

    private async Task StartStreaming()
    {
        if (_streamer != null) return;

        RefreshDevices();
        var device = _devices.FirstOrDefault(d => d.ID == _config.DeviceId) ?? _devices.FirstOrDefault();
        if (device == null)
        {
            SetStatus("No input device found");
            return;
        }

        _config.DeviceId = device.ID;
        _config.DeviceName = device.FriendlyName;
        _configStore.Save(_config);

        _streamer = new AudioStreamer(_config, device, SetStatus);
        _startMenu.Enabled = false;
        _stopMenu.Enabled = true;
        await _streamer.Start();
    }

    private async Task StopStreaming()
    {
        if (_streamer == null) return;
        await _streamer.Stop();
        _streamer.Dispose();
        _streamer = null;
        _startMenu.Enabled = true;
        _stopMenu.Enabled = false;
        SetStatus("Stopped");
    }

    private void SetStatus(string value)
    {
        if (_notifyIcon.ContextMenuStrip?.InvokeRequired == true)
        {
            _notifyIcon.ContextMenuStrip.BeginInvoke(() => SetStatus(value));
            return;
        }

        _statusMenu.Text = value.Length > 50 ? value[..50] : value;
        _notifyIcon.Text = _statusMenu.Text.Length > 63 ? _statusMenu.Text[..63] : _statusMenu.Text;
    }

    public void Dispose()
    {
        _streamer?.Dispose();
        _notifyIcon.Dispose();
        foreach (var device in _devices) device.Dispose();
    }
}

internal sealed class AudioStreamer : IDisposable
{
    private readonly AppConfig _config;
    private readonly MMDevice _device;
    private readonly Action<string> _setStatus;
    private readonly Channel<byte[]> _frames = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(120)
    {
        SingleReader = true,
        SingleWriter = false,
        FullMode = BoundedChannelFullMode.DropOldest
    });

    private WasapiCapture? _capture;
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _cts;
    private Task? _sendLoop;
    private WaveFormat? _format;

    public AudioStreamer(AppConfig config, MMDevice device, Action<string> setStatus)
    {
        _config = config;
        _device = device;
        _setStatus = setStatus;
    }

    public async Task Start()
    {
        _cts = new CancellationTokenSource();
        _socket = new ClientWebSocket();
        _setStatus($"Connecting {_config.WebSocketUrl}");
        await _socket.ConnectAsync(new Uri(_config.WebSocketUrl), _cts.Token);

        _capture = new WasapiCapture(_device);
        _format = _capture.WaveFormat;
        await SendHello(_format, _cts.Token);

        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += (_, args) =>
        {
            if (args.Exception != null) _setStatus(args.Exception.Message);
        };

        _sendLoop = Task.Run(() => SendLoop(_cts.Token));
        _capture.StartRecording();
        _setStatus($"Streaming {_device.FriendlyName}");
    }

    public async Task Stop()
    {
        _cts?.Cancel();
        _capture?.StopRecording();
        _capture?.Dispose();
        _capture = null;

        if (_socket is { State: WebSocketState.Open })
        {
            await _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "stopped", CancellationToken.None);
        }

        if (_sendLoop != null)
        {
            await _sendLoop.WaitAsync(TimeSpan.FromSeconds(1)).ContinueWith(_ => { });
        }

        _socket?.Dispose();
        _socket = null;
        _cts?.Dispose();
        _cts = null;
    }

    private async Task SendHello(WaveFormat format, CancellationToken cancellationToken)
    {
        var hello = JsonSerializer.Serialize(new
        {
            type = "hello",
            sampleRate = format.SampleRate,
            channels = 1,
            format = "f32le",
            frameMs = 100,
            deviceName = _device.FriendlyName
        });
        var bytes = Encoding.UTF8.GetBytes(hello);
        await _socket!.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken);
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        if (_format == null) return;
        var mono = AudioConvert.ToFloatMono(args.Buffer, args.BytesRecorded, _format);
        var bytes = new byte[mono.Length * sizeof(float)];
        Buffer.BlockCopy(mono, 0, bytes, 0, bytes.Length);
        _frames.Writer.TryWrite(bytes);
    }

    private async Task SendLoop(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var frame in _frames.Reader.ReadAllAsync(cancellationToken))
            {
                if (_socket is not { State: WebSocketState.Open }) break;
                await _socket.SendAsync(frame, WebSocketMessageType.Binary, true, cancellationToken);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            _setStatus(error.Message);
        }
    }

    public void Dispose()
    {
        _capture?.Dispose();
        _socket?.Dispose();
        _cts?.Dispose();
    }
}

internal static class AudioConvert
{
    public static float[] ToFloatMono(byte[] buffer, int byteCount, WaveFormat format)
    {
        return format.Encoding switch
        {
            WaveFormatEncoding.IeeeFloat => FloatToMono(buffer, byteCount, format.Channels),
            WaveFormatEncoding.Extensible when format.BitsPerSample == 32 => FloatToMono(buffer, byteCount, format.Channels),
            WaveFormatEncoding.Pcm when format.BitsPerSample == 16 => Pcm16ToMono(buffer, byteCount, format.Channels),
            WaveFormatEncoding.Pcm when format.BitsPerSample == 24 => Pcm24ToMono(buffer, byteCount, format.Channels),
            WaveFormatEncoding.Pcm when format.BitsPerSample == 32 => Pcm32ToMono(buffer, byteCount, format.Channels),
            _ => throw new NotSupportedException($"Unsupported capture format: {format.Encoding} {format.BitsPerSample} bit")
        };
    }

    private static float[] FloatToMono(byte[] buffer, int byteCount, int channels)
    {
        var frames = byteCount / sizeof(float) / channels;
        var output = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = (frame * channels + channel) * sizeof(float);
                sum += BitConverter.ToSingle(buffer, offset);
            }
            output[frame] = sum / channels;
        }
        return output;
    }

    private static float[] Pcm16ToMono(byte[] buffer, int byteCount, int channels)
    {
        var frames = byteCount / 2 / channels;
        var output = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = (frame * channels + channel) * 2;
                sum += BitConverter.ToInt16(buffer, offset) / 32768f;
            }
            output[frame] = sum / channels;
        }
        return output;
    }

    private static float[] Pcm24ToMono(byte[] buffer, int byteCount, int channels)
    {
        var frames = byteCount / 3 / channels;
        var output = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = (frame * channels + channel) * 3;
                var value = buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16);
                if ((value & 0x800000) != 0) value |= unchecked((int)0xff000000);
                sum += value / 8388608f;
            }
            output[frame] = sum / channels;
        }
        return output;
    }

    private static float[] Pcm32ToMono(byte[] buffer, int byteCount, int channels)
    {
        var frames = byteCount / 4 / channels;
        var output = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = (frame * channels + channel) * 4;
                sum += BinaryPrimitives.ReadInt32LittleEndian(buffer.AsSpan(offset, 4)) / 2147483648f;
            }
            output[frame] = sum / channels;
        }
        return output;
    }
}

internal sealed class AppConfig
{
    public string MacHost { get; set; } = "192.168.1.3";
    public int MacPort { get; set; } = 4739;
    public string? DeviceId { get; set; }
    public string? DeviceName { get; set; }

    public string WebSocketUrl => $"ws://{MacHost}:{MacPort}/audio";
}

internal sealed class ConfigStore
{
    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "VinylSync",
        "config.json");

    public AppConfig Load()
    {
        try
        {
            if (!File.Exists(_path)) return new AppConfig();
            return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(_path)) ?? new AppConfig();
        }
        catch
        {
            return new AppConfig();
        }
    }

    public void Save(AppConfig config)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, JsonSerializer.Serialize(config, new JsonSerializerOptions
        {
            WriteIndented = true
        }));
    }
}
