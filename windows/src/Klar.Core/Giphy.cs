using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Klar.Core;

public sealed class GiphyGif
{
    public sealed class Rendition
    {
        [JsonPropertyName("url")] public string Url { get; set; } = "";
        [JsonPropertyName("width")] public string Width { get; set; } = "";
        [JsonPropertyName("height")] public string Height { get; set; } = "";
    }

    public sealed class ImageSet
    {
        [JsonPropertyName("fixed_width")] public Rendition FixedWidth { get; set; } = new();
        [JsonPropertyName("original")] public Rendition Original { get; set; } = new();
    }

    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("images")] public ImageSet Images { get; set; } = new();

    [JsonIgnore] public string PreviewUrl => Images.FixedWidth.Url;
    [JsonIgnore] public string OriginalUrl => Images.Original.Url;
}

public sealed class GiphyException(string message) : Exception(message);

public static class GiphyClient
{
    private sealed class Envelope
    {
        [JsonPropertyName("data")] public List<GiphyGif> Data { get; set; } = [];
    }

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public static async Task<List<GiphyGif>> FetchAsync(string query, string apiKey, int limit = 30, CancellationToken ct = default)
    {
        var key = apiKey.Trim();
        if (key.Length == 0) throw new GiphyException("Kein Giphy-API-Schlüssel hinterlegt.");
        var q = query.Trim();
        var url = (q.Length == 0 ? "https://api.giphy.com/v1/gifs/trending" : "https://api.giphy.com/v1/gifs/search")
            + "?api_key=" + Uri.EscapeDataString(key)
            + "&limit=" + limit.ToString(CultureInfo.InvariantCulture)
            + "&rating=pg-13&lang=de"
            + (q.Length == 0 ? "" : "&q=" + Uri.EscapeDataString(q));
        HttpResponseMessage response;
        try { response = await Http.GetAsync(url, ct).ConfigureAwait(false); }
        catch (HttpRequestException) { throw new GiphyException("Giphy ist nicht erreichbar."); }
        using (response)
        {
            if (response.StatusCode != HttpStatusCode.OK)
            {
                var code = (int)response.StatusCode;
                throw new GiphyException(code is 401 or 403 ? "Giphy-Schlüssel ungültig." : $"Giphy antwortet nicht ({code}).");
            }
            try
            {
                var bytes = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
                return JsonSerializer.Deserialize<Envelope>(bytes)?.Data ?? [];
            }
            catch (JsonException) { throw new GiphyException("Giphy-Antwort unlesbar."); }
        }
    }

    public static Task<byte[]> DownloadBytesAsync(string url, CancellationToken ct = default) => Http.GetByteArrayAsync(url, ct);

    /// <summary>Lädt das Original-GIF, legt es dauerhaft ab und liefert den Pfad.</summary>
    public static async Task<string> DownloadAsync(GiphyGif gif, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(gif.OriginalUrl, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new GiphyException("Giphy-Antwort unlesbar.");
        var target = Path.Combine(Storage.Gifs, FileName(gif));
        if (File.Exists(target)) return target;
        var data = await Http.GetByteArrayAsync(uri, ct).ConfigureAwait(false);
        var tmp = target + ".part";
        await File.WriteAllBytesAsync(tmp, data, ct).ConfigureAwait(false);
        File.Move(tmp, target, overwrite: true);
        return target;
    }

    public static string FileName(GiphyGif gif)
    {
        var title = Regex.Replace(gif.Title, " GIF by .*$", "");
        title = Regex.Replace(title, " GIF$", "").Trim();
        var bad = Path.GetInvalidFileNameChars().Concat("/\\:?*\"<>|").ToHashSet();
        title = new string(title.Select(c => bad.Contains(c) ? ' ' : c).ToArray()).Trim().TrimEnd('.');
        if (title.Length == 0) title = "GIF";
        if (title.Length > 60) title = title[..60].Trim();
        var id = new string(gif.Id.Where(char.IsLetterOrDigit).Take(6).ToArray());
        return $"{title} {id}.gif";
    }
}
